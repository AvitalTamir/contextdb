const std = @import("std");
const net = std.net;
const config = @import("config.zig");

/// Gossip Protocol for Decentralized Node Discovery
/// Implements a SWIM-like (Scalable Weakly-consistent Infection-style process group Membership) protocol
/// Designed for TigerBeetle-style deterministic operation with minimal dependencies

/// Node state in the gossip protocol
pub const NodeState = enum(u8) {
    alive = 0,
    suspected = 1,
    dead = 2,
    left = 3, // Graceful departure
};

/// Gossip message types
pub const GossipMessageType = enum(u8) {
    ping = 1,
    ping_req = 2, // Indirect ping through another node
    ack = 3,
    alive = 4,
    suspect = 5,
    dead = 6,
    compound = 7, // Multiple messages in one packet
};

/// Node information in the cluster
pub const NodeInfo = packed struct {
    id: u64,
    address: u32, // IPv4 address in network byte order
    gossip_port: u16,
    raft_port: u16,
    incarnation: u32, // Lamport timestamp for conflict resolution
    state: NodeState,
    
    pub fn fromAddress(id: u64, addr_str: []const u8, gossip_port: u16, raft_port: u16) !NodeInfo {
        const addr = try net.Address.parseIp4(addr_str, 0);
        return NodeInfo{
            .id = id,
            .address = @bitCast(addr.in.sa.addr),
            .gossip_port = gossip_port,
            .raft_port = raft_port,
            .incarnation = 0,
            .state = .alive,
        };
    }
    
    pub fn getAddressString(self: *const NodeInfo, buf: []u8) ![]const u8 {
        const addr_bytes: [4]u8 = @bitCast(self.address);
        return try std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3] });
    }
    
    pub fn getSocketAddress(self: *const NodeInfo) net.Address {
        return net.Address{
            .in = net.Address.In{
                .sa = net.Address.In.Sa{
                    .family = std.posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, self.gossip_port),
                    .addr = self.address,
                    .zero = [8]u8{0} ** 8,
                },
            },
        };
    }
};

/// Gossip message header
pub const GossipMessage = packed struct {
    magic: u32 = 0x4D454D4F, // "MEMO" in ASCII
    version: u8 = 1,
    message_type: GossipMessageType,
    sender_id: u64,
    sequence: u32,
    checksum: u32,
    payload_size: u16,
    // payload follows
    
    pub fn calculateChecksum(self: *const GossipMessage, payload: []const u8) u32 {
        const Crc32 = std.hash.Crc32;
        var hasher = Crc32.init();
        hasher.update(std.mem.asBytes(self)[0..@offsetOf(GossipMessage, "checksum")]);
        hasher.update(std.mem.asBytes(&self.payload_size));
        hasher.update(payload);
        return hasher.final();
    }
    
    pub fn isValid(self: *const GossipMessage, payload: []const u8) bool {
        return self.magic == 0x4D454D4F and 
               self.version == 1 and
               self.payload_size == payload.len and
               self.checksum == self.calculateChecksum(payload);
    }
};

/// Ping message payload
pub const PingPayload = packed struct {
    target_id: u64,
    incarnation: u32,
};

/// Node update payload (for alive/suspect/dead messages)
pub const NodeUpdatePayload = packed struct {
    node: NodeInfo,
};

