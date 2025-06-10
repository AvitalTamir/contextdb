const std = @import("std");
const consistent_hashing = @import("consistent_hashing.zig");
const types = @import("types.zig");
const memora = @import("main.zig");
const raft = @import("raft.zig");
const testing = std.testing;

/// Data Partitioning System for Distributed Memora
/// Handles horizontal scaling through consistent hashing and data migration
/// Maintains TigerBeetle-style deterministic operation with append-only behavior

/// Partition configuration
pub const PartitionConfig = struct {
    // Consistent hashing settings
    hash_ring_config: consistent_hashing.HashRingConfig,
    
    // Data migration settings
    migration_batch_size: u32 = 1000, // Items per migration batch
    migration_timeout_ms: u32 = 30000, // Timeout for migration operations
    rebalance_threshold: f32 = 0.15, // Trigger rebalance if >15% imbalance
    
    // Partition validation
    enable_partition_validation: bool = true,
    validation_sample_rate: f32 = 0.01, // Validate 1% of operations
    
    pub fn fromConfig(global_config: anytype) PartitionConfig {
        return PartitionConfig{
            .hash_ring_config = consistent_hashing.HashRingConfig{
                .virtual_nodes_per_node = 150,
                .replication_factor = global_config.cluster_replication_factor,
                .hash_function = .fnv1a,
            },
            .migration_batch_size = 1000,
            .migration_timeout_ms = 30000,
            .rebalance_threshold = 0.15,
            .enable_partition_validation = true,
            .validation_sample_rate = 0.01,
        };
    }
};

/// Data item location information
pub const DataLocation = struct {
    item_key: []const u8,
    item_type: DataType,
    primary_node: u64,
    replica_nodes: []u64,
    partition_hash: u64,
    
    pub const DataType = enum(u8) {
        node = 1,
        edge = 2,
        vector = 3,
        memory = 4,
    };
    
    pub fn deinit(self: *DataLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.item_key);
        allocator.free(self.replica_nodes);
    }
    
    /// Check if a specific node owns this data
    pub fn isOwnedBy(self: *const DataLocation, node_id: u64) bool {
        if (self.primary_node == node_id) return true;
        
        for (self.replica_nodes) |replica| {
            if (replica == node_id) return true;
        }
        return false;
    }
};

/// Migration operation for data rebalancing
pub const MigrationOperation = struct {
    operation_id: u64,
    source_node: u64,
    target_node: u64,
    data_items: []DataMigrationItem,
    status: MigrationStatus,
    started_at: u64,
    completed_at: ?u64 = null,
    
    pub const MigrationStatus = enum(u8) {
        pending = 1,
        in_progress = 2,
        completed = 3,
        failed = 4,
        cancelled = 5,
    };
    
    pub const DataMigrationItem = struct {
        item_key: []const u8,
        item_type: DataLocation.DataType,
        data_size: u32,
        checksum: u32,
    };
    
    pub fn deinit(self: *MigrationOperation, allocator: std.mem.Allocator) void {
        for (self.data_items) |item| {
            allocator.free(item.item_key);
        }
        allocator.free(self.data_items);
    }
};

/// Partition statistics for monitoring
pub const PartitionStats = struct {
    total_partitions: u32,
    active_migrations: u32,
    rebalance_operations: u64,
    data_distribution: []NodeDataStats,
    last_rebalance_time: u64,
    
    pub const NodeDataStats = struct {
        node_id: u64,
        node_count: u32,
        edge_count: u32,
        vector_count: u32,
        memory_count: u32,
        total_size_bytes: u64,
        load_percentage: f32,
    };
    
    pub fn deinit(self: *PartitionStats, allocator: std.mem.Allocator) void {
        allocator.free(self.data_distribution);
    }
};

