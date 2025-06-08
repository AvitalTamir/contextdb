const std = @import("std");
const contextdb = @import("main.zig");
const raft = @import("raft.zig");
const raft_network = @import("raft_network.zig");

/// Distributed ContextDB with Raft consensus
/// Provides high availability through leader election and log replication
/// Maintains TigerBeetle-style deterministic operation within each node

/// State machine operations for ContextDB
pub const StateMachineOperation = packed struct {
    operation_type: OperationType,
    data_size: u32,
    checksum: u32,
    // Operation-specific data follows
    
    pub const OperationType = enum(u8) {
        insert_node = 1,
        insert_edge = 2,
        insert_vector = 3,
        batch_insert = 4,
        create_snapshot = 5,
    };
};

/// Distributed configuration
pub const DistributedConfig = struct {
    // ContextDB configuration
    contextdb_config: contextdb.ContextDBConfig,
    
    // Raft configuration
    node_id: u64,
    raft_port: u16,
    cluster_nodes: []const ClusterNode,
    
    // Replication settings
    replication_factor: u8 = 3, // How many copies of data
    read_quorum: u8 = 2, // Minimum nodes for read operations
    write_quorum: u8 = 2, // Minimum nodes for write operations
    
    pub const ClusterNode = struct {
        id: u64,
        address: []const u8,
        raft_port: u16,
        contextdb_port: ?u16 = null, // Optional HTTP API port
    };
};

