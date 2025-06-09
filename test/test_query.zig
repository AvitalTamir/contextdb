const std = @import("std");
const testing = std.testing;

// Import the ContextDB module
const contextdb = @import("contextdb");

// Re-export individual modules for convenience
const types = contextdb.types;
const log = contextdb.log;
const graph = contextdb.graph;
const vector = contextdb.vector;
const snapshot = contextdb.snapshot;
const main = contextdb;

test "ContextDB full integration test" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data at the beginning
    std.fs.cwd().deleteTree("integration_test_db") catch {};
    
    const config = main.ContextDBConfig{
        .data_path = "integration_test_db",
        .auto_snapshot_interval = null, // Disable auto-snapshots to prevent pointer invalidation
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try main.ContextDB.init(allocator, config, null);
    defer db.deinit();
    defer std.fs.cwd().deleteTree("integration_test_db") catch {};

    // Test 1: Basic insertions
    try db.insertNode(types.Node.init(1, "User"));
    try db.insertNode(types.Node.init(2, "Document"));
    try db.insertNode(types.Node.init(3, "Category"));
    try db.insertNode(types.Node.init(4, "Tag"));

    // Test 2: Edge relationships
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.owns));      // User owns Document
    try db.insertEdge(types.Edge.init(2, 3, types.EdgeKind.related));   // Document related to Category
    try db.insertEdge(types.Edge.init(2, 4, types.EdgeKind.links));     // Document links to Tag
    try db.insertEdge(types.Edge.init(3, 4, types.EdgeKind.child_of));  // Category child of Tag

    // Test 3: Vector embeddings
    const user_embedding = [_]f32{ 1.0, 0.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 124;
    const doc_embedding = [_]f32{ 0.8, 0.6, 0.0, 0.0 } ++ [_]f32{0.0} ** 124;
    const cat_embedding = [_]f32{ 0.0, 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 124;
    const tag_embedding = [_]f32{ 0.2, 0.2, 0.9, 0.0 } ++ [_]f32{0.0} ** 124;

    try db.insertVector(types.Vector.init(1, &user_embedding));
    try db.insertVector(types.Vector.init(2, &doc_embedding));
    try db.insertVector(types.Vector.init(3, &cat_embedding));
    try db.insertVector(types.Vector.init(4, &tag_embedding));

    // Test 4: Graph traversal queries
    const related_to_user = try db.queryRelated(1, 2);
    defer related_to_user.deinit();
    
    try testing.expect(related_to_user.items.len >= 3); // Should find User, Document, and related nodes
    
    // Verify we found the expected nodes
    var found_user = false;
    var found_doc = false;
    for (related_to_user.items) |node| {
        if (node.id == 1) found_user = true;
        if (node.id == 2) found_doc = true;
    }
    try testing.expect(found_user);
    try testing.expect(found_doc);

    // Test 5: Vector similarity queries
    const similar_to_user = try db.querySimilar(1, 3);
    defer similar_to_user.deinit();
    
    try testing.expect(similar_to_user.items.len >= 1);
    
    // Document should be most similar to User (cosine similarity of their embeddings)
    if (similar_to_user.items.len > 0) {
        try testing.expect(similar_to_user.items[0].id == 2); // Document vector
        try testing.expect(similar_to_user.items[0].similarity > 0.5); // Should be reasonably similar
    }

    // Test 6: Database statistics
    const stats = db.getStats();
    try testing.expect(stats.node_count == 4);
    try testing.expect(stats.edge_count == 4);
    try testing.expect(stats.vector_count == 4);
    try testing.expect(stats.log_entry_count == 12); // 4 nodes + 4 edges + 4 vectors = 12 entries

    // Test 7: Manual snapshot creation
    var snapshot_info = try db.createSnapshot();
    defer snapshot_info.deinit();
    
    try testing.expect(snapshot_info.snapshot_id > 0);
    try testing.expect(snapshot_info.counts.nodes == 4);
    try testing.expect(snapshot_info.counts.edges == 4);
    try testing.expect(snapshot_info.counts.vectors == 4);

    // Test 8: Batch operations
    const batch_nodes = [_]types.Node{
        types.Node.init(5, "NewUser"),
        types.Node.init(6, "NewDoc"),
    };
    
    const batch_edges = [_]types.Edge{
        types.Edge.init(5, 6, types.EdgeKind.owns),
    };
    
    const new_embedding = [_]f32{ 0.1, 0.1, 0.1, 0.1 } ++ [_]f32{0.0} ** 124;
    const batch_vectors = [_]types.Vector{
        types.Vector.init(5, &new_embedding),
    };

    try db.insertBatch(&batch_nodes, &batch_edges, &batch_vectors);

    // Verify batch insertion
    const final_stats = db.getStats();
    try testing.expect(final_stats.node_count == 6);
    try testing.expect(final_stats.edge_count == 5);
    try testing.expect(final_stats.vector_count == 5);
}

test "ContextDB deterministic queries" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data at the beginning
    std.fs.cwd().deleteTree("deterministic_test_db") catch {};
    
    const config = main.ContextDBConfig{
        .data_path = "deterministic_test_db",
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try main.ContextDB.init(allocator, config, null);
    defer db.deinit();
    defer std.fs.cwd().deleteTree("deterministic_test_db") catch {};

    // Insert deterministic test data
    const test_vectors = [_][4]f32{
        [_]f32{ 1.0, 0.0, 0.0, 0.0 },  // Vector 1
        [_]f32{ 0.9, 0.1, 0.0, 0.0 },  // Vector 2 - very similar to 1
        [_]f32{ 0.0, 1.0, 0.0, 0.0 },  // Vector 3 - orthogonal to 1
        [_]f32{ 0.0, 0.0, 1.0, 0.0 },  // Vector 4 - orthogonal to 1 and 3
        [_]f32{ 0.7, 0.7, 0.0, 0.0 },  // Vector 5 - moderately similar to 1
    };

    for (test_vectors, 1..) |base_dims, i| {
        const full_dims = base_dims ++ [_]f32{0.0} ** 124;
        try db.insertVector(types.Vector.init(@intCast(i), &full_dims));
        
        const label = try std.fmt.allocPrint(allocator, "Node{}", .{i});
        defer allocator.free(label);
        try db.insertNode(types.Node.init(@intCast(i), label));
    }

    // Create a simple graph structure
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.similar_to));
    try db.insertEdge(types.Edge.init(2, 3, types.EdgeKind.links));
    try db.insertEdge(types.Edge.init(3, 4, types.EdgeKind.related));
    try db.insertEdge(types.Edge.init(4, 5, types.EdgeKind.child_of));

    // Test deterministic similarity search
    const similar_run1 = try db.querySimilar(1, 3);
    defer similar_run1.deinit();
    
    const similar_run2 = try db.querySimilar(1, 3);
    defer similar_run2.deinit();

    // Results should be identical
    try testing.expect(similar_run1.items.len == similar_run2.items.len);
    for (similar_run1.items, similar_run2.items) |result1, result2| {
        try testing.expect(result1.id == result2.id);
        try testing.expect(@abs(result1.similarity - result2.similarity) < 0.001);
    }

    // Test deterministic graph traversal
    const related_run1 = try db.queryRelated(1, 2);
    defer related_run1.deinit();
    
    const related_run2 = try db.queryRelated(1, 2);
    defer related_run2.deinit();

    // Results should be identical
    try testing.expect(related_run1.items.len == related_run2.items.len);
    for (related_run1.items, related_run2.items) |node1, node2| {
        try testing.expect(node1.id == node2.id);
        try testing.expectEqualStrings(node1.getLabelAsString(), node2.getLabelAsString());
    }

    // Test expected similarity ordering
    try testing.expect(similar_run1.items.len >= 2);
    try testing.expect(similar_run1.items[0].id == 2); // Vector 2 should be most similar
    try testing.expect(similar_run1.items[0].similarity > 0.9); // Should be very similar
    
    if (similar_run1.items.len >= 2) {
        try testing.expect(similar_run1.items[1].id == 5); // Vector 5 should be second most similar
        try testing.expect(similar_run1.items[1].similarity > 0.6); // Should be moderately similar
    }
}