/// Compound message - multiple updates in one packet
pub const CompoundPayload = struct {
    updates: []NodeUpdatePayload,
    
    pub fn serialize(self: *const CompoundPayload, allocator: std.mem.Allocator) ![]u8 {
        const total_size = @sizeOf(u16) + self.updates.len * @sizeOf(NodeUpdatePayload);
        var buffer = try allocator.alloc(u8, total_size);
        
        // Write count
        const count: u16 = @intCast(self.updates.len);
        @memcpy(buffer[0..2], std.mem.asBytes(&count));
        
        // Write updates
        for (self.updates, 0..) |update, i| {
            const offset = 2 + i * @sizeOf(NodeUpdatePayload);
            @memcpy(buffer[offset..offset + @sizeOf(NodeUpdatePayload)], std.mem.asBytes(&update));
        }
        
        return buffer;
    }
    
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !CompoundPayload {
        if (data.len < 2) return error.InvalidData;
        
        const count = std.mem.readInt(u16, data[0..2], .little);
        if (data.len != 2 + count * @sizeOf(NodeUpdatePayload)) return error.InvalidData;
        
        var updates = try allocator.alloc(NodeUpdatePayload, count);
        
        for (0..count) |i| {
            const offset = 2 + i * @sizeOf(NodeUpdatePayload);
            const update_bytes = data[offset..offset + @sizeOf(NodeUpdatePayload)];
            updates[i] = @as(*const NodeUpdatePayload, @ptrCast(@alignCast(update_bytes.ptr))).*;
        }
        
        return CompoundPayload{ .updates = updates };
    }
};

/// Gossip protocol configuration
pub const GossipConfig = struct {
    node_id: u64,
    bind_address: []const u8 = "0.0.0.0",
    gossip_port: u16 = 7946,
    raft_port: u16 = 8000,
    
    // Protocol timing
    gossip_interval_ms: u32 = 1000, // How often to gossip
    failure_detection_timeout_ms: u32 = 5000, // Ping timeout
    suspect_timeout_ms: u32 = 10000, // How long to keep suspected nodes
    dead_timeout_ms: u32 = 30000, // How long to keep dead nodes
    
    // Protocol parameters
    gossip_fanout: u8 = 3, // How many nodes to gossip to each round
    indirect_ping_count: u8 = 3, // How many nodes to use for indirect ping
    max_compound_messages: u8 = 10, // Max updates per compound message
    
    // Bootstrap
    bootstrap_nodes: []const []const u8 = &[_][]const u8{}, // Initial seed nodes
    bootstrap_timeout_ms: u32 = 30000, // How long to wait for bootstrap
    
    pub fn fromConfig(global_config: config.Config) GossipConfig {
        return GossipConfig{
            .node_id = global_config.raft_node_id, // Reuse Raft node ID
            .gossip_port = global_config.raft_port - 1, // Default: Raft port - 1
            .raft_port = global_config.raft_port,
            .gossip_interval_ms = 1000,
            .failure_detection_timeout_ms = global_config.cluster_failure_detection_ms / 2,
            .suspect_timeout_ms = global_config.cluster_failure_detection_ms,
            .dead_timeout_ms = global_config.cluster_failure_detection_ms * 3,
        };
    }
};