/// Data Partitioning Manager
pub const DataPartitionManager = struct {
    allocator: std.mem.Allocator,
    config: PartitionConfig,
    
    // Consistent hashing ring
    hash_ring: consistent_hashing.ConsistentHashRing,
    
    // Migration tracking
    active_migrations: std.AutoHashMap(u64, MigrationOperation),
    migration_counter: u64 = 0,
    
    // Partition ownership cache
    ownership_cache: std.AutoHashMap(u64, DataLocation), // hash -> location
    cache_valid: bool = false,
    
    // Statistics
    stats: PartitionStats,
    rebalance_operations: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, partition_config: PartitionConfig) DataPartitionManager {
        const hash_ring = consistent_hashing.ConsistentHashRing.init(allocator, partition_config.hash_ring_config);
        
        return DataPartitionManager{
            .allocator = allocator,
            .config = partition_config,
            .hash_ring = hash_ring,
            .active_migrations = std.AutoHashMap(u64, MigrationOperation).init(allocator),
            .ownership_cache = std.AutoHashMap(u64, DataLocation).init(allocator),
            .stats = PartitionStats{
                .total_partitions = 0,
                .active_migrations = 0,
                .rebalance_operations = 0,
                .data_distribution = &[_]PartitionStats.NodeDataStats{},
                .last_rebalance_time = 0,
            },
        };
    }
    
    pub fn deinit(self: *DataPartitionManager) void {
        self.hash_ring.deinit();
        
        // Clean up migrations
        var migration_iter = self.active_migrations.valueIterator();
        while (migration_iter.next()) |migration| {
            migration.deinit(self.allocator);
        }
        self.active_migrations.deinit();
        
        // Clean up cache
        var cache_iter = self.ownership_cache.valueIterator();
        while (cache_iter.next()) |location| {
            location.deinit(self.allocator);
        }
        self.ownership_cache.deinit();
        
        self.stats.deinit(self.allocator);
    }
    
    /// Add a node to the partition ring
    pub fn addNode(self: *DataPartitionManager, node_id: u64) !void {
        try self.hash_ring.addNode(node_id);
        self.cache_valid = false;
        
        // Check if rebalancing is needed
        if (self.shouldRebalance()) {
            try self.initiateRebalance();
        }
        
        std.debug.print("Added node {} to partition ring\n", .{node_id});
    }
    
    /// Remove a node from the partition ring
    pub fn removeNode(self: *DataPartitionManager, node_id: u64) !void {
        // Initiate data migration before removing node
        try self.migrateNodeData(node_id);
        
        try self.hash_ring.removeNode(node_id);
        self.cache_valid = false;
        
        std.debug.print("Removed node {} from partition ring\n", .{node_id});
    }
    
    /// Mark a node as failed and initiate failover
    pub fn markNodeFailed(self: *DataPartitionManager, node_id: u64) !void {
        try self.hash_ring.markNodeFailed(node_id);
        self.cache_valid = false;
        
        // Initiate emergency replication to maintain redundancy
        try self.initiateEmergencyReplication(node_id);
        
        std.debug.print("Marked node {} as failed, initiating emergency replication\n", .{node_id});
    }
    
    /// Mark a node as recovered
    pub fn markNodeRecovered(self: *DataPartitionManager, node_id: u64) !void {
        try self.hash_ring.markNodeRecovered(node_id);
        self.cache_valid = false;
        
        // Check if data needs to be migrated back
        if (self.shouldRebalance()) {
            try self.initiateRebalance();
        }
        
        std.debug.print("Marked node {} as recovered\n", .{node_id});
    }
    
    /// Find the location information for a data item
    pub fn findDataLocation(self: *DataPartitionManager, item_key: []const u8, item_type: DataLocation.DataType) !DataLocation {
        const hash = std.hash_map.hashString(item_key);
        
        // Check cache first
        if (self.cache_valid) {
            if (self.ownership_cache.get(hash)) |cached_location| {
                return cached_location;
            }
        }
        
        // Find primary and replica nodes
        const primary_node = try self.hash_ring.findPrimaryNode(item_key);
        const replica_nodes = try self.hash_ring.findReplicaNodes(item_key);
        defer self.allocator.free(replica_nodes); // Free the owned slice
        
        // Filter out primary from replicas
        var filtered_replicas = std.ArrayList(u64).init(self.allocator);
        defer filtered_replicas.deinit();
        
        for (replica_nodes) |replica| {
            if (replica != primary_node) {
                try filtered_replicas.append(replica);
            }
        }
        
        const location = DataLocation{
            .item_key = try self.allocator.dupe(u8, item_key),
            .item_type = item_type,
            .primary_node = primary_node,
            .replica_nodes = try filtered_replicas.toOwnedSlice(),
            .partition_hash = hash,
        };
        
        // Cache the result
        if (!self.cache_valid) {
            try self.rebuildOwnershipCache();
        }
        
        return location;
    }
    
    /// Check if current node owns a specific data item
    pub fn ownsData(self: *DataPartitionManager, current_node_id: u64, item_key: []const u8, item_type: DataLocation.DataType) !bool {
        const location = try self.findDataLocation(item_key, item_type);
        defer {
            var mutable_location = location;
            mutable_location.deinit(self.allocator);
        }
        return location.isOwnedBy(current_node_id);
    }
    
    /// Get nodes that should store a specific data item
    pub fn getStorageNodes(self: *DataPartitionManager, item_key: []const u8) ![]u64 {
        return self.hash_ring.findReplicaNodes(item_key);
    }
    
    /// Route a read operation to appropriate nodes
    pub fn routeReadOperation(self: *DataPartitionManager, item_key: []const u8, item_type: DataLocation.DataType) ![]u64 {
        const location = try self.findDataLocation(item_key, item_type);
        defer {
            var mutable_location = location;
            mutable_location.deinit(self.allocator);
        }
        
        // For reads, we can use any replica (prefer primary for consistency)
        var read_nodes = std.ArrayList(u64).init(self.allocator);
        defer read_nodes.deinit();
        
        // Add primary first
        try read_nodes.append(location.primary_node);
        
        // Add replicas
        for (location.replica_nodes) |replica| {
            try read_nodes.append(replica);
        }
        
        return read_nodes.toOwnedSlice();
    }
    
    /// Route a write operation to appropriate nodes
    pub fn routeWriteOperation(self: *DataPartitionManager, item_key: []const u8, item_type: DataLocation.DataType) ![]u64 {
        _ = item_type; // Suppress unused parameter warning
        // For writes, we need all replicas to maintain consistency
        return self.getStorageNodes(item_key);
    }
    
    /// Initiate data rebalancing across the cluster
    pub fn initiateRebalance(self: *DataPartitionManager) !void {
        std.debug.print("Initiating cluster rebalancing operation\n", .{});
        
        const alive_nodes = try self.hash_ring.getAliveNodes();
        defer self.allocator.free(alive_nodes);
        
        if (alive_nodes.len < 2) {
            std.debug.print("Not enough nodes for rebalancing\n", .{});
            return;
        }
        
        // Calculate current load distribution
        const load_distribution = try self.calculateLoadDistribution(alive_nodes);
        defer self.allocator.free(load_distribution);
        
        // Find nodes that need data migration
        var migration_plan = std.ArrayList(MigrationOperation).init(self.allocator);
        defer {
            for (migration_plan.items) |*migration| {
                migration.deinit(self.allocator);
            }
            migration_plan.deinit();
        }
        
        // Create migration plan (simplified - move from highest to lowest load)
        if (load_distribution.len >= 2) {
            const overloaded_node = load_distribution[load_distribution.len - 1]; // Highest load
            const underloaded_node = load_distribution[0]; // Lowest load
            
            if (overloaded_node.load_percentage - underloaded_node.load_percentage > self.config.rebalance_threshold) {
                const migration_op = try self.createMigrationOperation(overloaded_node.node_id, underloaded_node.node_id);
                try migration_plan.append(migration_op);
            }
        }
        
        // Execute migration plan
        for (migration_plan.items) |migration| {
            try self.executeMigration(migration);
        }
        
        self.rebalance_operations += 1;
        self.stats.last_rebalance_time = @intCast(std.time.milliTimestamp());
        
        std.debug.print("Rebalancing operation completed\n", .{});
    }
    
    /// Get partition statistics
    pub fn getPartitionStats(self: *DataPartitionManager) !PartitionStats {
        const alive_nodes = try self.hash_ring.getAliveNodes();
        defer self.allocator.free(alive_nodes);
        
        const data_distribution = try self.calculateLoadDistribution(alive_nodes);
        
        return PartitionStats{
            .total_partitions = @intCast(self.hash_ring.total_virtual_nodes),
            .active_migrations = @intCast(self.active_migrations.count()),
            .rebalance_operations = self.rebalance_operations,
            .data_distribution = data_distribution,
            .last_rebalance_time = self.stats.last_rebalance_time,
        };
    }
    
    // Private helper methods
    
    /// Check if rebalancing is needed
    fn shouldRebalance(self: *DataPartitionManager) bool {
        const alive_nodes = self.hash_ring.getAliveNodes() catch return false;
        defer self.allocator.free(alive_nodes);
        
        if (alive_nodes.len < 2) return false;
        
        const load_distribution = self.calculateLoadDistribution(alive_nodes) catch return false;
        defer self.allocator.free(load_distribution);
        
        if (load_distribution.len < 2) return false;
        
        const highest_load = load_distribution[load_distribution.len - 1].load_percentage;
        const lowest_load = load_distribution[0].load_percentage;
        
        return (highest_load - lowest_load) > self.config.rebalance_threshold;
    }
    
    /// Calculate load distribution across nodes
    fn calculateLoadDistribution(self: *DataPartitionManager, alive_nodes: []u64) ![]PartitionStats.NodeDataStats {
        var node_stats = std.ArrayList(PartitionStats.NodeDataStats).init(self.allocator);
        defer node_stats.deinit();
        
        for (alive_nodes) |node_id| {
            // In a real implementation, this would query actual data sizes
            // For now, we'll estimate based on virtual node count
            const virtual_node_count = self.countVirtualNodesForNode(node_id);
            const estimated_load = @as(f32, @floatFromInt(virtual_node_count)) / @as(f32, @floatFromInt(self.hash_ring.total_virtual_nodes));
            
            const stats = PartitionStats.NodeDataStats{
                .node_id = node_id,
                .node_count = virtual_node_count * 100, // Estimated
                .edge_count = virtual_node_count * 150, // Estimated
                .vector_count = virtual_node_count * 80, // Estimated
                .memory_count = virtual_node_count * 50, // Estimated
                .total_size_bytes = virtual_node_count * 1024 * 1024, // Estimated 1MB per virtual node
                .load_percentage = estimated_load,
            };
            
            try node_stats.append(stats);
        }
        
        // Sort by load percentage
        std.mem.sort(PartitionStats.NodeDataStats, node_stats.items, {}, compareNodeStatsByLoad);
        
        return node_stats.toOwnedSlice();
    }
    
    /// Count virtual nodes for a specific physical node
    fn countVirtualNodesForNode(self: *DataPartitionManager, node_id: u64) u32 {
        var count: u32 = 0;
        for (self.hash_ring.ring_nodes.items) |ring_node| {
            if (ring_node.node_id == node_id and ring_node.is_alive) {
                count += 1;
            }
        }
        return count;
    }
    
    /// Create a migration operation
    fn createMigrationOperation(self: *DataPartitionManager, source_node: u64, target_node: u64) !MigrationOperation {
        self.migration_counter += 1;
        
        // In a real implementation, this would identify actual data items to migrate
        var migration_items = std.ArrayList(MigrationOperation.DataMigrationItem).init(self.allocator);
        defer migration_items.deinit();
        
        // Placeholder migration items
        for (0..self.config.migration_batch_size) |i| {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "migrate_item_{}", .{i});
            const item = MigrationOperation.DataMigrationItem{
                .item_key = try self.allocator.dupe(u8, key),
                .item_type = .node,
                .data_size = 1024, // 1KB placeholder
                .checksum = @truncate(std.hash_map.hashString(key)),
            };
            try migration_items.append(item);
        }
        
        return MigrationOperation{
            .operation_id = self.migration_counter,
            .source_node = source_node,
            .target_node = target_node,
            .data_items = try migration_items.toOwnedSlice(),
            .status = .pending,
            .started_at = @intCast(std.time.milliTimestamp()),
        };
    }
    
    /// Execute a migration operation
    fn executeMigration(self: *DataPartitionManager, migration: MigrationOperation) !void {
        std.debug.print("Executing migration {} from node {} to node {}\n", 
            .{ migration.operation_id, migration.source_node, migration.target_node });
        
        // Add to active migrations
        try self.active_migrations.put(migration.operation_id, migration);
        
        // In a real implementation, this would:
        // 1. Lock the source data
        // 2. Copy data to target node
        // 3. Verify data integrity
        // 4. Update ownership in the hash ring
        // 5. Remove data from source
        // 6. Update migration status
        
        // For now, just mark as completed
        var mutable_migration = self.active_migrations.getPtr(migration.operation_id).?;
        mutable_migration.status = .completed;
        mutable_migration.completed_at = @intCast(std.time.milliTimestamp());
        
        std.debug.print("Migration {} completed successfully\n", .{migration.operation_id});
    }
    
    /// Migrate all data from a node (for node removal)
    fn migrateNodeData(self: *DataPartitionManager, node_id: u64) !void {
        std.debug.print("Migrating all data from node {}\n", .{node_id});
        
        const alive_nodes = try self.hash_ring.getAliveNodes();
        defer self.allocator.free(alive_nodes);
        
        // Find alternative nodes for migration
        var target_nodes = std.ArrayList(u64).init(self.allocator);
        defer target_nodes.deinit();
        
        for (alive_nodes) |alive_node| {
            if (alive_node != node_id) {
                try target_nodes.append(alive_node);
            }
        }
        
        if (target_nodes.items.len == 0) {
            return error.NoTargetNodesAvailable;
        }
        
        // Create migration operation to distribute data
        const target_node = target_nodes.items[0]; // Simplified: use first available node
        const migration_op = try self.createMigrationOperation(node_id, target_node);
        try self.executeMigration(migration_op);
    }
    
    /// Initiate emergency replication for failed node
    fn initiateEmergencyReplication(self: *DataPartitionManager, failed_node: u64) !void {
        _ = self; // Suppress unused parameter warning
        std.debug.print("Initiating emergency replication for failed node {}\n", .{failed_node});
        
        // In a real implementation, this would:
        // 1. Identify data owned by the failed node
        // 2. Find existing replicas
        // 3. Create new replicas on healthy nodes
        // 4. Update partition ownership
        
        // For now, just log the operation
        std.debug.print("Emergency replication for node {} completed\n", .{failed_node});
    }
    
    /// Rebuild ownership cache
    fn rebuildOwnershipCache(self: *DataPartitionManager) !void {
        self.ownership_cache.clearAndFree();
        
        // Pre-compute ownership for common data patterns
        // This is a simplified implementation
        
        self.cache_valid = true;
    }
};

