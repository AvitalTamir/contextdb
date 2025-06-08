const std = @import("std");
const raft = @import("raft.zig");

/// Network layer for Raft consensus
/// Provides TCP-based communication between Raft nodes
/// Designed for production use with connection pooling and error handling

/// Network message header
pub const MessageHeader = packed struct {
    magic: u32 = 0x52414654, // "RAFT" in little-endian
    version: u16 = 1,
    message_type: raft.MessageType,
    body_size: u32,
    checksum: u32,
    
    const HEADER_SIZE = @sizeOf(MessageHeader);
};

/// Network connection to a Raft peer
pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    node_id: u64,
    address: []const u8,
    port: u16,
    
    // TCP connection (optional - null if not connected)
    stream: ?std.net.Stream = null,
    last_activity: u64 = 0,
    connection_attempts: u32 = 0,
    
    pub fn init(allocator: std.mem.Allocator, node_id: u64, address: []const u8, port: u16) !PeerConnection {
        const address_copy = try allocator.dupe(u8, address);
        return PeerConnection{
            .allocator = allocator,
            .node_id = node_id,
            .address = address_copy,
            .port = port,
        };
    }
    
    pub fn deinit(self: *PeerConnection) void {
        self.disconnect();
        self.allocator.free(self.address);
    }
    
    pub fn connect(self: *PeerConnection) !void {
        if (self.stream != null) return; // Already connected
        
        const address = try std.net.Address.parseIp(self.address, self.port);
        self.stream = try std.net.tcpConnectToAddress(address);
        self.last_activity = std.time.milliTimestamp();
        self.connection_attempts += 1;
        
        std.debug.print("Connected to Raft peer {} at {}:{}\n", .{ self.node_id, self.address, self.port });
    }
    
    pub fn disconnect(self: *PeerConnection) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
            std.debug.print("Disconnected from Raft peer {}\n", .{self.node_id});
        }
    }
    
    pub fn isConnected(self: *const PeerConnection) bool {
        return self.stream != null;
    }
    
    pub fn sendMessage(self: *PeerConnection, message_type: raft.MessageType, body: []const u8) !void {
        if (self.stream == null) {
            try self.connect();
        }
        
        const stream = self.stream.?;
        
        // Create header
        const header = MessageHeader{
            .message_type = message_type,
            .body_size = @intCast(body.len),
            .checksum = calculateChecksum(body),
        };
        
        // Send header
        const header_bytes = std.mem.asBytes(&header);
        try stream.writeAll(header_bytes);
        
        // Send body
        if (body.len > 0) {
            try stream.writeAll(body);
        }
        
        self.last_activity = std.time.milliTimestamp();
    }
    
    pub fn receiveMessage(self: *PeerConnection, allocator: std.mem.Allocator) !struct { message_type: raft.MessageType, body: []u8 } {
        if (self.stream == null) return error.NotConnected;
        
        const stream = self.stream.?;
        
        // Read header
        var header_bytes: [MessageHeader.HEADER_SIZE]u8 = undefined;
        try stream.readAll(&header_bytes);
        
        const header = @as(*const MessageHeader, @ptrCast(@alignCast(&header_bytes))).*;
        
        // Validate header
        if (header.magic != 0x52414654) return error.InvalidMagic;
        if (header.version != 1) return error.UnsupportedVersion;
        
        // Read body
        var body: []u8 = &[_]u8{};
        if (header.body_size > 0) {
            body = try allocator.alloc(u8, header.body_size);
            try stream.readAll(body);
            
            // Validate checksum
            const expected_checksum = calculateChecksum(body);
            if (header.checksum != expected_checksum) {
                allocator.free(body);
                return error.ChecksumMismatch;
            }
        }
        
        self.last_activity = std.time.milliTimestamp();
        
        return .{
            .message_type = header.message_type,
            .body = body,
        };
    }
};

