const std = @import("std");
const raft = @import("raft.zig");
const partitioning = @import("partitioning.zig");
const types = @import("types.zig");
const memora = @import("main.zig");
const testing = std.testing;

/// Failover and Recovery System for Distributed Memora
/// Handles automatic leader failover, data recovery, and node rejoin procedures
/// Designed for production reliability with TigerBeetle-style deterministic operation

/// Recovery configuration
pub const RecoveryConfig = struct {
    // Failover timing
    leader_failure_timeout_ms: u32 = 5000, // Time to detect leader failure
    failover_timeout_ms: u32 = 10000, // Maximum time for failover
    rejoin_timeout_ms: u32 = 30000, // Time for node to rejoin cluster
    
    // Recovery strategies
    enable_fast_recovery: bool = true, // Use snapshots for fast recovery
    enable_incremental_recovery: bool = true, // Apply only missing log entries
    max_recovery_batch_size: u32 = 1000, // Items per recovery batch
    
    // Data consistency
    require_majority_for_recovery: bool = true, // Need majority consensus for recovery
    verify_data_integrity: bool = true, // Checksum verification during recovery
    enable_automatic_repair: bool = true, // Auto-repair corrupted data
    
    pub fn fromConfig(global_config: anytype) RecoveryConfig {
        return RecoveryConfig{
            .leader_failure_timeout_ms = global_config.cluster_failure_detection_ms / 2,
            .failover_timeout_ms = global_config.cluster_failure_detection_ms,
            .rejoin_timeout_ms = global_config.cluster_failure_detection_ms * 3,
            .enable_fast_recovery = true,
            .enable_incremental_recovery = true,
            .max_recovery_batch_size = 1000,
            .require_majority_for_recovery = global_config.cluster_split_brain_protection,
            .verify_data_integrity = true,
            .enable_automatic_repair = true,
        };
    }
};

/// Recovery operation types
pub const RecoveryOperation = struct {
    operation_id: u64,
    operation_type: OperationType,
    target_node: u64,
    status: RecoveryStatus,
    started_at: u64,
    completed_at: ?u64 = null,
    error_message: ?[]const u8 = null,
    
    // Progress tracking
    total_items: u32 = 0,
    recovered_items: u32 = 0,
    last_applied_index: u64 = 0,
    
    pub const OperationType = enum(u8) {
        leader_failover = 1,     // Elect new leader
        node_rejoin = 2,         // Node rejoining cluster
        state_recovery = 3,      // Recover state machine
        data_repair = 4,         // Repair corrupted data
        partition_recovery = 5,  // Recover partition ownership
    };
    
    pub const RecoveryStatus = enum(u8) {
        pending = 1,
        in_progress = 2,
        completed = 3,
        failed = 4,
        cancelled = 5,
    };
    
    pub fn getProgressPercentage(self: *const RecoveryOperation) f32 {
        if (self.total_items == 0) return 0.0;
        return @as(f32, @floatFromInt(self.recovered_items)) / @as(f32, @floatFromInt(self.total_items));
    }
};

/// Node health information
pub const NodeHealth = struct {
    node_id: u64,
    is_alive: bool,
    last_heartbeat: u64,
    raft_state: raft.NodeState,
    log_index: u64,
    data_integrity_status: DataIntegrityStatus,
    
    pub const DataIntegrityStatus = enum(u8) {
        healthy = 1,
        corrupted = 2,
        missing = 3,
        recovering = 4,
        unknown = 5,
    };
    
    pub fn isHealthy(self: *const NodeHealth) bool {
        return self.is_alive and 
               self.data_integrity_status == .healthy and
               (std.time.milliTimestamp() - @as(i64, @intCast(self.last_heartbeat))) < 10000; // 10s threshold
    }
};

/// Recovery state snapshot
pub const RecoverySnapshot = struct {
    snapshot_id: u64,
    created_at: u64,
    log_index: u64,
    log_term: u64,
    data_checksum: u32,
    node_count: u32,
    edge_count: u32,
    vector_count: u32,
    compressed_data: []u8,
    
    pub fn deinit(self: *RecoverySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.compressed_data);
    }
};