test "ContextDB crash recovery simulation" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("recovery_test_db") catch {};
    
    const config = main.ContextDBConfig{
        .data_path = "recovery_test_db",
        .auto_snapshot_interval = null, // Disable auto-snapshot for deterministic test
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    // Phase 1: Create initial database and add data
    {
        var db = try main.ContextDB.init(allocator, config, null);
        defer db.deinit();

        // Add some data that should be in the snapshot
        try db.insertNode(types.Node.init(1, "Original"));
        try db.insertNode(types.Node.init(2, "Data"));
        try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.links));
        try db.insertVector(types.Vector.init(1, &[_]f32{ 1.0, 2.0, 3.0 }));

        // Create a snapshot (this should capture the above data and clear the log)
        var snapshot_info = try db.createSnapshot();
        defer snapshot_info.deinit();

        // Add data that should only be in the log (after snapshot)
        try db.insertNode(types.Node.init(3, "PostSnapshot"));
        try db.insertEdge(types.Edge.init(2, 3, types.EdgeKind.owns));

        const stats_before = db.getStats();
        try testing.expect(stats_before.node_count == 3);
        try testing.expect(stats_before.edge_count == 2);
        try testing.expect(stats_before.vector_count == 1);
    }

    // Phase 2: Simulate crash and recovery
    {
        var db = try main.ContextDB.init(allocator, config, null);
        defer db.deinit();

        // Load from storage (should recover from snapshot + log)
        try db.loadFromStorage();

        // Check that data was recovered
        const stats_after = db.getStats();
        try testing.expect(stats_after.node_count == 3); // Should recover all data
        try testing.expect(stats_after.edge_count == 2);
        try testing.expect(stats_after.vector_count == 1);
    }

    // Clean up
    std.fs.cwd().deleteTree("recovery_test_db") catch {};
}

