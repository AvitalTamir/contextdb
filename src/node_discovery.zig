const std = @import("std");
const gossip = @import("gossip.zig");
const raft = @import("raft.zig");
const config = @import("config.zig");

/// Node Discovery Service
/// Integrates gossip protocol with Raft consensus for automatic cluster formation
/// Provides seamless node discovery without requiring manual cluster configuration

/// Discovery event types
pub const DiscoveryEvent = enum {
    node_joined,    // New node discovered and verified
    node_left,      // Node gracefully departed
    node_failed,    // Node failed (timeout/unreachable)
    cluster_formed, // Initial cluster formation complete
};

/// Event handler callback
pub const EventHandler = *const fn (event: DiscoveryEvent, node: gossip.NodeInfo) void;

/// Node discovery configuration
pub const DiscoveryConfig = struct {
    // Gossip configuration
    gossip_config: gossip.GossipConfig,
    
    // Raft integration
    enable_raft_integration: bool = true,
    raft_bootstrap_threshold: u8 = 3, // Minimum nodes before starting Raft
    
    // Discovery behavior
    auto_cluster_formation: bool = true,
    cluster_size_hint: u8 = 3, // Expected cluster size for optimization
    
    pub fn fromConfig(global_config: config.Config) DiscoveryConfig {
        return DiscoveryConfig{
            .gossip_config = gossip.GossipConfig.fromConfig(global_config),
            .enable_raft_integration = global_config.raft_enable,
            .raft_bootstrap_threshold = global_config.cluster_bootstrap_expect,
            .auto_cluster_formation = global_config.cluster_auto_join,
            .cluster_size_hint = global_config.cluster_bootstrap_expect,
        };
    }
};

