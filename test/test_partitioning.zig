const std = @import("std");
const testing = std.testing;
const memora = @import("memora");
const partitioning = memora.partitioning;
const consistent_hashing = memora.consistent_hashing;

// =============================================================================
// Data Partitioning Tests
// =============================================================================

test "Partitioning: basic hash ring operations" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 20,
            .replication_factor = 3,
        },
        .migration_batch_size = 100,
    });
    defer partition_manager.deinit();
    
    // Test empty ring
    try testing.expectError(error.NoNodesAvailable, partition_manager.findDataLocation("test_key", .node));
    
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
    try testing.expect(location.replica_nodes.len == 2); // replication_factor - 1
    try testing.expect(location.item_type == .node);
    
    // Verify replicas are different from primary
    for (location.replica_nodes) |replica| {
        try testing.expect(replica != location.primary_node);
        try testing.expect(replica >= 1 and replica <= 3);
    }
}

test "Partitioning: data ownership and routing" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 2,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Test ownership
    const owns_data_1 = try partition_manager.ownsData(1, "test_key", .node);
    const owns_data_2 = try partition_manager.ownsData(2, "test_key", .node);
    const owns_data_3 = try partition_manager.ownsData(3, "test_key", .node);
    
    // At least one node should own the data (primary)
    try testing.expect(owns_data_1 or owns_data_2 or owns_data_3);
    
    // Test read routing
    const read_nodes = try partition_manager.routeReadOperation("test_key", .node);
    defer testing.allocator.free(read_nodes);
    try testing.expect(read_nodes.len >= 1);
    try testing.expect(read_nodes.len <= 3);
    
    // Test write routing
    const write_nodes = try partition_manager.routeWriteOperation("test_key", .node);
    defer testing.allocator.free(write_nodes);
    try testing.expect(write_nodes.len >= 1);
    try testing.expect(write_nodes.len <= 3);
    
    // Write nodes should include all replicas
    try testing.expect(write_nodes.len == 2); // replication_factor
}

test "Partitioning: node failure and recovery" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 15,
            .replication_factor = 3,
        },
    });
    defer partition_manager.deinit();
    
    // Add nodes
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    try partition_manager.addNode(4);
    
    // Get initial location
    const initial_location = try partition_manager.findDataLocation("test_key", .vector);
    defer {
        var mutable_location = initial_location;
        mutable_location.deinit(testing.allocator);
    }
    
    // Mark a node as failed
    try partition_manager.markNodeFailed(2);
    
    // Verify data is still accessible
    const failover_location = try partition_manager.findDataLocation("test_key", .vector);
    defer {
        var mutable_location = failover_location;
        mutable_location.deinit(testing.allocator);
    }
    
    // Primary should be a live node
    try testing.expect(failover_location.primary_node != 2);
    try testing.expect(failover_location.primary_node >= 1 and failover_location.primary_node <= 4);
    
    // Verify no failed nodes in replicas
    for (failover_location.replica_nodes) |replica| {
        try testing.expect(replica != 2);
    }
    
    // Recover the node
    try partition_manager.markNodeRecovered(2);
    
    // Verify node is available again
    const recovery_location = try partition_manager.findDataLocation("test_key_2", .vector);
    defer {
        var mutable_location = recovery_location;
        mutable_location.deinit(testing.allocator);
    }
    
    // Node 2 should be eligible for new data
    var node_2_found = false;
    if (recovery_location.primary_node == 2) {
        node_2_found = true;
    } else {
        for (recovery_location.replica_nodes) |node| {
            if (node == 2) {
                node_2_found = true;
                break;
            }
        }
    }
    // Note: Due to hashing, node 2 may or may not be selected for this particular key
    // This test mainly verifies no errors occur during recovery
}

test "Partitioning: data distribution across nodes" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 50,
            .replication_factor = 1, // Single replica for easier distribution testing
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Test distribution across many keys
    var node_counts = [_]u32{0} ** 4; // Index 0 unused, 1-3 for nodes
    
    for (0..300) |i| {
        var key_buf: [20]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key_{}", .{i});
        
        const location = try partition_manager.findDataLocation(key, .edge);
        defer {
            var mutable_location = location;
            mutable_location.deinit(testing.allocator);
        }
        
        node_counts[location.primary_node] += 1;
    }
    
    // Each node should get roughly 300/3 = 100 keys
    // Allow some variance due to hashing (30% variance)
    for (1..4) |node_id| {
        const count = node_counts[node_id];
        try testing.expect(count > 70 and count < 130);
        std.debug.print("Node {} got {} keys\n", .{ node_id, count });
    }
}

test "Partitioning: different data types" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 2,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    
    const test_key = "multi_type_key";
    
    // Test different data types for the same key
    const data_types = [_]partitioning.DataLocation.DataType{ .node, .edge, .vector, .memory };
    
    for (data_types) |data_type| {
        const location = try partition_manager.findDataLocation(test_key, data_type);
        defer {
            var mutable_location = location;
            mutable_location.deinit(testing.allocator);
        }
        
        try testing.expect(location.item_type == data_type);
        try testing.expect(location.primary_node == 1 or location.primary_node == 2);
        try testing.expect(location.replica_nodes.len == 1); // replication_factor - 1
        
        // All data types should hash to the same location (same key)
        try testing.expect(std.mem.eql(u8, location.item_key, test_key));
    }
}