/// Gossip protocol state machine
pub const GossipProtocol = struct {
    allocator: std.mem.Allocator,
    config: GossipConfig,
    
    // Local node info
    local_node: NodeInfo,
    
    // Cluster membership
    members: std.AutoHashMap(u64, NodeInfo),
    suspected_members: std.AutoHashMap(u64, u64), // node_id -> suspect_timestamp
    
    // Network
    socket: std.posix.socket_t,
    bind_address: net.Address,
    
    // Protocol state
    sequence_number: u32 = 0,
    last_gossip_time: u64 = 0,
    
    // Bootstrap state
    bootstrap_complete: bool = false,
    bootstrap_start_time: u64 = 0,
    
    // Statistics
    ping_count: u64 = 0,
    gossip_count: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, gossip_config: GossipConfig) !GossipProtocol {
        // Create local node info
        const local_node = try NodeInfo.fromAddress(
            gossip_config.node_id,
            gossip_config.bind_address,
            gossip_config.gossip_port,
            gossip_config.raft_port
        );
        
        // Create UDP socket
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        
        // Bind to address
        const bind_addr = try net.Address.parseIp(gossip_config.bind_address, gossip_config.gossip_port);
        try std.posix.bind(socket, &bind_addr.any, bind_addr.getOsSockLen());
        
        std.debug.print("Gossip protocol listening on {s}:{}\n", .{ gossip_config.bind_address, gossip_config.gossip_port });
        
        return GossipProtocol{
            .allocator = allocator,
            .config = gossip_config,
            .local_node = local_node,
            .members = std.AutoHashMap(u64, NodeInfo).init(allocator),
            .suspected_members = std.AutoHashMap(u64, u64).init(allocator),
            .socket = socket,
            .bind_address = bind_addr,
        };
    }
    
    pub fn deinit(self: *GossipProtocol) void {
        std.posix.close(self.socket);
        self.members.deinit();
        self.suspected_members.deinit();
    }
    
    /// Start the gossip protocol
    pub fn start(self: *GossipProtocol) !void {
        std.debug.print("Starting gossip protocol for node {}\n", .{self.config.node_id});
        
        // Start bootstrap process
        if (self.config.bootstrap_nodes.len > 0) {
            try self.bootstrap();
        } else {
            std.debug.print("No bootstrap nodes configured, starting as single node cluster\n", .{});
            self.bootstrap_complete = true;
        }
        
        // Main gossip loop
        while (true) {
            try self.tick();
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms tick
        }
    }
    
    /// Bootstrap by contacting seed nodes
    fn bootstrap(self: *GossipProtocol) !void {
        std.debug.print("Bootstrapping with {} seed nodes\n", .{self.config.bootstrap_nodes.len});
        self.bootstrap_start_time = @intCast(std.time.milliTimestamp());
        
        // Send alive messages to all bootstrap nodes
        for (self.config.bootstrap_nodes) |bootstrap_addr| {
            self.sendAliveToBootstrapNode(bootstrap_addr) catch |err| {
                std.debug.print("Failed to contact bootstrap node {s}: {}\n", .{ bootstrap_addr, err });
            };
        }
    }
    
    fn sendAliveToBootstrapNode(self: *GossipProtocol, addr_str: []const u8) !void {
        // Parse address (assume format "ip:port")
        var addr_parts = std.mem.split(u8, addr_str, ":");
        const ip = addr_parts.next() orelse return error.InvalidAddress;
        const port_str = addr_parts.next() orelse return error.InvalidAddress;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        
        const target_addr = try net.Address.parseIp(ip, port);
        
        // Send alive message
        try self.sendAlive(target_addr, self.local_node);
    }
    
    /// Main protocol tick
    pub fn tick(self: *GossipProtocol) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        
        // Handle incoming messages
        try self.receiveMessages();
        
        // Check bootstrap timeout
        if (!self.bootstrap_complete) {
            if (now - self.bootstrap_start_time > self.config.bootstrap_timeout_ms) {
                std.debug.print("Bootstrap timeout, proceeding as single node\n", .{});
                self.bootstrap_complete = true;
            }
        }
        
        // Periodic gossip
        if (now - self.last_gossip_time > self.config.gossip_interval_ms) {
            try self.doGossipRound();
            self.last_gossip_time = now;
        }
        
        // Failure detection
        try self.detectFailures(now);
        
        // Cleanup old entries
        try self.cleanup(now);
    }
    
    /// Receive and process incoming messages
    fn receiveMessages(self: *GossipProtocol) !void {
        var buffer: [4096]u8 = undefined;
        var from_addr: net.Address = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(net.Address);
        
        // Non-blocking receive
        const bytes_received = std.posix.recvfrom(
            self.socket,
            &buffer,
            0, // No flags (non-blocking would need MSG.DONTWAIT but we use short timeouts)
            &from_addr.any,
            &from_len
        ) catch |err| switch (err) {
            error.WouldBlock => return, // No messages
            else => return err,
        };
        
        if (bytes_received >= @sizeOf(GossipMessage)) {
            try self.processMessage(buffer[0..bytes_received], from_addr);
        }
    }
    
    /// Process a received gossip message
    fn processMessage(self: *GossipProtocol, data: []const u8, from: net.Address) !void {
        if (data.len < @sizeOf(GossipMessage)) return;
        
        const message = @as(*const GossipMessage, @ptrCast(@alignCast(data.ptr))).*;
        const payload = data[@sizeOf(GossipMessage)..];
        
        if (!message.isValid(payload)) {
            std.debug.print("Invalid gossip message received\n", .{});
            return;
        }
        
        // Don't process our own messages
        if (message.sender_id == self.config.node_id) return;
        
        switch (message.message_type) {
            .ping => try self.handlePing(message, payload, from),
            .ping_req => try self.handlePingReq(message, payload, from),
            .ack => try self.handleAck(message, payload),
            .alive => try self.handleAlive(message, payload),
            .suspect => try self.handleSuspect(message, payload),
            .dead => try self.handleDead(message, payload),
            .compound => try self.handleCompound(message, payload),
        }
    }
    
    fn handlePing(self: *GossipProtocol, message: GossipMessage, payload: []const u8, from: net.Address) !void {
        _ = payload; // Ping has no payload
        
        // Send ACK back
        try self.sendAck(from, message.sender_id, message.sequence);
        
        self.ping_count += 1;
    }
    
    fn handlePingReq(self: *GossipProtocol, message: GossipMessage, payload: []const u8, from: net.Address) !void {
        if (payload.len != @sizeOf(PingPayload)) return;
        
        const ping_payload = @as(*const PingPayload, @ptrCast(@alignCast(payload.ptr))).*;
        
        // Find target node and ping it on behalf of requester
        if (self.members.get(ping_payload.target_id)) |target_node| {
            const target_addr = target_node.getSocketAddress();
            try self.sendPing(target_addr, ping_payload.target_id);
        }
        
        // Send ACK to requester
        try self.sendAck(from, message.sender_id, message.sequence);
    }
    
    fn handleAck(self: *GossipProtocol, message: GossipMessage, payload: []const u8) !void {
        _ = self; // Would update pending ping tracking in production
        _ = payload; // ACK has no payload
        
        // Mark node as alive (would update pending ping tracking)
        std.debug.print("Received ACK from node {}\n", .{message.sender_id});
    }
    
    fn handleAlive(self: *GossipProtocol, message: GossipMessage, payload: []const u8) !void {
        _ = message; // Message header already validated
        if (payload.len != @sizeOf(NodeUpdatePayload)) return;
        
        const update = @as(*const NodeUpdatePayload, @ptrCast(@alignCast(payload.ptr))).*;
        
        // Update or add member
        try self.updateMember(update.node);
        
        // Mark bootstrap as complete if we got a response
        if (!self.bootstrap_complete) {
            std.debug.print("Bootstrap successful, received alive from node {}\n", .{update.node.id});
            self.bootstrap_complete = true;
        }
    }
    
    fn handleSuspect(self: *GossipProtocol, message: GossipMessage, payload: []const u8) !void {
        if (payload.len != @sizeOf(NodeUpdatePayload)) return;
        
        const update = @as(*const NodeUpdatePayload, @ptrCast(@alignCast(payload.ptr))).*;
        
        // If it's about us, refute with an alive message
        if (update.node.id == self.config.node_id) {
            try self.refuteSuspicion();
            return;
        }
        
        // Update member state
        if (self.members.getPtr(update.node.id)) |member| {
            member.state = .suspected;
            const now = @as(u64, @intCast(std.time.milliTimestamp()));
            try self.suspected_members.put(update.node.id, now);
        }
        
        std.debug.print("Node {} suspected by {}\n", .{ update.node.id, message.sender_id });
    }
    
    fn handleDead(self: *GossipProtocol, message: GossipMessage, payload: []const u8) !void {
        if (payload.len != @sizeOf(NodeUpdatePayload)) return;
        
        const update = @as(*const NodeUpdatePayload, @ptrCast(@alignCast(payload.ptr))).*;
        
        // If it's about us, refute with an alive message
        if (update.node.id == self.config.node_id) {
            try self.refuteSuspicion();
            return;
        }
        
        // Mark member as dead
        if (self.members.getPtr(update.node.id)) |member| {
            member.state = .dead;
            _ = self.suspected_members.remove(update.node.id);
        }
        
        std.debug.print("Node {} declared dead by {}\n", .{ update.node.id, message.sender_id });
    }
    
    fn handleCompound(self: *GossipProtocol, message: GossipMessage, payload: []const u8) !void {
        const compound = CompoundPayload.deserialize(self.allocator, payload) catch return;
        defer self.allocator.free(compound.updates);
        
        for (compound.updates) |update| {
            try self.updateMember(update.node);
        }
        
        std.debug.print("Processed {} updates from node {}\n", .{ compound.updates.len, message.sender_id });
    }
    
    /// Perform one round of gossip
    fn doGossipRound(self: *GossipProtocol) !void {
        if (self.members.count() == 0) return; // No one to gossip with
        
        // Select random nodes to gossip with
        const target_count = @min(self.config.gossip_fanout, @as(u8, @intCast(self.members.count())));
        
        // Create compound message with recent updates
        var updates = std.ArrayList(NodeUpdatePayload).init(self.allocator);
        defer updates.deinit();
        
        // Always include ourselves
        try updates.append(NodeUpdatePayload{ .node = self.local_node });
        
        // Add other alive members
        var member_iter = self.members.valueIterator();
        while (member_iter.next()) |member| {
            if (member.state == .alive and updates.items.len < self.config.max_compound_messages) {
                try updates.append(NodeUpdatePayload{ .node = member.* });
            }
        }
        
        const compound = CompoundPayload{ .updates = updates.items };
        
        // Send to random targets
        var sent_count: u8 = 0;
        var member_iter2 = self.members.iterator();
        while (member_iter2.next()) |entry| {
            if (sent_count >= target_count) break;
            
            const target_node = entry.value_ptr;
            if (target_node.state == .alive) {
                const target_addr = target_node.getSocketAddress();
                self.sendCompound(target_addr, compound) catch |err| {
                    std.debug.print("Failed to gossip to node {}: {}\n", .{ target_node.id, err });
                };
                sent_count += 1;
            }
        }
        
        self.gossip_count += 1;
        std.debug.print("Gossip round {}: sent to {} nodes\n", .{ self.gossip_count, sent_count });
    }
    
    /// Update or add a member
    fn updateMember(self: *GossipProtocol, node: NodeInfo) !void {
        const existing = self.members.get(node.id);
        
        if (existing) |current| {
            // Only update if incarnation is newer
            if (node.incarnation > current.incarnation) {
                try self.members.put(node.id, node);
                _ = self.suspected_members.remove(node.id);
                std.debug.print("Updated member {}: state={}, incarnation={}\n", 
                    .{ node.id, @tagName(node.state), node.incarnation });
            }
        } else {
            // New member
            try self.members.put(node.id, node);
            std.debug.print("Added new member {}: state={}\n", .{ node.id, @tagName(node.state) });
        }
    }
    
    /// Detect node failures
    fn detectFailures(self: *GossipProtocol, now: u64) !void {
        // Check suspected nodes for timeout
        var suspected_iter = self.suspected_members.iterator();
        while (suspected_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const suspect_time = entry.value_ptr.*;
            
            if (now - suspect_time > self.config.suspect_timeout_ms) {
                // Declare node dead
                if (self.members.getPtr(node_id)) |member| {
                    member.state = .dead;
                    try self.broadcastDead(member.*);
                }
                _ = self.suspected_members.remove(node_id);
            }
        }
    }
    
    /// Clean up old dead nodes
    fn cleanup(self: *GossipProtocol, now: u64) !void {
        _ = now; // Would track dead timestamps in production
        
        // Remove dead nodes after dead_timeout_ms
        var to_remove = std.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();
        
        var member_iter = self.members.iterator();
        while (member_iter.next()) |entry| {
            const node = entry.value_ptr;
            if (node.state == .dead) {
                // In production, check if node has been dead for dead_timeout_ms
                try to_remove.append(node.id);
            }
        }
        
        for (to_remove.items) |node_id| {
            _ = self.members.remove(node_id);
            std.debug.print("Removed dead node {}\n", .{node_id});
        }
    }
    
    /// Send alive message to refute suspicion
    fn refuteSuspicion(self: *GossipProtocol) !void {
        self.local_node.incarnation += 1; // Increment to override suspicion
        
        // Broadcast alive message
        try self.broadcastAlive(self.local_node);
        std.debug.print("Refuted suspicion with incarnation {}\n", .{self.local_node.incarnation});
    }
    
    /// Get current cluster membership
    pub fn getMembers(self: *GossipProtocol, allocator: std.mem.Allocator) ![]NodeInfo {
        var alive_members = std.ArrayList(NodeInfo).init(allocator);
        defer alive_members.deinit();
        
        // Add ourselves
        try alive_members.append(self.local_node);
        
        // Add alive members
        var member_iter = self.members.valueIterator();
        while (member_iter.next()) |member| {
            if (member.state == .alive) {
                try alive_members.append(member.*);
            }
        }
        
        return alive_members.toOwnedSlice();
    }
    
    /// Check if bootstrap is complete
    pub fn isBootstrapComplete(self: *GossipProtocol) bool {
        return self.bootstrap_complete;
    }
    
    // Network helper methods
    
    fn sendMessage(self: *GossipProtocol, addr: net.Address, msg_type: GossipMessageType, payload: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        
        if (@sizeOf(GossipMessage) + payload.len > buffer.len) return error.MessageTooLarge;
        
        self.sequence_number += 1;
        
        var message = GossipMessage{
            .message_type = msg_type,
            .sender_id = self.config.node_id,
            .sequence = self.sequence_number,
            .checksum = 0, // Will be calculated
            .payload_size = @intCast(payload.len),
        };
        
        message.checksum = message.calculateChecksum(payload);
        
        // Copy message + payload to buffer
        @memcpy(buffer[0..@sizeOf(GossipMessage)], std.mem.asBytes(&message));
        if (payload.len > 0) {
            @memcpy(buffer[@sizeOf(GossipMessage)..@sizeOf(GossipMessage) + payload.len], payload);
        }
        
        const total_size = @sizeOf(GossipMessage) + payload.len;
        _ = try std.posix.sendto(self.socket, buffer[0..total_size], 0, &addr.any, addr.getOsSockLen());
    }
    
    fn sendPing(self: *GossipProtocol, addr: net.Address, target_id: u64) !void {
        const payload = PingPayload{
            .target_id = target_id,
            .incarnation = self.local_node.incarnation,
        };
        try self.sendMessage(addr, .ping, std.mem.asBytes(&payload));
    }
    
    fn sendAck(self: *GossipProtocol, addr: net.Address, target_id: u64, sequence: u32) !void {
        _ = target_id; // ACK doesn't need payload, just header info
        _ = sequence; // Would use in production for request/response matching
        try self.sendMessage(addr, .ack, &[_]u8{});
    }
    
    fn sendAlive(self: *GossipProtocol, addr: net.Address, node: NodeInfo) !void {
        const payload = NodeUpdatePayload{ .node = node };
        try self.sendMessage(addr, .alive, std.mem.asBytes(&payload));
    }
    
    fn sendCompound(self: *GossipProtocol, addr: net.Address, compound: CompoundPayload) !void {
        const payload = try compound.serialize(self.allocator);
        defer self.allocator.free(payload);
        try self.sendMessage(addr, .compound, payload);
    }
    
    fn broadcastAlive(self: *GossipProtocol, node: NodeInfo) !void {
        var member_iter = self.members.valueIterator();
        while (member_iter.next()) |member| {
            if (member.state == .alive) {
                const addr = member.getSocketAddress();
                self.sendAlive(addr, node) catch continue;
            }
        }
    }
    
    fn broadcastDead(self: *GossipProtocol, node: NodeInfo) !void {
        const payload = NodeUpdatePayload{ .node = node };
        
        var member_iter = self.members.valueIterator();
        while (member_iter.next()) |member| {
            if (member.state == .alive) {
                const addr = member.getSocketAddress();
                self.sendMessage(addr, .dead, std.mem.asBytes(&payload)) catch continue;
            }
        }
    }
}; 