/// Node Discovery Service
pub const NodeDiscovery = struct {
    allocator: std.mem.Allocator,
    config: DiscoveryConfig,
    
    // Gossip protocol
    gossip_protocol: gossip.GossipProtocol,
    
    // Cluster state
    discovered_nodes: std.AutoHashMap(u64, gossip.NodeInfo),
    raft_ready_nodes: std.AutoHashMap(u64, bool),
    cluster_formed: bool = false,
    
    // Event handling
    event_handler: ?EventHandler = null,
    
    // Threading
    gossip_thread: ?std.Thread = null,
    running: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, discovery_config: DiscoveryConfig) !NodeDiscovery {
        const gossip_protocol = try gossip.GossipProtocol.init(allocator, discovery_config.gossip_config);
        
        return NodeDiscovery{
            .allocator = allocator,
            .config = discovery_config,
            .gossip_protocol = gossip_protocol,
            .discovered_nodes = std.AutoHashMap(u64, gossip.NodeInfo).init(allocator),
            .raft_ready_nodes = std.AutoHashMap(u64, bool).init(allocator),
        };
    }
    
    pub fn deinit(self: *NodeDiscovery) void {
        self.stop();
        self.gossip_protocol.deinit();
        self.discovered_nodes.deinit();
        self.raft_ready_nodes.deinit();
    }
    
    /// Start the node discovery service
    pub fn start(self: *NodeDiscovery) !void {
        if (self.running) return;
        
        std.debug.print("Starting Node Discovery Service for node {}\n", .{self.config.gossip_config.node_id});
        
        self.running = true;
        
        // Start gossip protocol in background thread
        self.gossip_thread = try std.Thread.spawn(.{}, gossipWorker, .{self});
        
        // Main discovery loop
        while (self.running) {
            try self.discoveryTick();
            std.time.sleep(500 * std.time.ns_per_ms); // 500ms tick
        }
    }
    
    /// Stop the discovery service
    pub fn stop(self: *NodeDiscovery) void {
        if (!self.running) return;
        
        std.debug.print("Stopping Node Discovery Service\n", .{});
        self.running = false;
        
        if (self.gossip_thread) |thread| {
            thread.join();
            self.gossip_thread = null;
        }
    }
    
    /// Set event handler for discovery events
    pub fn setEventHandler(self: *NodeDiscovery, handler: EventHandler) void {
        self.event_handler = handler;
    }
    
    /// Get current discovered nodes (suitable for Raft cluster config)
    pub fn getDiscoveredNodes(self: *NodeDiscovery) ![]gossip.NodeInfo {
        return self.gossip_protocol.getMembers(self.allocator);
    }
    
    /// Get Raft-ready nodes (nodes that have completed gossip bootstrap)
    pub fn getRaftReadyNodes(self: *NodeDiscovery) ![]raft.ClusterConfig.NodeInfo {
        var raft_nodes = std.ArrayList(raft.ClusterConfig.NodeInfo).init(self.allocator);
        defer raft_nodes.deinit();
        
        const members = try self.gossip_protocol.getMembers(self.allocator);
        defer self.allocator.free(members);
        
        for (members) |member| {
            if (member.state == .alive) {
                var addr_buf: [16]u8 = undefined;
                const addr_str = try member.getAddressString(&addr_buf);
                
                // Copy address string for Raft config
                const addr_copy = try self.allocator.dupe(u8, addr_str);
                
                try raft_nodes.append(raft.ClusterConfig.NodeInfo{
                    .id = member.id,
                    .address = addr_copy,
                    .port = member.raft_port,
                });
            }
        }
        
        return raft_nodes.toOwnedSlice();
    }
    
    /// Check if cluster is ready for Raft consensus
    pub fn isClusterReady(self: *NodeDiscovery) bool {
        if (!self.gossip_protocol.isBootstrapComplete()) return false;
        
        const node_count = self.discovered_nodes.count() + 1; // +1 for ourselves
        return node_count >= self.config.raft_bootstrap_threshold;
    }
    
    /// Check if cluster formation is complete
    pub fn isClusterFormed(self: *NodeDiscovery) bool {
        return self.cluster_formed;
    }
    
    /// Force cluster formation (for testing or manual override)
    pub fn forceClusterFormation(self: *NodeDiscovery) void {
        if (!self.cluster_formed) {
            std.debug.print("Forcing cluster formation\n", .{});
            self.cluster_formed = true;
            
            if (self.event_handler) |handler| {
                handler(.cluster_formed, self.gossip_protocol.local_node);
            }
        }
    }
    
    // Private methods
    
    /// Main discovery tick
    fn discoveryTick(self: *NodeDiscovery) !void {
        // Update discovered nodes from gossip
        try self.updateDiscoveredNodes();
        
        // Check for cluster formation
        if (!self.cluster_formed and self.config.auto_cluster_formation) {
            try self.checkClusterFormation();
        }
        
        // Validate Raft readiness
        if (self.config.enable_raft_integration) {
            try self.updateRaftReadiness();
        }
    }
    
    /// Update discovered nodes from gossip protocol
    fn updateDiscoveredNodes(self: *NodeDiscovery) !void {
        const members = try self.gossip_protocol.getMembers(self.allocator);
        defer self.allocator.free(members);
        
        // Track new and departed nodes
        var current_nodes = std.AutoHashMap(u64, bool).init(self.allocator);
        defer current_nodes.deinit();
        
        for (members) |member| {
            try current_nodes.put(member.id, true);
            
            const existing = self.discovered_nodes.get(member.id);
            if (existing == null) {
                // New node discovered
                try self.discovered_nodes.put(member.id, member);
                std.debug.print("Discovered new node: {} ({}:{})\n", 
                    .{ member.id, member.address, member.raft_port });
                
                if (self.event_handler) |handler| {
                    handler(.node_joined, member);
                }
            } else {
                // Update existing node
                try self.discovered_nodes.put(member.id, member);
            }
        }
        
        // Check for departed nodes
        var departed_nodes = std.ArrayList(u64).init(self.allocator);
        defer departed_nodes.deinit();
        
        var discovered_iter = self.discovered_nodes.iterator();
        while (discovered_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            if (!current_nodes.contains(node_id)) {
                try departed_nodes.append(node_id);
            }
        }
        
        // Remove departed nodes
        for (departed_nodes.items) |node_id| {
            if (self.discovered_nodes.get(node_id)) |departed_node| {
                _ = self.discovered_nodes.remove(node_id);
                _ = self.raft_ready_nodes.remove(node_id);
                
                std.debug.print("Node departed: {}\n", .{node_id});
                
                if (self.event_handler) |handler| {
                    handler(.node_left, departed_node);
                }
            }
        }
    }
    
    /// Check if cluster formation should trigger
    fn checkClusterFormation(self: *NodeDiscovery) !void {
        if (self.isClusterReady()) {
            std.debug.print("Cluster formation threshold reached ({} nodes)\n", 
                .{self.discovered_nodes.count() + 1});
            
            self.cluster_formed = true;
            
            if (self.event_handler) |handler| {
                handler(.cluster_formed, self.gossip_protocol.local_node);
            }
        }
    }
    
    /// Update Raft readiness status for nodes
    fn updateRaftReadiness(self: *NodeDiscovery) !void {
        // Mark nodes as Raft-ready based on gossip stability
        var discovered_iter = self.discovered_nodes.iterator();
        while (discovered_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            
            // Simple readiness check: alive state and stable for some time
            const is_ready = (node.state == .alive);
            
            const was_ready = self.raft_ready_nodes.get(node_id) orelse false;
            if (is_ready != was_ready) {
                try self.raft_ready_nodes.put(node_id, is_ready);
                std.debug.print("Node {} Raft readiness: {}\n", .{ node_id, is_ready });
            }
        }
    }
    
    /// Worker function for gossip protocol thread
    fn gossipWorker(self: *NodeDiscovery) void {
        std.debug.print("Starting gossip protocol worker\n", .{});
        
        // Simple gossip tick loop
        // In production, this would be the full gossip.start() method
        while (self.running) {
            self.gossip_protocol.tick() catch |err| {
                std.debug.print("Gossip tick error: {}\n", .{err});
            };
            std.time.sleep(100 * std.time.ns_per_ms); // 100ms tick
        }
        
        std.debug.print("Gossip protocol worker stopped\n", .{});
    }
};