test "ContextDB performance and memory usage" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("perf_test_db") catch {};
    
    const config = main.ContextDBConfig{
        .data_path = "perf_test_db",
        .auto_snapshot_interval = 100, // Snapshot every 100 operations
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try main.ContextDB.init(allocator, config, null);
    defer db.deinit();
    defer std.fs.cwd().deleteTree("perf_test_db") catch {};

    const num_items = 100; // Keep test fast but meaningful

    // Benchmark bulk insertions
    var timer = try std.time.Timer.start();
    
    // Insert nodes
    for (0..num_items) |i| {
        const label = try std.fmt.allocPrint(allocator, "Node{}", .{i});
        defer allocator.free(label);
        try db.insertNode(types.Node.init(@intCast(i + 1), label));
    }
    
    const node_insert_time = timer.lap();
    
    // Insert edges (create a chain)
    for (1..num_items) |i| {
        try db.insertEdge(types.Edge.init(@intCast(i), @intCast(i + 1), types.EdgeKind.links));
    }
    
    const edge_insert_time = timer.lap();
    
    // Insert vectors
    for (0..num_items) |i| {
        var dims = [_]f32{0.0} ** 128;
        dims[0] = @floatFromInt(i);
        dims[1] = @floatFromInt(i % 10);
        dims[2] = @floatFromInt(i % 5);
        try db.insertVector(types.Vector.init(@intCast(i + 1), &dims));
    }
    
    const vector_insert_time = timer.lap();
    
    // Test query performance
    const similar = try db.querySimilar(1, 10);
    defer similar.deinit();
    
    const similarity_query_time = timer.lap();
    
    const related = try db.queryRelated(1, 3);
    defer related.deinit();
    
    const graph_query_time = timer.lap();

    // Performance assertions (very lenient for CI)
    try testing.expect(node_insert_time < 1000_000_000); // < 1 second
    try testing.expect(edge_insert_time < 1000_000_000); // < 1 second
    try testing.expect(vector_insert_time < 1000_000_000); // < 1 second
    try testing.expect(similarity_query_time < 100_000_000); // < 100ms
    try testing.expect(graph_query_time < 100_000_000); // < 100ms

    // Verify correctness
    const final_stats = db.getStats();
    try testing.expect(final_stats.node_count == num_items);
    try testing.expect(final_stats.edge_count == num_items - 1);
    try testing.expect(final_stats.vector_count == num_items);

    std.debug.print("\nPerformance Results ({} items):\n", .{num_items});
    std.debug.print("  Node inserts: {}ns\n", .{node_insert_time});
    std.debug.print("  Edge inserts: {}ns\n", .{edge_insert_time});
    std.debug.print("  Vector inserts: {}ns\n", .{vector_insert_time});
    std.debug.print("  Similarity query: {}ns\n", .{similarity_query_time});
    std.debug.print("  Graph query: {}ns\n", .{graph_query_time});
} 