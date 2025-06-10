const std = @import("std");
const memora = @import("main.zig");
const raft = @import("raft.zig");
const raft_network = @import("raft_network.zig");
const config = @import("config.zig");
const partitioning = @import("partitioning.zig");
const recovery = @import("recovery.zig");
const split_brain_protection = @import("split_brain_protection.zig");
const testing = std.testing;

/// Distributed Memora with Raft consensus
/// Provides high availability through leader election and log replication
/// Maintains TigerBeetle-style deterministic operation within each node

/// State machine operations for Memora
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
    // Memora configuration
    memora_config: memora.MemoraConfig,
    
    // Raft configuration
    node_id: u64,
    raft_port: u16,
    cluster_nodes: []const ClusterNode,
    
    // Replication settings
    replication_factor: u8 = 3, // How many copies of data
    read_quorum: u8 = 2, // Minimum nodes for read operations
    write_quorum: u8 = 2, // Minimum nodes for write operations
    
    // Data partitioning settings
    enable_data_partitioning: bool = true,
    virtual_nodes_per_node: u16 = 150,
    rebalance_threshold: f32 = 0.15,
    
    // Failover and recovery settings
    enable_automatic_failover: bool = true,
    leader_failure_timeout_ms: u32 = 5000,
    enable_fast_recovery: bool = true,
    
    // Split-brain protection settings
    enable_split_brain_protection: bool = true,
    minimum_quorum_size: u8 = 2,
    conflict_resolution_strategy: split_brain_protection.ConflictConfig.ConflictResolutionStrategy = .vector_clock,
    
    pub const ClusterNode = struct {
        id: u64,
        address: []const u8,
        raft_port: u16,
        memora_port: ?u16 = null, // Optional HTTP API port
    };
};