/// Create a cluster configuration from discovered nodes
pub fn createClusterConfigFromDiscovery(allocator: std.mem.Allocator, discovery: *NodeDiscovery) !raft.ClusterConfig {
    _ = allocator; // May be used for future allocations
    const raft_nodes = try discovery.getRaftReadyNodes();
    
    return raft.ClusterConfig{
        .nodes = raft_nodes,
    };
}

/// Bootstrap helper for single-node development
pub fn createSingleNodeCluster(allocator: std.mem.Allocator, node_id: u64, raft_port: u16) !raft.ClusterConfig {
    var nodes = try allocator.alloc(raft.ClusterConfig.NodeInfo, 1);
    
    const address = try allocator.dupe(u8, "127.0.0.1");
    nodes[0] = raft.ClusterConfig.NodeInfo{
        .id = node_id,
        .address = address,
        .port = raft_port,
    };
    
    return raft.ClusterConfig{
        .nodes = nodes,
    };
}

// Helper functions for common discovery patterns

/// Create discovery config for local development
pub fn createDevConfig(node_id: u64) DiscoveryConfig {
    const gossip_config = gossip.GossipConfig{
        .node_id = node_id,
        .gossip_port = 7946 + @as(u16, @intCast(node_id - 1)), // Unique ports for local testing
        .raft_port = 8000 + @as(u16, @intCast(node_id - 1)),
        .bootstrap_nodes = &[_][]const u8{}, // No bootstrap for single node
    };
    
    return DiscoveryConfig{
        .gossip_config = gossip_config,
        .raft_bootstrap_threshold = 1, // Allow single-node clusters
        .auto_cluster_formation = true,
    };
}

/// Create discovery config for multi-node cluster
pub fn createClusterConfig(node_id: u64, bootstrap_nodes: []const []const u8) DiscoveryConfig {
    const gossip_config = gossip.GossipConfig{
        .node_id = node_id,
        .gossip_port = 7946,
        .raft_port = 8000,
        .bootstrap_nodes = bootstrap_nodes,
    };
    
    return DiscoveryConfig{
        .gossip_config = gossip_config,
        .raft_bootstrap_threshold = 3,
        .auto_cluster_formation = true,
        .cluster_size_hint = @intCast(bootstrap_nodes.len + 1),
    };
} 