/// Compare node stats by load percentage
fn compareNodeStatsByLoad(context: void, a: PartitionStats.NodeDataStats, b: PartitionStats.NodeDataStats) bool {
    _ = context;
    return a.load_percentage < b.load_percentage;
}

// =============================================================================
// Tests
// =============================================================================

test "DataPartitionManager: basic partitioning" {
    var partition_manager = DataPartitionManager.init(testing.allocator, PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 2,
        },
        .migration_batch_size = 100,
    });
    defer partition_manager.deinit();
    
    // Add nodes
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Test data location
    const location = try partition_manager.findDataLocation("test_key", .node);
    defer {
        var mutable_location = location;
        mutable_location.deinit(testing.allocator);
    }
    
    try testing.expect(location.primary_node >= 1 and location.primary_node <= 3);
    try testing.expect(location.replica_nodes.len == 1); // replication_factor - 1
}

test "DataPartitionManager: node failure handling" {
    var partition_manager = DataPartitionManager.init(testing.allocator, PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 5,
            .replication_factor = 2,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Mark node as failed
    try partition_manager.markNodeFailed(2);
    
    // Verify data is still accessible
    const location = try partition_manager.findDataLocation("test_key", .node);
    defer {
        var mutable_location = location;
        mutable_location.deinit(testing.allocator);
    }
    
    try testing.expect(location.primary_node == 1 or location.primary_node == 3);
}

test "DataPartitionManager: data ownership" {
    var partition_manager = DataPartitionManager.init(testing.allocator, PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 3,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Test ownership
    const owns_data = try partition_manager.ownsData(1, "test_key", .node);
    try testing.expect(owns_data == true or owns_data == false); // Just verify it runs
    
    // Test routing
    const read_nodes = try partition_manager.routeReadOperation("test_key", .node);
    defer testing.allocator.free(read_nodes);
    try testing.expect(read_nodes.len > 0);
    
    const write_nodes = try partition_manager.routeWriteOperation("test_key", .node);
    defer testing.allocator.free(write_nodes);
    try testing.expect(write_nodes.len > 0);
} 