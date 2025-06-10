const std = @import("std");
const raft = @import("raft.zig");
const recovery = @import("recovery.zig");
const partitioning = @import("partitioning.zig");
const testing = std.testing;

/// Split-Brain Protection and Conflict Resolution System
/// Handles network partitions, prevents split-brain scenarios, and resolves conflicts
/// Implements vector clocks and conflict-free replicated data types (CRDTs)

/// Vector clock for distributed conflict resolution
pub const VectorClock = struct {
    clocks: std.AutoHashMap(u64, u64), // node_id -> timestamp
    
    pub fn init(allocator: std.mem.Allocator) VectorClock {
        return VectorClock{
            .clocks = std.AutoHashMap(u64, u64).init(allocator),
        };
    }
    
    pub fn deinit(self: *VectorClock) void {
        self.clocks.deinit();
    }
    
    /// Increment clock for a specific node
    pub fn tick(self: *VectorClock, node_id: u64) !void {
        const current = self.clocks.get(node_id) orelse 0;
        try self.clocks.put(node_id, current + 1);
    }
    
    /// Update clock with received timestamp
    pub fn update(self: *VectorClock, node_id: u64, timestamp: u64) !void {
        const current = self.clocks.get(node_id) orelse 0;
        try self.clocks.put(node_id, @max(current, timestamp));
    }
    
    /// Merge with another vector clock
    pub fn merge(self: *VectorClock, other: *const VectorClock) !void {
        var other_iter = other.clocks.iterator();
        while (other_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const other_timestamp = entry.value_ptr.*;
            const current = self.clocks.get(node_id) orelse 0;
            try self.clocks.put(node_id, @max(current, other_timestamp));
        }
    }
    
    /// Compare with another vector clock
    pub fn compare(self: *const VectorClock, other: *const VectorClock) ClockRelation {
        var self_greater = false;
        var other_greater = false;
        
        // Check all clocks in self
        var self_iter = self.clocks.iterator();
        while (self_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            const self_timestamp = entry.value_ptr.*;
            const other_timestamp = other.clocks.get(node_id) orelse 0;
            
            if (self_timestamp > other_timestamp) {
                self_greater = true;
            } else if (self_timestamp < other_timestamp) {
                other_greater = true;
            }
        }
        
        // Check clocks that exist only in other
        var other_iter = other.clocks.iterator();
        while (other_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            if (!self.clocks.contains(node_id)) {
                const other_timestamp = entry.value_ptr.*;
                if (other_timestamp > 0) {
                    other_greater = true;
                }
            }
        }
        
        if (self_greater and !other_greater) return .happens_before;
        if (other_greater and !self_greater) return .happens_after;
        if (!self_greater and !other_greater) return .concurrent;
        return .concurrent; // Both greater - concurrent
    }
    
    pub const ClockRelation = enum {
        happens_before,  // self happens before other
        happens_after,   // self happens after other
        concurrent,      // concurrent/conflicting
    };
};

/// Conflict resolution configuration
pub const ConflictConfig = struct {
    // Split-brain protection
    enable_split_brain_protection: bool = true,
    minimum_quorum_size: u8 = 2, // Minimum nodes for quorum
    partition_detection_timeout_ms: u32 = 10000, // Time to detect partition
    
    // Conflict resolution strategies
    default_resolution_strategy: ConflictResolutionStrategy = .last_writer_wins,
    use_vector_clocks: bool = true,
    enable_automatic_merge: bool = true,
    
    // CRDT configuration
    enable_crdts: bool = true,
    crdt_sync_interval_ms: u32 = 5000, // Sync CRDTs every 5 seconds
    
    pub const ConflictResolutionStrategy = enum(u8) {
        last_writer_wins = 1,    // Use timestamp to resolve
        vector_clock = 2,        // Use vector clocks
        manual_resolution = 3,   // Require human intervention
        merge_all = 4,           // Attempt to merge all versions
        highest_node_id = 5,     // Use highest node ID as tiebreaker
    };
    
    pub fn fromConfig(global_config: anytype) ConflictConfig {
        return ConflictConfig{
            .enable_split_brain_protection = global_config.cluster_split_brain_protection,
            .minimum_quorum_size = (global_config.cluster_replication_factor + 1) / 2, // Majority
            .partition_detection_timeout_ms = global_config.cluster_failure_detection_ms,
            .default_resolution_strategy = .vector_clock,
            .use_vector_clocks = true,
            .enable_automatic_merge = true,
            .enable_crdts = true,
            .crdt_sync_interval_ms = 5000,
        };
    }
};

