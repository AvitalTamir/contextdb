const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");
const types = contextdb.types;
const persistent_index = contextdb.persistent_index;

// Comprehensive Persistent Index Tests
// Following TigerBeetle-style programming: deterministic, extensive, zero external dependencies

test "PersistentNodeIndex basic operations" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_persistent_nodes") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_nodes") catch {};
    
    // Create test directory
    try std.fs.cwd().makeDir("test_persistent_nodes");
    
    var node_index = try persistent_index.PersistentNodeIndex.init(allocator, "test_persistent_nodes");
    defer node_index.deinit();
    
    // Test that index doesn't exist initially
    try testing.expect(!node_index.exists());
    
    // Create some test nodes
    const test_nodes = [_]types.Node{
        types.Node.init(1, "User"),
        types.Node.init(2, "Document"),
        types.Node.init(3, "Topic"),
    };
    
    // Create persistent index
    try node_index.create(&test_nodes);
    try testing.expect(node_index.exists());
    
    // Load nodes back
    const loaded_nodes = try node_index.load();
    try testing.expect(loaded_nodes.len == test_nodes.len);
    
    // Verify node data integrity
    for (test_nodes, 0..) |original_node, i| {
        const loaded_node = loaded_nodes[i];
        try testing.expect(loaded_node.id == original_node.id);
        try testing.expect(std.mem.eql(u8, loaded_node.getLabelAsString(), original_node.getLabelAsString()));
    }
}

test "PersistentEdgeIndex with binary search" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_persistent_edges") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_edges") catch {};
    
    try std.fs.cwd().makeDir("test_persistent_edges");
    
    var edge_index = try persistent_index.PersistentEdgeIndex.init(allocator, "test_persistent_edges");
    defer edge_index.deinit();
    
    // Create test edges with various relationships
    const test_edges = [_]types.Edge{
        types.Edge.init(1, 2, types.EdgeKind.owns),
        types.Edge.init(1, 3, types.EdgeKind.related),
        types.Edge.init(2, 3, types.EdgeKind.links),
        types.Edge.init(3, 4, types.EdgeKind.child_of),
        types.Edge.init(1, 4, types.EdgeKind.similar_to),
    };
    
    try edge_index.create(&test_edges);
    
    // Test binary search for edges from specific nodes
    const edges_from_1 = try edge_index.findEdgesFrom(1);
    try testing.expect(edges_from_1.len == 3); // Node 1 has 3 outgoing edges
    
    // Verify all found edges are from node 1
    for (edges_from_1) |edge| {
        try testing.expect(edge.from == 1);
    }
    
    const edges_from_2 = try edge_index.findEdgesFrom(2);
    try testing.expect(edges_from_2.len == 1); // Node 2 has 1 outgoing edge
    
    const edges_from_999 = try edge_index.findEdgesFrom(999);
    try testing.expect(edges_from_999.len == 0); // Non-existent node
}

test "PersistentVectorIndex with binary search" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_persistent_vectors") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_vectors") catch {};
    
    try std.fs.cwd().makeDir("test_persistent_vectors");
    
    var vector_index = try persistent_index.PersistentVectorIndex.init(allocator, "test_persistent_vectors");
    defer vector_index.deinit();
    
    // Create test vectors
    const dims1 = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims2 = [_]f32{ 0.9, 0.1, 0.0 } ++ [_]f32{0.0} ** 125;
    const dims3 = [_]f32{ 0.0, 1.0, 0.0 } ++ [_]f32{0.0} ** 125;
    
    const test_vectors = [_]types.Vector{
        types.Vector.init(3, &dims3),
        types.Vector.init(1, &dims1), // Intentionally out of order
        types.Vector.init(2, &dims2),
    };
    
    try vector_index.create(&test_vectors);
    
    // Test binary search
    const found_vector_1 = try vector_index.findVector(1);
    try testing.expect(found_vector_1 != null);
    try testing.expect(found_vector_1.?.id == 1);
    
    const found_vector_2 = try vector_index.findVector(2);
    try testing.expect(found_vector_2 != null);
    try testing.expect(found_vector_2.?.id == 2);
    
    const found_vector_999 = try vector_index.findVector(999);
    try testing.expect(found_vector_999 == null);
    
    // Verify vector data integrity
    for (test_vectors) |original_vector| {
        const found = (try vector_index.findVector(original_vector.id)).?;
        for (original_vector.dims, 0..) |dim, i| {
            try testing.expect(found.dims[i] == dim);
        }
    }
}