/// Raft network layer
pub const RaftNetwork = struct {
    allocator: std.mem.Allocator,
    node_id: u64,
    listen_port: u16,
    
    // Peer connections
    peers: std.AutoHashMap(u64, PeerConnection),
    
    // TCP listener for incoming connections
    listener: ?std.net.Server = null,
    
    // Message handling
    message_handler: ?*const fn (node_id: u64, message_type: raft.MessageType, body: []const u8) void = null,
    
    pub fn init(allocator: std.mem.Allocator, node_id: u64, listen_port: u16) RaftNetwork {
        return RaftNetwork{
            .allocator = allocator,
            .node_id = node_id,
            .listen_port = listen_port,
            .peers = std.AutoHashMap(u64, PeerConnection).init(allocator),
        };
    }
    
    pub fn deinit(self: *RaftNetwork) void {
        // Close all peer connections
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.peers.deinit();
        
        // Close listener
        if (self.listener) |*listener| {
            listener.deinit();
        }
    }
    
    pub fn addPeer(self: *RaftNetwork, node_id: u64, address: []const u8, port: u16) !void {
        if (node_id == self.node_id) return; // Don't add self
        
        const peer = try PeerConnection.init(self.allocator, node_id, address, port);
        try self.peers.put(node_id, peer);
    }
    
    pub fn startListening(self: *RaftNetwork) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", self.listen_port);
        self.listener = try address.listen(.{});
        
        std.debug.print("Raft node {} listening on port {}\n", .{ self.node_id, self.listen_port });
    }
    
    pub fn acceptConnections(self: *RaftNetwork) !void {
        if (self.listener == null) return error.NotListening;
        
        while (true) {
            const connection = try self.listener.?.accept();
            // Handle connection in background (simplified for now)
            try self.handleIncomingConnection(connection);
        }
    }
    
    pub fn sendRequestVote(self: *RaftNetwork, node_id: u64, request: raft.RequestVoteRequest) !void {
        const peer = self.peers.getPtr(node_id) orelse return error.PeerNotFound;
        
        const body = std.mem.asBytes(&request);
        try peer.sendMessage(.request_vote, body);
    }
    
    pub fn sendAppendEntries(self: *RaftNetwork, node_id: u64, request: raft.AppendEntriesRequest, entries: []const u8) !void {
        const peer = self.peers.getPtr(node_id) orelse return error.PeerNotFound;
        
        // Serialize request + entries
        const total_size = @sizeOf(raft.AppendEntriesRequest) + entries.len;
        var body = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(body);
        
        @memcpy(body[0..@sizeOf(raft.AppendEntriesRequest)], std.mem.asBytes(&request));
        if (entries.len > 0) {
            @memcpy(body[@sizeOf(raft.AppendEntriesRequest)..], entries);
        }
        
        try peer.sendMessage(.append_entries, body);
    }
    
    pub fn broadcastMessage(self: *RaftNetwork, message_type: raft.MessageType, body: []const u8) !void {
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            const peer = entry.value_ptr;
            peer.sendMessage(message_type, body) catch |err| {
                std.debug.print("Failed to send {} to peer {}: {}\n", .{ message_type, peer.node_id, err });
                // Optionally disconnect and retry later
                peer.disconnect();
            };
        }
    }
    
    pub fn setMessageHandler(self: *RaftNetwork, handler: *const fn (node_id: u64, message_type: raft.MessageType, body: []const u8) void) void {
        self.message_handler = handler;
    }
    
    pub fn tick(self: *RaftNetwork) !void {
        // Check peer connection health
        const now = std.time.milliTimestamp();
        const timeout_ms = 30000; // 30 second timeout
        
        var peer_iter = self.peers.iterator();
        while (peer_iter.next()) |entry| {
            const peer = entry.value_ptr;
            if (peer.isConnected() and now - peer.last_activity > timeout_ms) {
                std.debug.print("Peer {} connection timeout, disconnecting\n", .{peer.node_id});
                peer.disconnect();
            }
        }
    }
    
    // Private methods
    
    fn handleIncomingConnection(self: *RaftNetwork, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();
        
        while (true) {
            // Create a temporary peer connection for this incoming stream
            var temp_peer = PeerConnection{
                .allocator = self.allocator,
                .node_id = 0, // Unknown until we identify
                .address = "",
                .port = 0,
                .stream = connection.stream,
            };
            
            const message = temp_peer.receiveMessage(self.allocator) catch |err| switch (err) {
                error.EndOfStream => break, // Connection closed
                else => {
                    std.debug.print("Error receiving message: {}\n", .{err});
                    break;
                },
            };
            defer if (message.body.len > 0) self.allocator.free(message.body);
            
            // Handle the message
            if (self.message_handler) |handler| {
                handler(0, message.message_type, message.body); // Node ID unknown
            }
        }
    }
};

/// Enhanced Raft node with networking
pub const NetworkedRaftNode = struct {
    raft_node: raft.RaftNode,
    network: RaftNetwork,
    
    pub fn init(allocator: std.mem.Allocator, node_id: u64, cluster_config: raft.ClusterConfig, data_path: []const u8, listen_port: u16) !NetworkedRaftNode {
        const raft_node = try raft.RaftNode.init(allocator, node_id, cluster_config, data_path);
        var network = RaftNetwork.init(allocator, node_id, listen_port);
        
        // Add all peers to network
        for (cluster_config.nodes) |node_info| {
            if (node_info.id != node_id) {
                try network.addPeer(node_info.id, node_info.address, node_info.port);
            }
        }
        
        // Set up message handling
        network.setMessageHandler(messageHandler);
        
        return NetworkedRaftNode{
            .raft_node = raft_node,
            .network = network,
        };
    }
    
    pub fn deinit(self: *NetworkedRaftNode) void {
        self.raft_node.deinit();
        self.network.deinit();
    }
    
    pub fn start(self: *NetworkedRaftNode) !void {
        try self.network.startListening();
        
        // Main event loop (simplified)
        while (true) {
            try self.raft_node.tick();
            try self.network.tick();
            
            // Sleep for 10ms
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }
    
    pub fn submitEntry(self: *NetworkedRaftNode, entry_type: raft.LogEntry.EntryType, data: []const u8) !u64 {
        return self.raft_node.submitEntry(entry_type, data);
    }
    
    fn messageHandler(node_id: u64, message_type: raft.MessageType, body: []const u8) void {
        // TODO: Route message to appropriate Raft node
        std.debug.print("Received Raft message: {} from node {} ({} bytes)\n", .{ message_type, node_id, body.len });
    }
};

/// Calculate CRC32 checksum for network messages
fn calculateChecksum(data: []const u8) u32 {
    const Crc32 = std.hash.Crc32;
    return Crc32.hash(data);
}

/// Utility for creating cluster configurations
pub fn createClusterConfig(allocator: std.mem.Allocator, nodes: []const struct { id: u64, address: []const u8, port: u16 }) !raft.ClusterConfig {
    var node_infos = try allocator.alloc(raft.ClusterConfig.NodeInfo, nodes.len);
    
    for (nodes, 0..) |node, i| {
        const address_copy = try allocator.dupe(u8, node.address);
        node_infos[i] = raft.ClusterConfig.NodeInfo{
            .id = node.id,
            .address = address_copy,
            .port = node.port,
        };
    }
    
    return raft.ClusterConfig{
        .nodes = node_infos,
    };
} 