/// Network partition information
pub const PartitionInfo = struct {
    partition_id: u64,
    detected_at: u64,
    affected_nodes: []u64,
    majority_partition: bool,
    partition_type: PartitionType,
    resolution_status: ResolutionStatus = .pending,
    
    pub const PartitionType = enum(u8) {
        network_split = 1,       // Network connectivity lost
        node_failure = 2,        // Node completely failed
        leadership_conflict = 3, // Multiple leaders detected
        data_divergence = 4,     // Data has diverged between nodes
    };
    
    pub const ResolutionStatus = enum(u8) {
        pending = 1,
        resolving = 2,
        resolved = 3,
        manual_intervention_required = 4,
    };
    
    pub fn deinit(self: *PartitionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.affected_nodes);
    }
    
    pub fn containsNode(self: *const PartitionInfo, node_id: u64) bool {
        for (self.affected_nodes) |affected_node| {
            if (affected_node == node_id) return true;
        }
        return false;
    }
};

/// Conflict between different data versions
pub const DataConflict = struct {
    conflict_id: u64,
    data_key: []const u8,
    conflicting_versions: []ConflictingVersion,
    vector_clock: VectorClock,
    resolution_strategy: ConflictConfig.ConflictResolutionStrategy,
    resolved: bool = false,
    resolved_value: ?[]const u8 = null,
    
    pub const ConflictingVersion = struct {
        node_id: u64,
        timestamp: u64,
        vector_clock: VectorClock,
        data_value: []const u8,
        checksum: u32,
    };
    
    pub fn deinit(self: *DataConflict, allocator: std.mem.Allocator) void {
        allocator.free(self.data_key);
        for (self.conflicting_versions) |*version| {
            version.vector_clock.deinit();
            allocator.free(version.data_value);
        }
        allocator.free(self.conflicting_versions);
        self.vector_clock.deinit();
        if (self.resolved_value) |value| {
            allocator.free(value);
        }
    }
};