/// Distributed ContextDB cluster node
pub const DistributedContextDB = struct {
    allocator: std.mem.Allocator,
    config: DistributedConfig,
    
    // Core database engine
    contextdb: contextdb.ContextDB,
    
    // Raft consensus
    raft_node: raft_network.NetworkedRaftNode,
    
    // Cluster state
    is_leader: bool = false,
    leader_id: ?u64 = null,
    last_applied_index: u64 = 0,
    
    // Performance metrics
    operation_count: u64 = 0,
    replication_latency_ms: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, config: DistributedConfig) !DistributedContextDB {
        // Initialize ContextDB engine
        const contextdb_engine = try contextdb.ContextDB.init(allocator, config.contextdb_config);
        
        // Create Raft cluster configuration
        const cluster_config = try createRaftClusterConfig(allocator, config.cluster_nodes);
        
        // Initialize Raft node
        const raft_node = try raft_network.NetworkedRaftNode.init(
            allocator,
            config.node_id,
            cluster_config,
            config.contextdb_config.data_path,
            config.raft_port
        );
        
        return DistributedContextDB{
            .allocator = allocator,
            .config = config,
            .contextdb = contextdb_engine,
            .raft_node = raft_node,
        };
    }
    
    pub fn deinit(self: *DistributedContextDB) void {
        self.raft_node.deinit();
        self.contextdb.deinit();
    }
    
    pub fn start(self: *DistributedContextDB) !void {
        std.debug.print("Starting DistributedContextDB node {}\n", .{self.config.node_id});
        
        // Start Raft consensus in background
        const raft_thread = try std.Thread.spawn(.{}, startRaftNode, .{&self.raft_node});
        raft_thread.detach();
        
        // Main processing loop
        while (true) {
            try self.tick();
            std.time.sleep(1 * std.time.ns_per_ms); // 1ms tick
        }
    }
    
    /// Insert a node (distributed operation)
    pub fn insertNode(self: *DistributedContextDB, node: contextdb.types.Node) !void {
        const operation = StateMachineOperation{
            .operation_type = .insert_node,
            .data_size = @sizeOf(contextdb.types.Node),
            .checksum = calculateChecksum(std.mem.asBytes(&node)),
        };
        
        // Serialize operation
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(contextdb.types.Node));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&node));
        
        // Submit to Raft for replication
        const log_index = try self.raft_node.submitEntry(.contextdb_operation, operation_data);
        
        // Wait for commit (simplified - should use proper async mechanisms)
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Insert an edge (distributed operation)
    pub fn insertEdge(self: *DistributedContextDB, edge: contextdb.types.Edge) !void {
        const operation = StateMachineOperation{
            .operation_type = .insert_edge,
            .data_size = @sizeOf(contextdb.types.Edge),
            .checksum = calculateChecksum(std.mem.asBytes(&edge)),
        };
        
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(contextdb.types.Edge));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&edge));
        
        const log_index = try self.raft_node.submitEntry(.contextdb_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Insert a vector (distributed operation)
    pub fn insertVector(self: *DistributedContextDB, vector: contextdb.types.Vector) !void {
        const operation = StateMachineOperation{
            .operation_type = .insert_vector,
            .data_size = @sizeOf(contextdb.types.Vector),
            .checksum = calculateChecksum(std.mem.asBytes(&vector)),
        };
        
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(contextdb.types.Vector));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&vector));
        
        const log_index = try self.raft_node.submitEntry(.contextdb_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Batch insert (distributed operation)
    pub fn insertBatch(self: *DistributedContextDB, nodes: []const contextdb.types.Node, edges: []const contextdb.types.Edge, vectors: []const contextdb.types.Vector) !void {
        // Serialize batch data
        const nodes_size = nodes.len * @sizeOf(contextdb.types.Node);
        const edges_size = edges.len * @sizeOf(contextdb.types.Edge);
        const vectors_size = vectors.len * @sizeOf(contextdb.types.Vector);
        const total_data_size = nodes_size + edges_size + vectors_size + (3 * @sizeOf(u32)); // Include counts
        
        const operation = StateMachineOperation{
            .operation_type = .batch_insert,
            .data_size = @intCast(total_data_size),
            .checksum = 0, // Calculate after serialization
        };
        
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + total_data_size);
        defer self.allocator.free(operation_data);
        
        // Pack data: operation header + counts + nodes + edges + vectors
        var offset: usize = 0;
        @memcpy(operation_data[offset..offset + @sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        offset += @sizeOf(StateMachineOperation);
        
        // Pack counts
        const node_count: u32 = @intCast(nodes.len);
        const edge_count: u32 = @intCast(edges.len);
        const vector_count: u32 = @intCast(vectors.len);
        
        @memcpy(operation_data[offset..offset + @sizeOf(u32)], std.mem.asBytes(&node_count));
        offset += @sizeOf(u32);
        @memcpy(operation_data[offset..offset + @sizeOf(u32)], std.mem.asBytes(&edge_count));
        offset += @sizeOf(u32);
        @memcpy(operation_data[offset..offset + @sizeOf(u32)], std.mem.asBytes(&vector_count));
        offset += @sizeOf(u32);
        
        // Pack data
        if (nodes.len > 0) {
            @memcpy(operation_data[offset..offset + nodes_size], std.mem.sliceAsBytes(nodes));
            offset += nodes_size;
        }
        if (edges.len > 0) {
            @memcpy(operation_data[offset..offset + edges_size], std.mem.sliceAsBytes(edges));
            offset += edges_size;
        }
        if (vectors.len > 0) {
            @memcpy(operation_data[offset..offset + vectors_size], std.mem.sliceAsBytes(vectors));
            offset += vectors_size;
        }
        
        // Update checksum
        const data_section = operation_data[@sizeOf(StateMachineOperation)..];
        const updated_operation = StateMachineOperation{
            .operation_type = .batch_insert,
            .data_size = @intCast(total_data_size),
            .checksum = calculateChecksum(data_section),
        };
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&updated_operation));
        
        const log_index = try self.raft_node.submitEntry(.contextdb_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Query operations (read-only, can be performed on any node with proper quorum)
    pub fn querySimilar(self: *DistributedContextDB, vector_id: u64, top_k: u32) !std.ArrayList(contextdb.types.SimilarityResult) {
        // For read operations, ensure we're up-to-date or have read quorum
        if (!self.isReadQuorumAvailable()) {
            return error.InsufficientQuorum;
        }
        
        return self.contextdb.querySimilar(vector_id, top_k);
    }
    
    pub fn queryRelated(self: *DistributedContextDB, start_node_id: u64, depth: u8) !std.ArrayList(contextdb.types.Node) {
        if (!self.isReadQuorumAvailable()) {
            return error.InsufficientQuorum;
        }
        
        return self.contextdb.queryRelated(start_node_id, depth);
    }
    
    /// Get cluster status
    pub fn getClusterStatus(self: *DistributedContextDB) ClusterStatus {
        return ClusterStatus{
            .node_id = self.config.node_id,
            .is_leader = self.is_leader,
            .leader_id = self.leader_id,
            .operation_count = self.operation_count,
            .last_applied_index = self.last_applied_index,
            .replication_latency_ms = self.replication_latency_ms,
        };
    }
    
    // Private methods
    
    fn tick(self: *DistributedContextDB) !void {
        // Check for newly committed entries to apply
        try self.applyCommittedEntries();
        
        // Update leader status
        self.updateLeaderStatus();
        
        // Persist state periodically
        if (self.operation_count % 100 == 0) {
            try self.contextdb.savePersistentIndexes();
        }
    }
    
    fn applyCommittedEntries(self: *DistributedContextDB) !void {
        // Apply any new committed log entries to the state machine
        // This is where we execute the ContextDB operations
        
        // TODO: Implement proper log entry application
        // For now, this is a placeholder
        _ = self; // Suppress unused parameter warning
    }
    
    fn updateLeaderStatus(self: *DistributedContextDB) void {
        // Update leadership status based on Raft state
        const raft_state = self.raft_node.raft_node.state;
        const was_leader = self.is_leader;
        
        self.is_leader = (raft_state == .leader);
        
        if (self.is_leader and !was_leader) {
            std.debug.print("Node {} became leader\n", .{self.config.node_id});
        } else if (!self.is_leader and was_leader) {
            std.debug.print("Node {} lost leadership\n", .{self.config.node_id});
        }
    }
    
    fn waitForCommit(self: *DistributedContextDB, log_index: u64) !void {
        // Simplified wait for commit - in production, use proper async mechanisms
        const timeout_ms = 5000; // 5 second timeout
        const start_time = std.time.milliTimestamp();
        
        while (self.last_applied_index < log_index) {
            if (std.time.milliTimestamp() - start_time > timeout_ms) {
                return error.CommitTimeout;
            }
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }
    
    fn isReadQuorumAvailable(self: *DistributedContextDB) bool {
        // Simplified quorum check - in production, check actual node availability
        return self.is_leader or self.leader_id != null;
    }
};

/// Cluster status information
pub const ClusterStatus = struct {
    node_id: u64,
    is_leader: bool,
    leader_id: ?u64,
    operation_count: u64,
    last_applied_index: u64,
    replication_latency_ms: u64,
};

/// Create Raft cluster configuration from distributed config
fn createRaftClusterConfig(allocator: std.mem.Allocator, cluster_nodes: []const DistributedConfig.ClusterNode) !raft.ClusterConfig {
    var node_infos = try allocator.alloc(raft.ClusterConfig.NodeInfo, cluster_nodes.len);
    
    for (cluster_nodes, 0..) |node, i| {
        const address_copy = try allocator.dupe(u8, node.address);
        node_infos[i] = raft.ClusterConfig.NodeInfo{
            .id = node.id,
            .address = address_copy,
            .port = node.raft_port,
        };
    }
    
    return raft.ClusterConfig{
        .nodes = node_infos,
    };
}

/// Start Raft node in separate thread
fn startRaftNode(raft_node: *raft_network.NetworkedRaftNode) void {
    raft_node.start() catch |err| {
        std.debug.print("Raft node failed: {}\n", .{err});
    };
}

/// Calculate CRC32 checksum
fn calculateChecksum(data: []const u8) u32 {
    const Crc32 = std.hash.Crc32;
    return Crc32.hash(data);
}

/// Distributed ContextDB demo
pub fn demo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up any existing demo data
    std.fs.cwd().deleteTree("distributed_demo") catch {};
    
    // Create cluster configuration (3-node cluster)
    const cluster_nodes = [_]DistributedConfig.ClusterNode{
        .{ .id = 1, .address = "127.0.0.1", .raft_port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .raft_port = 8002 },
        .{ .id = 3, .address = "127.0.0.1", .raft_port = 8003 },
    };
    
    const config = DistributedConfig{
        .contextdb_config = contextdb.ContextDBConfig{
            .data_path = "distributed_demo/node1",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
    };
    
    // Initialize distributed database
    var distributed_db = try DistributedContextDB.init(allocator, config);
    defer distributed_db.deinit();
    defer std.fs.cwd().deleteTree("distributed_demo") catch {};
    
    std.debug.print("DistributedContextDB Demo Started\n", .{});
    std.debug.print("Node ID: {}\n", .{config.node_id});
    std.debug.print("Cluster size: {}\n", .{cluster_nodes.len});
    
    // Note: In a real demo, you'd start multiple nodes in separate processes
    // For now, just show the configuration
    const status = distributed_db.getClusterStatus();
    std.debug.print("Cluster Status:\n", .{});
    std.debug.print("  Node ID: {}\n", .{status.node_id});
    std.debug.print("  Is Leader: {}\n", .{status.is_leader});
    std.debug.print("  Operations: {}\n", .{status.operation_count});
    
    std.debug.print("DistributedContextDB Demo Setup Complete!\n", .{});
    std.debug.print("To run a full cluster, start multiple processes with different node IDs\n", .{});
} 