test "PersistentIndexManager full integration" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_persistent_integration") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_integration") catch {};
    
    // Create the parent directory first
    try std.fs.cwd().makeDir("test_persistent_integration");
    
    var manager = try persistent_index.PersistentIndexManager.init(allocator, "test_persistent_integration", null);
    defer manager.deinit();
    
    // Initially no indexes should exist
    try testing.expect(!manager.indexesExist());
    
    // Create test data
    const test_nodes = [_]types.Node{
        types.Node.init(1, "TestNode1"),
        types.Node.init(2, "TestNode2"),
    };
    
    const test_edges = [_]types.Edge{
        types.Edge.init(1, 2, types.EdgeKind.owns),
    };
    
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const test_vectors = [_]types.Vector{
        types.Vector.init(1, &dims),
    };
    
    // Save indexes
    try manager.saveIndexes(&test_nodes, &test_edges, &test_vectors);
    try testing.expect(manager.indexesExist());
    
    // Load indexes back
    const loaded_data = try manager.loadIndexes();
    
    try testing.expect(loaded_data.nodes.len == test_nodes.len);
    try testing.expect(loaded_data.edges.len == test_edges.len);
    try testing.expect(loaded_data.vectors.len == test_vectors.len);
    
    // Verify data integrity
    try testing.expect(loaded_data.nodes[0].id == test_nodes[0].id);
    try testing.expect(loaded_data.edges[0].from == test_edges[0].from);
    try testing.expect(loaded_data.vectors[0].id == test_vectors[0].id);
    
    // Test stats
    const stats = try manager.getStats();
    try testing.expect(stats.node_count == test_nodes.len);
    try testing.expect(stats.edge_count == test_edges.len);
    try testing.expect(stats.vector_count == test_vectors.len);
}

test "Memory-mapped file checksum validation" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_checksum") catch {};
    defer std.fs.cwd().deleteTree("test_checksum") catch {};
    
    try std.fs.cwd().makeDir("test_checksum");
    
    var node_index = try persistent_index.PersistentNodeIndex.init(allocator, "test_checksum");
    defer node_index.deinit();
    
    const test_nodes = [_]types.Node{
        types.Node.init(1, "TestNode"),
    };
    
    // Create valid index
    try node_index.create(&test_nodes);
    
    // Load should succeed
    const loaded_nodes = try node_index.load();
    try testing.expect(loaded_nodes.len == 1);
    
    // Corrupt the file by modifying a byte in the data section
    {
        const file = try std.fs.cwd().openFile("test_checksum/nodes.idx", .{ .mode = .read_write });
        defer file.close();
        
        // Skip header and corrupt first byte of data
        try file.seekTo(@sizeOf(persistent_index.IndexFileHeader));
        _ = try file.write(&[_]u8{0xFF}); // Corrupt the data
    }
    
    // Create a new index instance to reload
    var corrupted_index = try persistent_index.PersistentNodeIndex.init(allocator, "test_checksum");
    defer corrupted_index.deinit();
    
    // Load should fail with checksum mismatch
    const load_result = corrupted_index.load();
    try testing.expectError(error.ChecksumMismatch, load_result);
}

test "Large dataset persistence performance" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_performance") catch {};
    defer std.fs.cwd().deleteTree("test_performance") catch {};
    
    // Create the parent directory first
    try std.fs.cwd().makeDir("test_performance");
    
    var manager = try persistent_index.PersistentIndexManager.init(allocator, "test_performance", null);
    defer manager.deinit();
    
    // Create large dataset
    const num_items = 10000;
    
    var nodes = try allocator.alloc(types.Node, num_items);
    defer allocator.free(nodes);
    
    var edges = try allocator.alloc(types.Edge, num_items);
    defer allocator.free(edges);
    
    var vectors = try allocator.alloc(types.Vector, num_items);
    defer allocator.free(vectors);
    
    // Fill with test data
    for (0..num_items) |i| {
        const id = @as(u64, i + 1);
        nodes[i] = types.Node.init(id, "TestNode");
        edges[i] = types.Edge.init(id, ((id % 1000) + 1), types.EdgeKind.owns);
        
        const dims = [_]f32{@floatFromInt(i)} ++ [_]f32{0.0} ** 127;
        vectors[i] = types.Vector.init(id, &dims);
    }
    
    // Measure save performance
    const save_start = std.time.nanoTimestamp();
    try manager.saveIndexes(nodes, edges, vectors);
    const save_time = std.time.nanoTimestamp() - save_start;
    
    // Measure load performance
    const load_start = std.time.nanoTimestamp();
    const loaded_data = try manager.loadIndexes();
    const load_time = std.time.nanoTimestamp() - load_start;
    
    // Verify data
    try testing.expect(loaded_data.nodes.len == num_items);
    try testing.expect(loaded_data.edges.len == num_items);
    try testing.expect(loaded_data.vectors.len == num_items);
    
    std.debug.print("\nLarge Dataset Performance ({} items):\n", .{num_items});
    std.debug.print("  Save time: {}ms ({} per item)\n", .{ @divTrunc(save_time, 1_000_000), @divTrunc(save_time, num_items) });
    std.debug.print("  Load time: {}ms ({} per item)\n", .{ @divTrunc(load_time, 1_000_000), @divTrunc(load_time, num_items) });
    
    // Performance assertions - should be fast for memory-mapped operations
    try testing.expect(save_time < 1_000_000_000); // < 1 second
    try testing.expect(load_time < 200_000_000);   // < 200ms (more lenient for CI/testing environments)
}