/// Split-Brain Protection Manager
pub const SplitBrainProtection = struct {
    allocator: std.mem.Allocator,
    config: ConflictConfig,
    
    // Partition tracking
    active_partitions: std.AutoHashMap(u64, PartitionInfo),
    partition_counter: u64 = 0,
    
    // Conflict tracking
    active_conflicts: std.AutoHashMap(u64, DataConflict),
    conflict_counter: u64 = 0,
    
    // Vector clock for this node
    local_vector_clock: VectorClock,
    local_node_id: u64,
    
    // Cluster state
    cluster_nodes: std.AutoHashMap(u64, NodeStatus),
    quorum_nodes: std.AutoHashMap(u64, bool), // nodes in current quorum
    
    // Statistics
    total_partitions_detected: u64 = 0,
    total_conflicts_resolved: u64 = 0,
    
    pub const NodeStatus = struct {
        node_id: u64,
        is_reachable: bool,
        last_seen: u64,
        vector_clock: VectorClock,
        in_majority_partition: bool = false,
    };
    
    pub fn init(allocator: std.mem.Allocator, local_node_id: u64, conflict_config: ConflictConfig) SplitBrainProtection {
        return SplitBrainProtection{
            .allocator = allocator,
            .config = conflict_config,
            .active_partitions = std.AutoHashMap(u64, PartitionInfo).init(allocator),
            .active_conflicts = std.AutoHashMap(u64, DataConflict).init(allocator),
            .local_vector_clock = VectorClock.init(allocator),
            .local_node_id = local_node_id,
            .cluster_nodes = std.AutoHashMap(u64, NodeStatus).init(allocator),
            .quorum_nodes = std.AutoHashMap(u64, bool).init(allocator),
        };
    }
    
    pub fn deinit(self: *SplitBrainProtection) void {
        // Clean up partitions
        var partition_iter = self.active_partitions.valueIterator();
        while (partition_iter.next()) |partition| {
            partition.deinit(self.allocator);
        }
        self.active_partitions.deinit();
        
        // Clean up conflicts
        var conflict_iter = self.active_conflicts.valueIterator();
        while (conflict_iter.next()) |conflict| {
            conflict.deinit(self.allocator);
        }
        self.active_conflicts.deinit();
        
        // Clean up vector clocks
        self.local_vector_clock.deinit();
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |node_status| {
            node_status.vector_clock.deinit();
        }
        self.cluster_nodes.deinit();
        self.quorum_nodes.deinit();
    }
    
    /// Update node reachability status
    pub fn updateNodeStatus(self: *SplitBrainProtection, node_id: u64, is_reachable: bool) !void {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        
        if (self.cluster_nodes.getPtr(node_id)) |node_status| {
            node_status.is_reachable = is_reachable;
            node_status.last_seen = if (is_reachable) now else node_status.last_seen;
        } else {
            const node_status = NodeStatus{
                .node_id = node_id,
                .is_reachable = is_reachable,
                .last_seen = now,
                .vector_clock = VectorClock.init(self.allocator),
            };
            try self.cluster_nodes.put(node_id, node_status);
        }
        
        // Check for partition
        if (!is_reachable) {
            try self.detectPartition();
        }
    }
    
    /// Detect network partitions
    pub fn detectPartition(self: *SplitBrainProtection) !void {
        if (!self.config.enable_split_brain_protection) return;
        
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        var unreachable_nodes = std.ArrayList(u64).init(self.allocator);
        defer unreachable_nodes.deinit();
        
        // Find unreachable nodes
        var node_iter = self.cluster_nodes.iterator();
        while (node_iter.next()) |entry| {
            const node_status = entry.value_ptr;
            const time_since_seen = now - node_status.last_seen;
            
            if (!node_status.is_reachable or time_since_seen > self.config.partition_detection_timeout_ms) {
                try unreachable_nodes.append(node_status.node_id);
            }
        }
        
        // If we have unreachable nodes, create partition info
        if (unreachable_nodes.items.len > 0) {
            self.partition_counter += 1;
            
            const partition_info = PartitionInfo{
                .partition_id = self.partition_counter,
                .detected_at = now,
                .affected_nodes = try unreachable_nodes.toOwnedSlice(),
                .majority_partition = self.hasMajorityQuorum(),
                .partition_type = .network_split,
            };
            
            try self.active_partitions.put(partition_info.partition_id, partition_info);
            self.total_partitions_detected += 1;
            
            std.debug.print("Network partition detected: {} unreachable nodes\n", .{partition_info.affected_nodes.len});
            
            // Update quorum status
            try self.updateQuorumStatus();
        }
    }
    
    /// Check if current node set has majority quorum
    pub fn hasMajorityQuorum(self: *SplitBrainProtection) bool {
        var reachable_count: u32 = 1; // Count self as reachable
        
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |node_status| {
            if (node_status.is_reachable) {
                reachable_count += 1;
            }
        }
        
        const total_nodes = self.cluster_nodes.count() + 1; // +1 for self
        const majority_threshold = (total_nodes / 2) + 1;
        
        return reachable_count >= majority_threshold and reachable_count >= self.config.minimum_quorum_size;
    }
    
    /// Handle data write conflict
    pub fn handleWriteConflict(self: *SplitBrainProtection, data_key: []const u8, local_value: []const u8, remote_value: []const u8, remote_node_id: u64, remote_vector_clock: *const VectorClock) !bool {
        // Increment local vector clock
        try self.local_vector_clock.tick(self.local_node_id);
        
        // Compare vector clocks
        const relation = self.local_vector_clock.compare(remote_vector_clock);
        
        switch (relation) {
            .happens_before => {
                // Remote update is newer, accept it
                std.debug.print("Accepting remote write for key {s} (happens after local)\n", .{data_key});
                return true; // Accept remote write
            },
            .happens_after => {
                // Local update is newer, reject remote
                std.debug.print("Rejecting remote write for key {s} (happens before local)\n", .{data_key});
                return false; // Reject remote write
            },
            .concurrent => {
                // Concurrent writes - need conflict resolution
                try self.createDataConflict(data_key, local_value, remote_value, remote_node_id, remote_vector_clock);
                return false; // Conflict needs resolution
            },
        }
    }
    
    /// Create a data conflict for resolution
    fn createDataConflict(self: *SplitBrainProtection, data_key: []const u8, local_value: []const u8, remote_value: []const u8, remote_node_id: u64, remote_vector_clock: *const VectorClock) !void {
        self.conflict_counter += 1;
        
        // Create conflicting versions
        var versions = try self.allocator.alloc(DataConflict.ConflictingVersion, 2);
        
        // Local version
        versions[0] = DataConflict.ConflictingVersion{
            .node_id = self.local_node_id,
            .timestamp = @as(u64, @intCast(std.time.milliTimestamp())),
            .vector_clock = VectorClock.init(self.allocator),
            .data_value = try self.allocator.dupe(u8, local_value),
            .checksum = std.hash.Crc32.hash(local_value),
        };
        try versions[0].vector_clock.merge(&self.local_vector_clock);
        
        // Remote version
        versions[1] = DataConflict.ConflictingVersion{
            .node_id = remote_node_id,
            .timestamp = @as(u64, @intCast(std.time.milliTimestamp())),
            .vector_clock = VectorClock.init(self.allocator),
            .data_value = try self.allocator.dupe(u8, remote_value),
            .checksum = std.hash.Crc32.hash(remote_value),
        };
        try versions[1].vector_clock.merge(remote_vector_clock);
        
        const conflict = DataConflict{
            .conflict_id = self.conflict_counter,
            .data_key = try self.allocator.dupe(u8, data_key),
            .conflicting_versions = versions,
            .vector_clock = VectorClock.init(self.allocator),
            .resolution_strategy = self.config.default_resolution_strategy,
        };
        
        try self.active_conflicts.put(conflict.conflict_id, conflict);
        
        std.debug.print("Created data conflict {} for key {s}\n", .{ conflict.conflict_id, data_key });
        
        // Attempt automatic resolution
        if (self.config.enable_automatic_merge) {
            try self.resolveConflict(conflict.conflict_id);
        }
    }
    
    /// Resolve a data conflict
    pub fn resolveConflict(self: *SplitBrainProtection, conflict_id: u64) !void {
        const conflict = self.active_conflicts.getPtr(conflict_id) orelse return error.ConflictNotFound;
        
        if (conflict.resolved) return; // Already resolved
        
        switch (conflict.resolution_strategy) {
            .last_writer_wins => try self.resolveLWW(conflict),
            .vector_clock => try self.resolveVectorClock(conflict),
            .highest_node_id => try self.resolveHighestNodeId(conflict),
            .merge_all => try self.resolveMergeAll(conflict),
            .manual_resolution => {
                std.debug.print("Conflict {} requires manual resolution\n", .{conflict_id});
                return; // Cannot auto-resolve
            },
        }
        
        if (conflict.resolved) {
            self.total_conflicts_resolved += 1;
            std.debug.print("Resolved conflict {} for key {s}\n", .{ conflict_id, conflict.data_key });
        }
    }
    
    /// Get partition status summary
    pub fn getPartitionStatus(self: *SplitBrainProtection) PartitionStatus {
        var active_partition_count: u32 = 0;
        var majority_partition = false;
        
        var partition_iter = self.active_partitions.valueIterator();
        while (partition_iter.next()) |partition| {
            if (partition.resolution_status != .resolved) {
                active_partition_count += 1;
                if (partition.majority_partition) {
                    majority_partition = true;
                }
            }
        }
        
        return PartitionStatus{
            .has_active_partitions = active_partition_count > 0,
            .active_partition_count = active_partition_count,
            .in_majority_partition = majority_partition,
            .has_quorum = self.hasMajorityQuorum(),
            .reachable_nodes = self.countReachableNodes(),
            .total_conflicts = @intCast(self.active_conflicts.count()),
            .unresolved_conflicts = self.countUnresolvedConflicts(),
        };
    }
    
    // Private helper methods
    
    /// Update quorum status
    fn updateQuorumStatus(self: *SplitBrainProtection) !void {
        self.quorum_nodes.clearAndFree();
        
        // Add self to quorum if we have majority
        if (self.hasMajorityQuorum()) {
            try self.quorum_nodes.put(self.local_node_id, true);
            
            // Add reachable nodes to quorum
            var node_iter = self.cluster_nodes.iterator();
            while (node_iter.next()) |entry| {
                const node_status = entry.value_ptr;
                if (node_status.is_reachable) {
                    try self.quorum_nodes.put(node_status.node_id, true);
                }
            }
        }
    }
    
    /// Count reachable nodes
    fn countReachableNodes(self: *SplitBrainProtection) u32 {
        var count: u32 = 1; // Count self
        
        var node_iter = self.cluster_nodes.valueIterator();
        while (node_iter.next()) |node_status| {
            if (node_status.is_reachable) {
                count += 1;
            }
        }
        
        return count;
    }
    
    /// Count unresolved conflicts
    fn countUnresolvedConflicts(self: *SplitBrainProtection) u32 {
        var count: u32 = 0;
        
        var conflict_iter = self.active_conflicts.valueIterator();
        while (conflict_iter.next()) |conflict| {
            if (!conflict.resolved) {
                count += 1;
            }
        }
        
        return count;
    }
    
    /// Resolve conflict using Last Writer Wins
    fn resolveLWW(self: *SplitBrainProtection, conflict: *DataConflict) !void {
        var latest_timestamp: u64 = 0;
        var winning_version: ?*DataConflict.ConflictingVersion = null;
        
        for (conflict.conflicting_versions) |*version| {
            if (version.timestamp > latest_timestamp) {
                latest_timestamp = version.timestamp;
                winning_version = version;
            }
        }
        
        if (winning_version) |winner| {
            conflict.resolved_value = try self.allocator.dupe(u8, winner.data_value);
            conflict.resolved = true;
        }
    }
    
    /// Resolve conflict using vector clocks
    fn resolveVectorClock(self: *SplitBrainProtection, conflict: *DataConflict) !void {
        // Find the version that happens after all others
        for (conflict.conflicting_versions) |*version_a| {
            var is_latest = true;
            
            for (conflict.conflicting_versions) |*version_b| {
                if (version_a.node_id == version_b.node_id) continue;
                
                const relation = version_a.vector_clock.compare(&version_b.vector_clock);
                if (relation != .happens_after) {
                    is_latest = false;
                    break;
                }
            }
            
            if (is_latest) {
                conflict.resolved_value = try self.allocator.dupe(u8, version_a.data_value);
                conflict.resolved = true;
                return;
            }
        }
        
        // If no clear winner, fall back to LWW
        try self.resolveLWW(conflict);
    }
    
    /// Resolve conflict using highest node ID
    fn resolveHighestNodeId(self: *SplitBrainProtection, conflict: *DataConflict) !void {
        var highest_node_id: u64 = 0;
        var winning_version: ?*DataConflict.ConflictingVersion = null;
        
        for (conflict.conflicting_versions) |*version| {
            if (version.node_id > highest_node_id) {
                highest_node_id = version.node_id;
                winning_version = version;
            }
        }
        
        if (winning_version) |winner| {
            conflict.resolved_value = try self.allocator.dupe(u8, winner.data_value);
            conflict.resolved = true;
        }
    }
    
    /// Resolve conflict by merging all versions
    fn resolveMergeAll(self: *SplitBrainProtection, conflict: *DataConflict) !void {
        // Simplified merge: concatenate all values
        var total_size: usize = 0;
        for (conflict.conflicting_versions) |*version| {
            total_size += version.data_value.len + 1; // +1 for separator
        }
        
        var merged_value = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;
        
        for (conflict.conflicting_versions, 0..) |*version, i| {
            @memcpy(merged_value[offset..offset + version.data_value.len], version.data_value);
            offset += version.data_value.len;
            
            if (i < conflict.conflicting_versions.len - 1) {
                merged_value[offset] = '|'; // Separator
                offset += 1;
            }
        }
        
        conflict.resolved_value = merged_value[0..offset];
        conflict.resolved = true;
    }
};