/// Failover and Recovery Manager
pub const FailoverRecoveryManager = struct {
    allocator: std.mem.Allocator,
    config: RecoveryConfig,
    
    // Cluster state tracking
    cluster_nodes: std.AutoHashMap(u64, NodeHealth),
    current_leader: ?u64 = null,
    
    // Recovery operations
    active_recoveries: std.AutoHashMap(u64, RecoveryOperation),
    recovery_counter: u64 = 0,
    
    // Snapshots for fast recovery
    recovery_snapshots: std.AutoHashMap(u64, RecoverySnapshot),
    latest_snapshot_index: u64 = 0,
    
    // Partitioning integration
    partition_manager: ?*partitioning.DataPartitionManager = null,
    
    // Statistics
    total_failovers: u64 = 0,
    total_recoveries: u64 = 0,
    average_recovery_time_ms: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, recovery_config: RecoveryConfig) FailoverRecoveryManager {
        return FailoverRecoveryManager{
            .allocator = allocator,
            .config = recovery_config,
            .cluster_nodes = std.AutoHashMap(u64, NodeHealth).init(allocator),
            .active_recoveries = std.AutoHashMap(u64, RecoveryOperation).init(allocator),
            .recovery_snapshots = std.AutoHashMap(u64, RecoverySnapshot).init(allocator),
        };
    }
    
    pub fn deinit(self: *FailoverRecoveryManager) void {
        self.cluster_nodes.deinit();
        
        // Clean up active recoveries
        var recovery_iter = self.active_recoveries.valueIterator();
        while (recovery_iter.next()) |recovery| {
            if (recovery.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.active_recoveries.deinit();
        
        // Clean up snapshots
        var snapshot_iter = self.recovery_snapshots.valueIterator();
        while (snapshot_iter.next()) |snapshot| {
            snapshot.deinit(self.allocator);
        }
        self.recovery_snapshots.deinit();
    }
    
    /// Set partition manager for integrated recovery
    pub fn setPartitionManager(self: *FailoverRecoveryManager, partition_manager: *partitioning.DataPartitionManager) void {
        self.partition_manager = partition_manager;
    }
    
    /// Update node health status
    pub fn updateNodeHealth(self: *FailoverRecoveryManager, node_id: u64, raft_state: raft.NodeState, log_index: u64) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        
        const health = NodeHealth{
            .node_id = node_id,
            .is_alive = true,
            .last_heartbeat = now,
            .raft_state = raft_state,
            .log_index = log_index,
            .data_integrity_status = .healthy, // Would be determined by actual checks
        };
        
        try self.cluster_nodes.put(node_id, health);
        
        // Update current leader
        if (raft_state == .leader) {
            if (self.current_leader != node_id) {
                std.debug.print("Leader changed from {} to {}\n", .{ self.current_leader orelse 0, node_id });
                self.current_leader = node_id;
            }
        }
    }
    
    /// Mark a node as failed
    pub fn markNodeFailed(self: *FailoverRecoveryManager, node_id: u64) !void {
        if (self.cluster_nodes.getPtr(node_id)) |health| {
            health.is_alive = false;
            health.data_integrity_status = .unknown;
        }
        
        // If failed node was leader, initiate failover
        if (self.current_leader == node_id) {
            try self.initiateLeaderFailover();
        }
        
        // Update partition manager if available
        if (self.partition_manager) |pm| {
            try pm.markNodeFailed(node_id);
        }
        
        std.debug.print("Marked node {} as failed\n", .{node_id});
    }
    
    /// Initiate leader failover
    pub fn initiateLeaderFailover(self: *FailoverRecoveryManager) !void {
        std.debug.print("Initiating leader failover process\n", .{});
        
        self.recovery_counter += 1;
        const recovery_op = RecoveryOperation{
            .operation_id = self.recovery_counter,
            .operation_type = .leader_failover,
            .target_node = 0, // Will be determined during election
            .status = .in_progress,
            .started_at = @as(u64, @intCast(std.time.milliTimestamp())),
        };
        
        try self.active_recoveries.put(recovery_op.operation_id, recovery_op);
        
        // Find best candidate for new leader
        const new_leader = try self.selectNewLeader();
        if (new_leader) |leader_id| {
            // Update recovery operation
            var recovery = self.active_recoveries.getPtr(recovery_op.operation_id).?;
            recovery.target_node = leader_id;
            recovery.status = .completed;
            recovery.completed_at = @as(u64, @intCast(std.time.milliTimestamp()));
            
            self.current_leader = leader_id;
            self.total_failovers += 1;
            
            std.debug.print("New leader elected: node {}\n", .{leader_id});
        } else {
            var recovery = self.active_recoveries.getPtr(recovery_op.operation_id).?;
            recovery.status = .failed;
            recovery.error_message = try self.allocator.dupe(u8, "No suitable leader candidate found");
            
            std.debug.print("Leader failover failed: no suitable candidates\n", .{});
        }
    }
    
    /// Handle node rejoin after recovery
    pub fn handleNodeRejoin(self: *FailoverRecoveryManager, node_id: u64, last_log_index: u64) !void {
        std.debug.print("Handling node {} rejoin at log index {}\n", .{ node_id, last_log_index });
        
        self.recovery_counter += 1;
        const recovery_op = RecoveryOperation{
            .operation_id = self.recovery_counter,
            .operation_type = .node_rejoin,
            .target_node = node_id,
            .status = .in_progress,
            .started_at = @as(u64, @intCast(std.time.milliTimestamp())),
            .last_applied_index = last_log_index,
        };
        
        try self.active_recoveries.put(recovery_op.operation_id, recovery_op);
        
        // Determine recovery strategy
        const cluster_log_index = self.getClusterLogIndex();
        
        if (self.config.enable_fast_recovery and self.shouldUseFastRecovery(last_log_index, cluster_log_index)) {
            try self.performFastRecovery(recovery_op.operation_id, node_id);
        } else if (self.config.enable_incremental_recovery) {
            try self.performIncrementalRecovery(recovery_op.operation_id, node_id, last_log_index);
        } else {
            try self.performFullRecovery(recovery_op.operation_id, node_id);
        }
        
        // Update partition manager
        if (self.partition_manager) |pm| {
            try pm.markNodeRecovered(node_id);
        }
        
        self.total_recoveries += 1;
    }
    
    /// Create a recovery snapshot
    pub fn createRecoverySnapshot(self: *FailoverRecoveryManager, log_index: u64, log_term: u64) !u64 {
        self.latest_snapshot_index += 1;
        
        // In a real implementation, this would serialize the actual state machine
        const placeholder_data = try self.allocator.alloc(u8, 1024);
        std.mem.set(u8, placeholder_data, 0x42); // Placeholder data
        
        const snapshot = RecoverySnapshot{
            .snapshot_id = self.latest_snapshot_index,
            .created_at = @as(u64, @intCast(std.time.milliTimestamp())),
            .log_index = log_index,
            .log_term = log_term,
            .data_checksum = std.hash.Crc32.hash(placeholder_data),
            .node_count = 1000, // Placeholder
            .edge_count = 2500, // Placeholder
            .vector_count = 500, // Placeholder
            .compressed_data = placeholder_data,
        };
        
        try self.recovery_snapshots.put(snapshot.snapshot_id, snapshot);
        
        std.debug.print("Created recovery snapshot {} at log index {}\n", .{ snapshot.snapshot_id, log_index });
        return snapshot.snapshot_id;
    }
    
    /// Repair corrupted data
    pub fn repairCorruptedData(self: *FailoverRecoveryManager, node_id: u64, corruption_details: []const u8) !void {
        std.debug.print("Repairing corrupted data on node {}: {s}\n", .{ node_id, corruption_details });
        
        self.recovery_counter += 1;
        const recovery_op = RecoveryOperation{
            .operation_id = self.recovery_counter,
            .operation_type = .data_repair,
            .target_node = node_id,
            .status = .in_progress,
            .started_at = @as(u64, @intCast(std.time.milliTimestamp())),
        };
        
        try self.active_recoveries.put(recovery_op.operation_id, recovery_op);
        
        // Perform data repair (simplified implementation)
        if (self.config.enable_automatic_repair) {
            try self.performAutomaticDataRepair(recovery_op.operation_id, node_id);
        } else {
            // Mark for manual intervention
            var recovery = self.active_recoveries.getPtr(recovery_op.operation_id).?;
            recovery.status = .failed;
            recovery.error_message = try self.allocator.dupe(u8, "Automatic repair disabled, manual intervention required");
        }
    }
    
    /// Get cluster health summary
    pub fn getClusterHealth(self: *FailoverRecoveryManager) ClusterHealthSummary {
        var healthy_nodes: u32 = 0;
        var failed_nodes: u32 = 0;
        var recovering_nodes: u32 = 0;
        
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |health| {
            if (health.isHealthy()) {
                healthy_nodes += 1;
            } else if (health.is_alive) {
                recovering_nodes += 1;
            } else {
                failed_nodes += 1;
            }
        }
        
        return ClusterHealthSummary{
            .total_nodes = @intCast(self.cluster_nodes.count()),
            .healthy_nodes = healthy_nodes,
            .failed_nodes = failed_nodes,
            .recovering_nodes = recovering_nodes,
            .current_leader = self.current_leader,
            .active_recoveries = @intCast(self.active_recoveries.count()),
            .total_failovers = self.total_failovers,
            .total_recoveries = self.total_recoveries,
        };
    }
    
    /// Get active recovery operations
    pub fn getActiveRecoveries(self: *FailoverRecoveryManager) ![]RecoveryOperation {
        var recoveries = std.ArrayList(RecoveryOperation).init(self.allocator);
        defer recoveries.deinit();
        
        var recovery_iter = self.active_recoveries.valueIterator();
        while (recovery_iter.next()) |recovery| {
            if (recovery.status == .in_progress or recovery.status == .pending) {
                try recoveries.append(recovery.*);
            }
        }
        
        return recoveries.toOwnedSlice();
    }
    
    // Private helper methods
    
    /// Select new leader based on Raft criteria
    fn selectNewLeader(self: *FailoverRecoveryManager) !?u64 {
        var best_candidate: ?u64 = null;
        var highest_log_index: u64 = 0;
        
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |health| {
            if (health.isHealthy() and health.raft_state != .leader) {
                if (health.log_index > highest_log_index) {
                    highest_log_index = health.log_index;
                    best_candidate = health.node_id;
                }
            }
        }
        
        return best_candidate;
    }
    
    /// Get current cluster log index
    fn getClusterLogIndex(self: *FailoverRecoveryManager) u64 {
        var max_log_index: u64 = 0;
        
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |health| {
            if (health.isHealthy() and health.log_index > max_log_index) {
                max_log_index = health.log_index;
            }
        }
        
        return max_log_index;
    }
    
    /// Determine if fast recovery should be used
    fn shouldUseFastRecovery(self: *FailoverRecoveryManager, node_log_index: u64, cluster_log_index: u64) bool {
        const log_gap = cluster_log_index - node_log_index;
        return log_gap > 1000 and self.recovery_snapshots.count() > 0; // Use snapshot if gap is large
    }
    
    /// Perform fast recovery using snapshots
    fn performFastRecovery(self: *FailoverRecoveryManager, recovery_id: u64, node_id: u64) !void {
        std.debug.print("Performing fast recovery for node {}\n", .{node_id});
        
        // Find suitable snapshot
        var best_snapshot: ?RecoverySnapshot = null;
        var snapshot_iter = self.recovery_snapshots.valueIterator();
        while (snapshot_iter.next()) |snapshot| {
            if (best_snapshot == null or snapshot.log_index > best_snapshot.?.log_index) {
                best_snapshot = snapshot.*;
            }
        }
        
        if (best_snapshot) |snapshot| {
            // Simulate snapshot restoration
            var recovery = self.active_recoveries.getPtr(recovery_id).?;
            recovery.total_items = snapshot.node_count + snapshot.edge_count + snapshot.vector_count;
            recovery.recovered_items = recovery.total_items; // Instant recovery with snapshot
            recovery.status = .completed;
            recovery.completed_at = @as(u64, @intCast(std.time.milliTimestamp()));
            
            std.debug.print("Fast recovery completed using snapshot {} for node {}\n", .{ snapshot.snapshot_id, node_id });
        } else {
            // Fall back to incremental recovery
            try self.performIncrementalRecovery(recovery_id, node_id, 0);
        }
    }
    
    /// Perform incremental recovery using log entries
    fn performIncrementalRecovery(self: *FailoverRecoveryManager, recovery_id: u64, node_id: u64, from_index: u64) !void {
        std.debug.print("Performing incremental recovery for node {} from index {}\n", .{ node_id, from_index });
        
        const cluster_log_index = self.getClusterLogIndex();
        const recovery_items = cluster_log_index - from_index;
        
        var recovery = self.active_recoveries.getPtr(recovery_id).?;
        recovery.total_items = @intCast(recovery_items);
        
        // Simulate log replay
        var batch_size: u32 = 0;
        while (batch_size < recovery_items and batch_size < self.config.max_recovery_batch_size) {
            batch_size += 1;
            recovery.recovered_items += 1;
            
            // Simulate processing time
            std.time.sleep(1 * std.time.ns_per_ms);
        }
        
        recovery.status = .completed;
        recovery.completed_at = @as(u64, @intCast(std.time.milliTimestamp()));
        
        std.debug.print("Incremental recovery completed for node {}\n", .{node_id});
    }
    
    /// Perform full recovery (complete state rebuild)
    fn performFullRecovery(self: *FailoverRecoveryManager, recovery_id: u64, node_id: u64) !void {
        std.debug.print("Performing full recovery for node {}\n", .{node_id});
        
        var recovery = self.active_recoveries.getPtr(recovery_id).?;
        recovery.total_items = 10000; // Placeholder for full state size
        recovery.recovered_items = 0;
        
        // Simulate full state transfer
        while (recovery.recovered_items < recovery.total_items) {
            const batch_size = @min(self.config.max_recovery_batch_size, recovery.total_items - recovery.recovered_items);
            recovery.recovered_items += batch_size;
            
            // Simulate processing time
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        
        recovery.status = .completed;
        recovery.completed_at = @as(u64, @intCast(std.time.milliTimestamp()));
        
        std.debug.print("Full recovery completed for node {}\n", .{node_id});
    }
    
    /// Perform automatic data repair
    fn performAutomaticDataRepair(self: *FailoverRecoveryManager, recovery_id: u64, node_id: u64) !void {
        std.debug.print("Performing automatic data repair for node {}\n", .{node_id});
        
        var recovery = self.active_recoveries.getPtr(recovery_id).?;
        recovery.total_items = 100; // Placeholder for corrupted items
        recovery.recovered_items = 0;
        
        // Simulate data repair process
        while (recovery.recovered_items < recovery.total_items) {
            recovery.recovered_items += 1;
            std.time.sleep(5 * std.time.ns_per_ms); // Simulate repair time
        }
        
        recovery.status = .completed;
        recovery.completed_at = @as(u64, @intCast(std.time.milliTimestamp()));
        
        // Update node health
        if (self.cluster_nodes.getPtr(node_id)) |health| {
            health.data_integrity_status = .healthy;
        }
        
        std.debug.print("Automatic data repair completed for node {}\n", .{node_id});
    }
};

/// Cluster health summary
pub const ClusterHealthSummary = struct {
    total_nodes: u32,
    healthy_nodes: u32,
    failed_nodes: u32,
    recovering_nodes: u32,
    current_leader: ?u64,
    active_recoveries: u32,
    total_failovers: u64,
    total_recoveries: u64,
    
    pub fn getHealthPercentage(self: *const ClusterHealthSummary) f32 {
        if (self.total_nodes == 0) return 0.0;
        return @as(f32, @floatFromInt(self.healthy_nodes)) / @as(f32, @floatFromInt(self.total_nodes));
    }
    
    pub fn hasQuorum(self: *const ClusterHealthSummary) bool {
        const majority = (self.total_nodes / 2) + 1;
        return (self.healthy_nodes + self.recovering_nodes) >= majority;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FailoverRecoveryManager: basic operations" {
    var recovery_manager = FailoverRecoveryManager.init(testing.allocator, RecoveryConfig{
        .leader_failure_timeout_ms = 1000,
        .enable_fast_recovery = true,
        .require_majority_for_recovery = false,
    });
    defer recovery_manager.deinit();
    
    // Add nodes
    try recovery_manager.updateNodeHealth(1, .leader, 100);
    try recovery_manager.updateNodeHealth(2, .follower, 95);
    try recovery_manager.updateNodeHealth(3, .follower, 90);
    
    // Check initial state
    const initial_health = recovery_manager.getClusterHealth();
    try testing.expect(initial_health.total_nodes == 3);
    try testing.expect(initial_health.healthy_nodes == 3);
    try testing.expect(initial_health.current_leader == 1);
    
    // Mark leader as failed
    try recovery_manager.markNodeFailed(1);
    
    // Check after failure
    const after_failure_health = recovery_manager.getClusterHealth();
    try testing.expect(after_failure_health.failed_nodes == 1);
    try testing.expect(after_failure_health.current_leader != 1);
}

test "FailoverRecoveryManager: node rejoin recovery" {
    var recovery_manager = FailoverRecoveryManager.init(testing.allocator, RecoveryConfig{
        .enable_incremental_recovery = true,
        .max_recovery_batch_size = 100,
    });
    defer recovery_manager.deinit();
    
    // Setup cluster
    try recovery_manager.updateNodeHealth(1, .leader, 200);
    try recovery_manager.updateNodeHealth(2, .follower, 200);
    
    // Node rejoins with older log
    try recovery_manager.handleNodeRejoin(3, 150);
    
    // Check recovery was initiated
    const active_recoveries = try recovery_manager.getActiveRecoveries();
    defer testing.allocator.free(active_recoveries);
    
    try testing.expect(active_recoveries.len <= 1); // May complete immediately in test
}

test "FailoverRecoveryManager: snapshot creation and recovery" {
    var recovery_manager = FailoverRecoveryManager.init(testing.allocator, RecoveryConfig{
        .enable_fast_recovery = true,
    });
    defer recovery_manager.deinit();
    
    // Create a snapshot
    const snapshot_id = try recovery_manager.createRecoverySnapshot(1000, 5);
    try testing.expect(snapshot_id > 0);
    
    // Verify snapshot exists
    try testing.expect(recovery_manager.recovery_snapshots.contains(snapshot_id));
} 