test "IndexUtils graph and vector conversion" {
    const allocator = testing.allocator;
    
    // Create a mock graph index
    var graph_index = contextdb.graph.GraphIndex.init(allocator);
    defer graph_index.deinit();
    
    // Add test data
    try graph_index.addNode(types.Node.init(1, "TestNode1"));
    try graph_index.addNode(types.Node.init(2, "TestNode2"));
    try graph_index.addEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    
    // Convert to arrays
    const graph_data = try persistent_index.IndexUtils.graphToArrays(&graph_index, allocator);
    defer graph_data.nodes.deinit();
    defer graph_data.edges.deinit();
    
    try testing.expect(graph_data.nodes.items.len == 2);
    try testing.expect(graph_data.edges.items.len == 1);
    
    // Create a mock vector index
    var vector_index = contextdb.vector.VectorIndex.init(allocator);
    defer vector_index.deinit();
    
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    try vector_index.addVector(types.Vector.init(1, &dims));
    
    // Convert to array
    const vector_data = try persistent_index.IndexUtils.vectorsToArray(&vector_index, allocator);
    defer vector_data.deinit();
    
    try testing.expect(vector_data.items.len == 1);
    try testing.expect(vector_data.items[0].id == 1);
}

test "File header validation and magic numbers" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_header") catch {};
    defer std.fs.cwd().deleteTree("test_header") catch {};
    
    try std.fs.cwd().makeDir("test_header");
    
    var node_index = try persistent_index.PersistentNodeIndex.init(allocator, "test_header");
    defer node_index.deinit();
    
    const test_nodes = [_]types.Node{
        types.Node.init(1, "TestNode"),
    };
    
    try node_index.create(&test_nodes);
    
    // Manually inspect the header
    const mapped_file = try persistent_index.MappedFile.initReadOnly(allocator, "test_header/nodes.idx", 16384);
    defer {
        var mutable_file = mapped_file;
        mutable_file.deinit();
    }
    
    const header = try mapped_file.getHeader();
    
    // Validate header fields
    try testing.expect(header.magic == 0x49444558); // "IDEX"
    try testing.expect(header.version == 1);
    try testing.expect(header.index_type == .graph_nodes);
    try testing.expect(header.item_count == 1);
    try testing.expect(header.data_offset == @sizeOf(persistent_index.IndexFileHeader));
    try testing.expect(header.checksum != 0); // Should have calculated checksum
}

test "Persistent index error handling" {
    const allocator = testing.allocator;
    
    // Test loading non-existent files
    var node_index = try persistent_index.PersistentNodeIndex.init(allocator, "non_existent_dir");
    defer node_index.deinit();
    
    const nodes = try node_index.load();
    try testing.expect(nodes.len == 0); // Should return empty slice for missing files
    
    // Test creating index with invalid directory (read-only filesystem simulation)
    // This would need filesystem permission manipulation which is complex in tests
    // For now, we rely on the successful creation tests above
}

test "Memory-mapped file size and alignment" {
    const allocator = testing.allocator;
    
    std.fs.cwd().deleteTree("test_alignment") catch {};
    defer std.fs.cwd().deleteTree("test_alignment") catch {};
    
    try std.fs.cwd().makeDir("test_alignment");
    
    var vector_index = try persistent_index.PersistentVectorIndex.init(allocator, "test_alignment");
    defer vector_index.deinit();
    
    // Create test with known size
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    const test_vectors = [_]types.Vector{
        types.Vector.init(1, &dims),
        types.Vector.init(2, &dims),
    };
    
    try vector_index.create(&test_vectors);
    
    // Check file size
    const file = try std.fs.cwd().openFile("test_alignment/vectors.idx", .{});
    defer file.close();
    
    const file_size = try file.getEndPos();
    const expected_size = @sizeOf(persistent_index.IndexFileHeader) + (test_vectors.len * @sizeOf(types.Vector));
    
    try testing.expect(file_size == expected_size);
    
    // Verify alignment requirements
    const mapped_file = try persistent_index.MappedFile.initReadOnly(allocator, "test_alignment/vectors.idx", 16384);
    defer {
        var mutable_file = mapped_file;
        mutable_file.deinit();
    }
    
    // Memory mapping should be page-aligned
    const mapping_addr = @intFromPtr(mapped_file.mapping.ptr);
    try testing.expect(mapping_addr % 16384 == 0); // Use correct alignment value
} 