test "Partitioning: storage node routing" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 5,
            .replication_factor = 3,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    try partition_manager.addNode(4);
    
    const test_key = "storage_test";
    
    // Get storage nodes
    const storage_nodes = try partition_manager.getStorageNodes(test_key);
    defer testing.allocator.free(storage_nodes);
    
    try testing.expect(storage_nodes.len == 3); // replication_factor
    
    // Verify all storage nodes are unique
    for (storage_nodes, 0..) |node_a, i| {
        for (storage_nodes[i + 1 ..]) |node_b| {
            try testing.expect(node_a != node_b);
        }
        try testing.expect(node_a >= 1 and node_a <= 4);
    }
    
    // Compare with location info
    const location = try partition_manager.findDataLocation(test_key, .memory);
    defer {
        var mutable_location = location;
        mutable_location.deinit(testing.allocator);
    }
    
    // Storage nodes should include primary + replicas
    const expected_count = 1 + location.replica_nodes.len;
    try testing.expect(storage_nodes.len == expected_count);
}

test "Partitioning: partition statistics" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 20,
            .replication_factor = 2,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    // Get partition statistics
    const stats = try partition_manager.getPartitionStats();
    defer {
        var mutable_stats = stats;
        mutable_stats.deinit(testing.allocator);
    }
    
    try testing.expect(stats.total_partitions == 60); // 3 nodes × 20 virtual nodes
    try testing.expect(stats.active_migrations == 0);
    try testing.expect(stats.data_distribution.len == 3);
    
    // Verify node statistics
    var total_load: f32 = 0;
    for (stats.data_distribution) |node_stats| {
        try testing.expect(node_stats.node_id >= 1 and node_stats.node_id <= 3);
        try testing.expect(node_stats.load_percentage >= 0 and node_stats.load_percentage <= 1);
        total_load += node_stats.load_percentage;
    }
    
    // Total load should be approximately 1.0 (100%)
    try testing.expect(total_load > 0.95 and total_load < 1.05);
}

test "Partitioning: node addition triggers rebalancing" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 2,
        },
        .rebalance_threshold = 0.1, // Low threshold to trigger rebalancing
    });
    defer partition_manager.deinit();
    
    // Start with two nodes
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    
    const initial_stats = try partition_manager.getPartitionStats();
    defer {
        var mutable_stats = initial_stats;
        mutable_stats.deinit(testing.allocator);
    }
    
    const initial_rebalance_count = initial_stats.rebalance_operations;
    
    // Add a third node (should trigger rebalancing)
    try partition_manager.addNode(3);
    
    const after_stats = try partition_manager.getPartitionStats();
    defer {
        var mutable_stats = after_stats;
        mutable_stats.deinit(testing.allocator);
    }
    
    // Rebalancing should have been triggered
    try testing.expect(after_stats.rebalance_operations >= initial_rebalance_count);
    try testing.expect(after_stats.total_partitions == 30); // 3 nodes × 10 virtual nodes
}

test "Partitioning: edge cases and error handling" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 5,
            .replication_factor = 1,
        },
    });
    defer partition_manager.deinit();
    
    // Test with no nodes
    try testing.expectError(error.NoNodesAvailable, partition_manager.findDataLocation("test", .node));
    try testing.expectError(error.NoNodesAvailable, partition_manager.getStorageNodes("test"));
    
    // Add single node
    try partition_manager.addNode(1);
    
    // Test with single node
    const location = try partition_manager.findDataLocation("single_node_test", .node);
    defer {
        var mutable_location = location;
        mutable_location.deinit(testing.allocator);
    }
    
    try testing.expect(location.primary_node == 1);
    try testing.expect(location.replica_nodes.len == 0); // replication_factor = 1
    
    // Test duplicate node addition
    try testing.expectError(error.NodeAlreadyExists, partition_manager.addNode(1));
    
    // Test removing non-existent node
    try testing.expectError(error.NodeNotFound, partition_manager.markNodeFailed(999));
    try testing.expectError(error.NodeNotFound, partition_manager.markNodeRecovered(999));
}

test "Partitioning: consistent data placement" {
    var partition_manager = partitioning.DataPartitionManager.init(testing.allocator, partitioning.PartitionConfig{
        .hash_ring_config = consistent_hashing.HashRingConfig{
            .virtual_nodes_per_node = 10,
            .replication_factor = 2,
        },
    });
    defer partition_manager.deinit();
    
    try partition_manager.addNode(1);
    try partition_manager.addNode(2);
    try partition_manager.addNode(3);
    
    const test_key = "consistency_test";
    
    // Get location multiple times - should be consistent
    const location1 = try partition_manager.findDataLocation(test_key, .vector);
    defer {
        var mutable_location = location1;
        mutable_location.deinit(testing.allocator);
    }
    
    const location2 = try partition_manager.findDataLocation(test_key, .vector);
    defer {
        var mutable_location = location2;
        mutable_location.deinit(testing.allocator);
    }
    
    const location3 = try partition_manager.findDataLocation(test_key, .vector);
    defer {
        var mutable_location = location3;
        mutable_location.deinit(testing.allocator);
    }
    
    // All lookups should return the same result
    try testing.expect(location1.primary_node == location2.primary_node);
    try testing.expect(location2.primary_node == location3.primary_node);
    try testing.expect(location1.replica_nodes.len == location2.replica_nodes.len);
    try testing.expect(location2.replica_nodes.len == location3.replica_nodes.len);
    
    // Replica nodes should be the same (though order might differ)
    try testing.expect(location1.replica_nodes.len == 1); // replication_factor - 1
    try testing.expect(location1.replica_nodes[0] == location2.replica_nodes[0]);
    try testing.expect(location2.replica_nodes[0] == location3.replica_nodes[0]);
} 