/// Distributed Memora cluster node
pub const DistributedMemora = struct {
    allocator: std.mem.Allocator,
    config: DistributedConfig,
    
    // Core database engine
    memora: memora.Memora,
    
    // Raft consensus
    raft_node: raft_network.NetworkedRaftNode,
    
    // Data partitioning
    partition_manager: ?partitioning.DataPartitionManager = null,
    
    // Failover and recovery
    recovery_manager: ?recovery.FailoverRecoveryManager = null,
    
    // Split-brain protection
    split_brain_protection: ?split_brain_protection.SplitBrainProtection = null,
    
    // Cluster state
    is_leader: bool = false,
    leader_id: ?u64 = null,
    last_applied_index: u64 = 0,
    
    // Performance metrics
    operation_count: u64 = 0,
    replication_latency_ms: u64 = 0,
    total_failovers: u64 = 0,
    total_recoveries: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, distributed_config: DistributedConfig) !DistributedMemora {
        // Initialize Memora engine
        const memora_engine = try memora.Memora.init(allocator, distributed_config.memora_config);
        
        // Create Raft cluster configuration
        const cluster_config = try createRaftClusterConfig(allocator, distributed_config.cluster_nodes);
        
        // Initialize Raft node
        const raft_node = try raft_network.NetworkedRaftNode.init(
            allocator,
            distributed_config.node_id,
            cluster_config,
            distributed_config.memora_config.data_path,
            distributed_config.raft_port
        );
        
        var distributed_memora = DistributedMemora{
            .allocator = allocator,
            .config = distributed_config,
            .memora = memora_engine,
            .raft_node = raft_node,
        };
        
        // Initialize data partitioning if enabled
        if (distributed_config.enable_data_partitioning) {
            const partition_config = partitioning.PartitionConfig{
                .hash_ring_config = .{
                    .virtual_nodes_per_node = distributed_config.virtual_nodes_per_node,
                    .replication_factor = distributed_config.replication_factor,
                    .hash_function = .fnv1a,
                },
                .rebalance_threshold = distributed_config.rebalance_threshold,
                .enable_partition_validation = true,
            };
            distributed_memora.partition_manager = partitioning.DataPartitionManager.init(allocator, partition_config);
        }
        
        // Initialize failover and recovery if enabled
        if (distributed_config.enable_automatic_failover) {
            const recovery_config = recovery.RecoveryConfig{
                .leader_failure_timeout_ms = distributed_config.leader_failure_timeout_ms,
                .enable_fast_recovery = distributed_config.enable_fast_recovery,
                .require_majority_for_recovery = distributed_config.enable_split_brain_protection,
                .enable_automatic_repair = true,
            };
            distributed_memora.recovery_manager = recovery.FailoverRecoveryManager.init(allocator, recovery_config);
            
            // Connect partition manager to recovery manager
            if (distributed_memora.partition_manager) |*pm| {
                distributed_memora.recovery_manager.?.setPartitionManager(pm);
            }
        }
        
        // Initialize split-brain protection if enabled
        if (distributed_config.enable_split_brain_protection) {
            const conflict_config = split_brain_protection.ConflictConfig{
                .enable_split_brain_protection = true,
                .minimum_quorum_size = distributed_config.minimum_quorum_size,
                .default_resolution_strategy = distributed_config.conflict_resolution_strategy,
                .use_vector_clocks = true,
                .enable_automatic_merge = true,
            };
            distributed_memora.split_brain_protection = split_brain_protection.SplitBrainProtection.init(
                allocator, 
                distributed_config.node_id, 
                conflict_config
            );
        }
        
        // Add this node to partition manager
        if (distributed_memora.partition_manager) |*pm| {
            try pm.addNode(distributed_config.node_id);
        }
        
        std.debug.print("Initialized DistributedMemora node {} with partitioning: {}, recovery: {}, split-brain protection: {}\n", 
            .{ distributed_config.node_id, distributed_config.enable_data_partitioning, 
               distributed_config.enable_automatic_failover, distributed_config.enable_split_brain_protection });
        
        return distributed_memora;
    }
    
    pub fn deinit(self: *DistributedMemora) void {
        // Clean up distributed systems
        if (self.partition_manager) |*pm| {
            pm.deinit();
        }
        if (self.recovery_manager) |*rm| {
            rm.deinit();
        }
        if (self.split_brain_protection) |*sbp| {
            sbp.deinit();
        }
        
        // Clean up core systems
        self.raft_node.deinit();
        self.memora.deinit();
    }
    
    pub fn start(self: *DistributedMemora) !void {
        std.debug.print("Starting DistributedMemora node {}\n", .{self.config.node_id});
        
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
    pub fn insertNode(self: *DistributedMemora, node: memora.types.Node) !void {
        // Check if this node should handle this data using partitioning
        if (self.partition_manager) |*pm| {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "node_{}", .{node.id});
            
            const owns_data = try pm.ownsData(self.config.node_id, key, .node);
            if (!owns_data) {
                // Route to appropriate node
                const storage_nodes = try pm.routeWriteOperation(key, .node);
                defer self.allocator.free(storage_nodes);
                
                std.debug.print("Routing node {} write to nodes: {any}\n", .{ node.id, storage_nodes });
                // In a real implementation, forward to appropriate nodes
                return error.RoutedToOtherNodes;
            }
        }
        
        // Check split-brain protection
        if (self.split_brain_protection) |*sbp| {
            const partition_status = sbp.getPartitionStatus();
            if (!partition_status.has_quorum) {
                return error.InsufficientQuorum;
            }
        }
        
        const operation = StateMachineOperation{
            .operation_type = .insert_node,
            .data_size = @sizeOf(memora.types.Node),
            .checksum = calculateChecksum(std.mem.asBytes(&node)),
        };
        
        // Serialize operation
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(memora.types.Node));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&node));
        
        // Submit to Raft for replication
        const log_index = try self.raft_node.submitEntry(.memora_operation, operation_data);
        
        // Wait for commit (simplified - should use proper async mechanisms)
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Insert an edge (distributed operation)
    pub fn insertEdge(self: *DistributedMemora, edge: memora.types.Edge) !void {
        const operation = StateMachineOperation{
            .operation_type = .insert_edge,
            .data_size = @sizeOf(memora.types.Edge),
            .checksum = calculateChecksum(std.mem.asBytes(&edge)),
        };
        
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(memora.types.Edge));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&edge));
        
        const log_index = try self.raft_node.submitEntry(.memora_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Insert a vector (distributed operation)
    pub fn insertVector(self: *DistributedMemora, vector: memora.types.Vector) !void {
        const operation = StateMachineOperation{
            .operation_type = .insert_vector,
            .data_size = @sizeOf(memora.types.Vector),
            .checksum = calculateChecksum(std.mem.asBytes(&vector)),
        };
        
        var operation_data = try self.allocator.alloc(u8, @sizeOf(StateMachineOperation) + @sizeOf(memora.types.Vector));
        defer self.allocator.free(operation_data);
        
        @memcpy(operation_data[0..@sizeOf(StateMachineOperation)], std.mem.asBytes(&operation));
        @memcpy(operation_data[@sizeOf(StateMachineOperation)..], std.mem.asBytes(&vector));
        
        const log_index = try self.raft_node.submitEntry(.memora_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Batch insert (distributed operation)
    pub fn insertBatch(self: *DistributedMemora, nodes: []const memora.types.Node, edges: []const memora.types.Edge, vectors: []const memora.types.Vector) !void {
        // Serialize batch data
        const nodes_size = nodes.len * @sizeOf(memora.types.Node);
        const edges_size = edges.len * @sizeOf(memora.types.Edge);
        const vectors_size = vectors.len * @sizeOf(memora.types.Vector);
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
        
        const log_index = try self.raft_node.submitEntry(.memora_operation, operation_data);
        try self.waitForCommit(log_index);
        
        self.operation_count += 1;
    }
    
    /// Query operations (read-only, can be performed on any node with proper quorum)
    pub fn querySimilar(self: *DistributedMemora, vector_id: u64, top_k: u32) !std.ArrayList(memora.types.SimilarityResult) {
        // For read operations, ensure we're up-to-date or have read quorum
        if (!self.isReadQuorumAvailable()) {
            return error.InsufficientQuorum;
        }
        
        return self.memora.querySimilar(vector_id, top_k);
    }
    
    pub fn queryRelated(self: *DistributedMemora, start_node_id: u64, depth: u8) !std.ArrayList(memora.types.Node) {
        if (!self.isReadQuorumAvailable()) {
            return error.InsufficientQuorum;
        }
        
        return self.memora.queryRelated(start_node_id, depth);
    }
    
    /// Get cluster status
    pub fn getClusterStatus(self: *DistributedMemora) ClusterStatus {
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
    
    fn tick(self: *DistributedMemora) !void {
        // Check for newly committed entries to apply
        try self.applyCommittedEntries();
        
        // Update leader status
        self.updateLeaderStatus();
        
        // Persist state periodically
        if (self.operation_count % 100 == 0) {
            try self.memora.savePersistentIndexes();
        }
    }
    
    fn applyCommittedEntries(self: *DistributedMemora) !void {
        // Apply any new committed log entries to the state machine
        // This is where we execute the Memora operations
        
        // TODO: Implement proper log entry application
        // For now, this is a placeholder
        _ = self; // Suppress unused parameter warning
    }
    
    fn updateLeaderStatus(self: *DistributedMemora) void {
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
    
    fn waitForCommit(self: *DistributedMemora, log_index: u64) !void {
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
    
    fn isReadQuorumAvailable(self: *DistributedMemora) bool {
        // Simplified quorum check - in production, check actual node availability
        return self.is_leader or self.leader_id != null;
    }
    
    /// Get comprehensive cluster health information
    pub fn getClusterHealth(self: *DistributedMemora) ClusterHealthInfo {
        var health_info = ClusterHealthInfo{
            .node_id = self.config.node_id,
            .is_leader = self.is_leader,
            .leader_id = self.leader_id,
            .operation_count = self.operation_count,
            .replication_latency_ms = self.replication_latency_ms,
            .total_failovers = self.total_failovers,
            .total_recoveries = self.total_recoveries,
            .partition_status = null,
            .recovery_status = null,
            .split_brain_status = null,
        };
        
        // Get partition health if enabled
        if (self.partition_manager) |*pm| {
            const partition_stats = pm.getPartitionStats() catch null;
            if (partition_stats) |stats| {
                health_info.partition_status = PartitionHealthStatus{
                    .total_partitions = stats.total_partitions,
                    .active_migrations = stats.active_migrations,
                    .rebalance_operations = stats.rebalance_operations,
                    .last_rebalance_time = stats.last_rebalance_time,
                };
            }
        }
        
        // Get recovery health if enabled
        if (self.recovery_manager) |*rm| {
            const cluster_health = rm.getClusterHealth();
            health_info.recovery_status = RecoveryHealthStatus{
                .total_nodes = cluster_health.total_nodes,
                .healthy_nodes = cluster_health.healthy_nodes,
                .failed_nodes = cluster_health.failed_nodes,
                .recovering_nodes = cluster_health.recovering_nodes,
                .active_recoveries = cluster_health.active_recoveries,
                .total_failovers = cluster_health.total_failovers,
                .total_recoveries = cluster_health.total_recoveries,
            };
        }
        
        // Get split-brain protection status if enabled
        if (self.split_brain_protection) |*sbp| {
            const partition_status = sbp.getPartitionStatus();
            health_info.split_brain_status = SplitBrainHealthStatus{
                .has_active_partitions = partition_status.has_active_partitions,
                .active_partition_count = partition_status.active_partition_count,
                .in_majority_partition = partition_status.in_majority_partition,
                .has_quorum = partition_status.has_quorum,
                .reachable_nodes = partition_status.reachable_nodes,
                .total_conflicts = partition_status.total_conflicts,
                .unresolved_conflicts = partition_status.unresolved_conflicts,
            };
        }
        
        return health_info;
    }
    
    /// Handle node join event
    pub fn handleNodeJoin(self: *DistributedMemora, node_id: u64) !void {
        std.debug.print("Node {} joining cluster\n", .{node_id});
        
        // Add to partition manager
        if (self.partition_manager) |*pm| {
            try pm.addNode(node_id);
        }
        
        // Update recovery manager
        if (self.recovery_manager) |*rm| {
            try rm.updateNodeHealth(node_id, .follower, 0);
        }
        
        // Update split-brain protection
        if (self.split_brain_protection) |*sbp| {
            try sbp.updateNodeStatus(node_id, true);
        }
    }
    
    /// Handle node leave event
    pub fn handleNodeLeave(self: *DistributedMemora, node_id: u64) !void {
        std.debug.print("Node {} leaving cluster\n", .{node_id});
        
        // Update recovery manager first (for data migration)
        if (self.recovery_manager) |*rm| {
            try rm.markNodeFailed(node_id);
            self.total_failovers += 1;
        }
        
        // Update split-brain protection
        if (self.split_brain_protection) |*sbp| {
            try sbp.updateNodeStatus(node_id, false);
        }
        
        // Remove from partition manager (after data migration)
        if (self.partition_manager) |*pm| {
            try pm.removeNode(node_id);
        }
    }
    
    /// Handle leadership change
    pub fn handleLeadershipChange(self: *DistributedMemora, new_leader_id: u64) !void {
        const old_leader = self.leader_id;
        self.leader_id = new_leader_id;
        self.is_leader = (new_leader_id == self.config.node_id);
        
        std.debug.print("Leadership changed: {} -> {}\n", .{ old_leader orelse 0, new_leader_id });
        
        // Update recovery manager
        if (self.recovery_manager) |*rm| {
            try rm.updateNodeHealth(new_leader_id, .leader, 0);
            
            if (old_leader) |old_id| {
                if (old_id != new_leader_id) {
                    try rm.updateNodeHealth(old_id, .follower, 0);
                    self.total_failovers += 1;
                }
            }
        }
    }
    
    /// Perform periodic maintenance tasks
    pub fn performMaintenance(self: *DistributedMemora) !void {
        // Check for needed rebalancing
        if (self.partition_manager) |*pm| {
            // This would normally be triggered by load imbalance detection
            // For now, just update statistics
            _ = pm.getPartitionStats() catch {};
        }
        
        // Clean up completed recovery operations
        if (self.recovery_manager) |*rm| {
            const active_recoveries = try rm.getActiveRecoveries();
            defer self.allocator.free(active_recoveries);
            
            for (active_recoveries) |recovery_op| {
                if (recovery_op.status == .completed) {
                    self.total_recoveries += 1;
                }
            }
        }
        
        // Check partition status
        if (self.split_brain_protection) |*sbp| {
            try sbp.detectPartition();
        }
    }
};

/// Cluster health information
pub const ClusterHealthInfo = struct {
    node_id: u64,
    is_leader: bool,
    leader_id: ?u64,
    operation_count: u64,
    replication_latency_ms: u64,
    total_failovers: u64,
    total_recoveries: u64,
    partition_status: ?PartitionHealthStatus,
    recovery_status: ?RecoveryHealthStatus,
    split_brain_status: ?SplitBrainHealthStatus,
    
    pub fn isHealthy(self: *const ClusterHealthInfo) bool {
        // Basic health check
        var healthy = true;
        
        if (self.partition_status) |ps| {
            healthy = healthy and (ps.active_migrations == 0);
        }
        
        if (self.recovery_status) |rs| {
            healthy = healthy and (rs.failed_nodes == 0) and (rs.active_recoveries == 0);
        }
        
        if (self.split_brain_status) |sbs| {
            healthy = healthy and !sbs.has_active_partitions and sbs.has_quorum and (sbs.unresolved_conflicts == 0);
        }
        
        return healthy;
    }
};

/// Partition health status
pub const PartitionHealthStatus = struct {
    total_partitions: u32,
    active_migrations: u32,
    rebalance_operations: u64,
    last_rebalance_time: u64,
};

/// Recovery health status
pub const RecoveryHealthStatus = struct {
    total_nodes: u32,
    healthy_nodes: u32,
    failed_nodes: u32,
    recovering_nodes: u32,
    active_recoveries: u32,
    total_failovers: u64,
    total_recoveries: u64,
};

/// Split-brain protection health status
pub const SplitBrainHealthStatus = struct {
    has_active_partitions: bool,
    active_partition_count: u32,
    in_majority_partition: bool,
    has_quorum: bool,
    reachable_nodes: u32,
    total_conflicts: u32,
    unresolved_conflicts: u32,
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

/// Distributed Memora demo
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
    
    const distributed_config = DistributedConfig{
        .memora_config = memora.MemoraConfig{
            .data_path = "distributed_demo/node1",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
    };
    
    // Initialize distributed database
    var distributed_db = try DistributedMemora.init(allocator, distributed_config);
    defer distributed_db.deinit();
    defer std.fs.cwd().deleteTree("distributed_demo") catch {};
    
    std.debug.print("DistributedMemora Demo Started\n", .{});
    std.debug.print("Node ID: {}\n", .{distributed_config.node_id});
    std.debug.print("Cluster size: {}\n", .{cluster_nodes.len});
    
    // Note: In a real demo, you'd start multiple nodes in separate processes
    // For now, just show the configuration
    const status = distributed_db.getClusterStatus();
    std.debug.print("Cluster Status:\n", .{});
    std.debug.print("  Node ID: {}\n", .{status.node_id});
    std.debug.print("  Is Leader: {}\n", .{status.is_leader});
    std.debug.print("  Operations: {}\n", .{status.operation_count});
    
    std.debug.print("DistributedMemora Demo Setup Complete!\n", .{});
    std.debug.print("To run a full cluster, start multiple processes with different node IDs\n", .{});
}

/// Cluster configuration helper
pub const ClusterConfig = struct {
    replication_factor: u8,
    read_quorum: u8,
    write_quorum: u8,
    auto_join: bool,
    bootstrap_expect: u8,
    failure_detection_ms: u32,
    split_brain_protection: bool,
    
    pub fn fromConfig(global_cfg: config.Config) ClusterConfig {
        return ClusterConfig{
            .replication_factor = global_cfg.cluster_replication_factor,
            .read_quorum = global_cfg.cluster_read_quorum,
            .write_quorum = global_cfg.cluster_write_quorum,
            .auto_join = global_cfg.cluster_auto_join,
            .bootstrap_expect = global_cfg.cluster_bootstrap_expect,
            .failure_detection_ms = global_cfg.cluster_failure_detection_ms,
            .split_brain_protection = global_cfg.cluster_split_brain_protection,
        };
    }
};

test "ClusterConfig from global config" {
    const global_config = config.Config{
        .cluster_replication_factor = 5,
        .cluster_read_quorum = 3,
        .cluster_write_quorum = 3,
        .cluster_auto_join = false,
        .cluster_bootstrap_expect = 5,
        .cluster_failure_detection_ms = 15000,
        .cluster_split_brain_protection = false,
    };
    
    const cluster_cfg = ClusterConfig.fromConfig(global_config);
    try std.testing.expect(cluster_cfg.replication_factor == 5);
    try std.testing.expect(cluster_cfg.read_quorum == 3);
    try std.testing.expect(cluster_cfg.write_quorum == 3);
    try std.testing.expect(cluster_cfg.auto_join == false);
    try std.testing.expect(cluster_cfg.bootstrap_expect == 5);
    try std.testing.expect(cluster_cfg.failure_detection_ms == 15000);
    try std.testing.expect(cluster_cfg.split_brain_protection == false);
}

test "ClusterConfig default values" {
    const global_config = config.Config{};
    
    const cluster_cfg = ClusterConfig.fromConfig(global_config);
    try std.testing.expect(cluster_cfg.replication_factor == 3);
    try std.testing.expect(cluster_cfg.read_quorum == 2);
    try std.testing.expect(cluster_cfg.write_quorum == 2);
    try std.testing.expect(cluster_cfg.auto_join == true);
    try std.testing.expect(cluster_cfg.bootstrap_expect == 3);
    try std.testing.expect(cluster_cfg.failure_detection_ms == 10000);
    try std.testing.expect(cluster_cfg.split_brain_protection == true);
}

test "Cluster configuration integration test" {
    // Create a comprehensive global config with both Raft and cluster settings
    const global_config = config.Config{
        .raft_enable = true,
        .raft_node_id = 1,
        .raft_port = 8001,
        .raft_election_timeout_min_ms = 200,
        .raft_election_timeout_max_ms = 400,
        .raft_heartbeat_interval_ms = 75,
        .cluster_replication_factor = 3,
        .cluster_read_quorum = 2,
        .cluster_write_quorum = 2,
        .cluster_auto_join = true,
        .cluster_bootstrap_expect = 3,
        .cluster_failure_detection_ms = 12000,
        .cluster_split_brain_protection = true,
    };
    
    // Test ClusterConfig.fromConfig
    const cluster_cfg = ClusterConfig.fromConfig(global_config);
    try std.testing.expect(cluster_cfg.replication_factor == 3);
    try std.testing.expect(cluster_cfg.read_quorum == 2);
    try std.testing.expect(cluster_cfg.write_quorum == 2);
    try std.testing.expect(cluster_cfg.auto_join == true);
    try std.testing.expect(cluster_cfg.bootstrap_expect == 3);
    try std.testing.expect(cluster_cfg.failure_detection_ms == 12000);
    try std.testing.expect(cluster_cfg.split_brain_protection == true);
    
    // Test RaftConfig.fromConfig as well for integration
    const raft_cfg = raft.RaftConfig.fromConfig(global_config);
    try std.testing.expect(raft_cfg.enable == true);
    try std.testing.expect(raft_cfg.node_id == 1);
    try std.testing.expect(raft_cfg.port == 8001);
    try std.testing.expect(raft_cfg.election_timeout_min_ms == 200);
    try std.testing.expect(raft_cfg.election_timeout_max_ms == 400);
    try std.testing.expect(raft_cfg.heartbeat_interval_ms == 75);
    
    std.debug.print("✓ Cluster configuration integration test passed\n", .{});
}

test "Distributed Memora configuration" {
    const cluster_nodes = [_]DistributedConfig.ClusterNode{
        .{ .id = 1, .address = "127.0.0.1", .raft_port = 8001 },
        .{ .id = 2, .address = "127.0.0.1", .raft_port = 8002 },
        .{ .id = 3, .address = "127.0.0.1", .raft_port = 8003 },
    };
    
    const distributed_config = DistributedConfig{
        .memora_config = .{
            .data_path = "test_distributed_config",
            .enable_persistent_indexes = true,
        },
        .node_id = 1,
        .raft_port = 8001,
        .cluster_nodes = &cluster_nodes,
        .replication_factor = 3,
        .read_quorum = 2,
        .write_quorum = 2,
    };
    
    // Test configuration values
    try testing.expect(distributed_config.node_id == 1);
    try testing.expect(distributed_config.raft_port == 8001);
    try testing.expect(distributed_config.cluster_nodes.len == 3);
    try testing.expect(distributed_config.replication_factor == 3);
    try testing.expect(distributed_config.read_quorum == 2);
    try testing.expect(distributed_config.write_quorum == 2);
    
    // Test cluster node properties
    try testing.expect(distributed_config.cluster_nodes[0].id == 1);
    try testing.expect(std.mem.eql(u8, distributed_config.cluster_nodes[0].address, "127.0.0.1"));
    try testing.expect(distributed_config.cluster_nodes[0].raft_port == 8001);
} 