/// Partition status information
pub const PartitionStatus = struct {
    has_active_partitions: bool,
    active_partition_count: u32,
    in_majority_partition: bool,
    has_quorum: bool,
    reachable_nodes: u32,
    total_conflicts: u32,
    unresolved_conflicts: u32,
    
    pub fn isHealthy(self: *const PartitionStatus) bool {
        return !self.has_active_partitions and 
               self.has_quorum and 
               self.unresolved_conflicts == 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VectorClock: basic operations" {
    var clock = VectorClock.init(testing.allocator);
    defer clock.deinit();
    
    // Test tick and update
    try clock.tick(1);
    try clock.update(2, 5);
    
    try testing.expect(clock.clocks.get(1) == 1);
    try testing.expect(clock.clocks.get(2) == 5);
    
    // Test merge
    var other_clock = VectorClock.init(testing.allocator);
    defer other_clock.deinit();
    
    try other_clock.tick(1);
    try other_clock.tick(1);
    try other_clock.tick(3);
    
    try clock.merge(&other_clock);
    
    try testing.expect(clock.clocks.get(1) == 2); // max(1, 2)
    try testing.expect(clock.clocks.get(2) == 5); // unchanged
    try testing.expect(clock.clocks.get(3) == 1); // new from other
}

test "VectorClock: comparison" {
    var clock1 = VectorClock.init(testing.allocator);
    defer clock1.deinit();
    var clock2 = VectorClock.init(testing.allocator);
    defer clock2.deinit();
    
    // Set up happens-before relationship
    try clock1.update(1, 1);
    try clock1.update(2, 2);
    
    try clock2.update(1, 2);
    try clock2.update(2, 3);
    
    const relation = clock1.compare(&clock2);
    try testing.expect(relation == .happens_before);
}

test "SplitBrainProtection: partition detection" {
    var protection = SplitBrainProtection.init(testing.allocator, 1, ConflictConfig{
        .minimum_quorum_size = 2,
        .partition_detection_timeout_ms = 1000,
    });
    defer protection.deinit();
    
    // Add nodes
    try protection.updateNodeStatus(2, true);
    try protection.updateNodeStatus(3, true);
    
    // Initial state should have quorum
    try testing.expect(protection.hasMajorityQuorum());
    
    // Mark node as unreachable
    try protection.updateNodeStatus(2, false);
    
    // Should still have quorum with 2/3 nodes
    try testing.expect(protection.hasMajorityQuorum());
    
    // Mark another node as unreachable
    try protection.updateNodeStatus(3, false);
    
    // Should lose quorum with 1/3 nodes
    try testing.expect(!protection.hasMajorityQuorum());
}

test "SplitBrainProtection: conflict resolution" {
    var protection = SplitBrainProtection.init(testing.allocator, 1, ConflictConfig{
        .default_resolution_strategy = .last_writer_wins,
        .enable_automatic_merge = true,
    });
    defer protection.deinit();
    
    // Create a remote vector clock
    var remote_clock = VectorClock.init(testing.allocator);
    defer remote_clock.deinit();
    try remote_clock.update(2, 1);
    
    // Test write conflict
    const accept_write = try protection.handleWriteConflict("test_key", "local_value", "remote_value", 2, &remote_clock);
    
    // Should create conflict and not accept remote write immediately
    try testing.expect(!accept_write);
    
    // Should have created a conflict
    try testing.expect(protection.active_conflicts.count() > 0);
} 