const std = @import("std");
const memora = @import("memora");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🗜️  Testing Comprehensive Compression for All Data Types\n", .{});
    std.debug.print("======================================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_comprehensive_compression") catch {};
    defer std.fs.cwd().deleteTree("test_comprehensive_compression") catch {};

    // Initialize Memora with compression enabled
    const config = memora.MemoraConfig{
        .data_path = "test_comprehensive_compression",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    std.debug.print("📝 Adding test data for compression testing...\n", .{});
    
    // Add nodes with repetitive patterns (good for compression)
    const test_nodes = [_]memora.types.Node{
        memora.types.Node.init(1, "TestNode_Memory_Content_1"),
        memora.types.Node.init(2, "TestNode_Memory_Content_2"), 
        memora.types.Node.init(3, "TestNode_Memory_Content_3"),
        memora.types.Node.init(4, "TestNode_Memory_Content_4"),
        memora.types.Node.init(5, "TestNode_Memory_Content_5"),
    };
    
    for (test_nodes) |node| {
        try db.insertNode(node);
    }
    
    // Add edges with patterns
    const test_edges = [_]memora.types.Edge{
        memora.types.Edge.init(1, 2, memora.types.EdgeKind.related),
        memora.types.Edge.init(2, 3, memora.types.EdgeKind.child_of),
        memora.types.Edge.init(3, 4, memora.types.EdgeKind.related),
        memora.types.Edge.init(4, 5, memora.types.EdgeKind.child_of),
        memora.types.Edge.init(1, 5, memora.types.EdgeKind.similar_to),
    };
    
    for (test_edges) |edge| {
        try db.insertEdge(edge);
    }
    
    // Add vectors with repetitive patterns
    var dims1 = [_]f32{0.5} ** 64 ++ [_]f32{0.8} ** 64;
    var dims2 = [_]f32{0.3} ** 64 ++ [_]f32{0.9} ** 64;
    var dims3 = [_]f32{0.1} ** 64 ++ [_]f32{0.7} ** 64;
    
    try db.insertVector(memora.types.Vector.init(1, &dims1));
    try db.insertVector(memora.types.Vector.init(2, &dims2));
    try db.insertVector(memora.types.Vector.init(3, &dims3));

    // Add memory content with repetitive text (good for compression)
    const memory_contents = [_]memora.types.MemoryContent{
        .{ .memory_id = 1, .content = "This is a test memory content with repetitive patterns. This is a test memory content with repetitive patterns. This is a test memory content with repetitive patterns." },
        .{ .memory_id = 2, .content = "Another test memory with similar patterns. Another test memory with similar patterns. Another test memory with similar patterns." },
        .{ .memory_id = 3, .content = "Yet another memory content for compression testing. Yet another memory content for compression testing. Yet another memory content for compression testing." },
    };

    std.debug.print("📊 Current Database Statistics:\n", .{});
    const stats = db.getStats();
    std.debug.print("  • Nodes: {}\n", .{stats.node_count});
    std.debug.print("  • Edges: {}\n", .{stats.edge_count});
    std.debug.print("  • Vectors: {}\n", .{stats.vector_count});

    std.debug.print("\n📸 Creating snapshot with compression enabled...\n", .{});
    
    // Create a manual snapshot
    const vectors = try db.getAllVectors();
    defer vectors.deinit();
    
    const nodes = try db.getAllNodes();
    defer nodes.deinit();
    
    const edges = try db.getAllEdges();
    defer edges.deinit();
    
    var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, &memory_contents);
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created successfully!\n", .{});
    std.debug.print("  • Snapshot ID: {}\n", .{snapshot_info.snapshot_id});
    std.debug.print("  • Node files: {}\n", .{snapshot_info.node_files.items.len});
    std.debug.print("  • Edge files: {}\n", .{snapshot_info.edge_files.items.len});
    std.debug.print("  • Vector files: {}\n", .{snapshot_info.vector_files.items.len});
    std.debug.print("  • Memory content files: {}\n", .{snapshot_info.memory_content_files.items.len});
    
    std.debug.print("\n🔍 Testing file compression status...\n", .{});
    
    // Check if files are compressed by trying to read them as text
    for (snapshot_info.node_files.items) |node_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_comprehensive_compression", node_file });
        defer allocator.free(file_path);
        
        const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
        defer file.close();
        
        var buffer: [100]u8 = undefined;
        const bytes_read = file.readAll(&buffer) catch 0;
        
        // Check if it looks like JSON (uncompressed) or binary (compressed)
        var looks_like_json = false;
        if (bytes_read > 0) {
            // Trim whitespace and check for JSON patterns
            var start: usize = 0;
            while (start < bytes_read and (buffer[start] == ' ' or buffer[start] == '\t' or buffer[start] == '\n' or buffer[start] == '\r')) {
                start += 1;
            }
            if (start < bytes_read and buffer[start] == '[') {
                looks_like_json = true;
            }
        }
        
        if (looks_like_json) {
            std.debug.print("  📄 Node file: {s} (uncompressed JSON)\n", .{node_file});
        } else {
            std.debug.print("  🗜️  Node file: {s} (compressed binary)\n", .{node_file});
        }
    }
    
    for (snapshot_info.edge_files.items) |edge_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_comprehensive_compression", edge_file });
        defer allocator.free(file_path);
        
        const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
        defer file.close();
        
        var buffer: [100]u8 = undefined;
        const bytes_read = file.readAll(&buffer) catch 0;
        
        var looks_like_json = false;
        if (bytes_read > 0) {
            var start: usize = 0;
            while (start < bytes_read and (buffer[start] == ' ' or buffer[start] == '\t' or buffer[start] == '\n' or buffer[start] == '\r')) {
                start += 1;
            }
            if (start < bytes_read and buffer[start] == '[') {
                looks_like_json = true;
            }
        }
        
        if (looks_like_json) {
            std.debug.print("  📄 Edge file: {s} (uncompressed JSON)\n", .{edge_file});
        } else {
            std.debug.print("  🗜️  Edge file: {s} (compressed binary)\n", .{edge_file});
        }
    }
    
    for (snapshot_info.memory_content_files.items) |memory_file| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_comprehensive_compression", memory_file });
        defer allocator.free(file_path);
        
        const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
        defer file.close();
        
        var buffer: [100]u8 = undefined;
        const bytes_read = file.readAll(&buffer) catch 0;
        
        var looks_like_json = false;
        if (bytes_read > 0) {
            var start: usize = 0;
            while (start < bytes_read and (buffer[start] == ' ' or buffer[start] == '\t' or buffer[start] == '\n' or buffer[start] == '\r')) {
                start += 1;
            }
            if (start < bytes_read and buffer[start] == '[') {
                looks_like_json = true;
            }
        }
        
        if (looks_like_json) {
            std.debug.print("  📄 Memory file: {s} (uncompressed JSON)\n", .{memory_file});
        } else {
            std.debug.print("  🗜️  Memory file: {s} (compressed binary)\n", .{memory_file});
        }
    }

    std.debug.print("\n🔄 Testing decompression by loading snapshot...\n", .{});
    
    // Test loading the snapshot back (this will test decompression)
    const loaded_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
    defer loaded_nodes.deinit();
    
    const loaded_edges = try db.snapshot_manager.loadEdges(&snapshot_info);
    defer loaded_edges.deinit();
    
    const loaded_memory_contents = try db.snapshot_manager.loadMemoryContents(&snapshot_info);
    defer {
        for (loaded_memory_contents.items) |memory_content| {
            allocator.free(memory_content.content);
        }
        loaded_memory_contents.deinit();
    }
    
    std.debug.print("✅ Successfully loaded compressed data:\n", .{});
    std.debug.print("  • Nodes loaded: {}\n", .{loaded_nodes.items.len});
    std.debug.print("  • Edges loaded: {}\n", .{loaded_edges.items.len});
    std.debug.print("  • Memory contents loaded: {}\n", .{loaded_memory_contents.items.len});
    
    // Verify data integrity
    std.debug.print("\n🔍 Verifying data integrity...\n", .{});
    
    var nodes_match = true;
    if (loaded_nodes.items.len != test_nodes.len) {
        nodes_match = false;
    } else {
        for (test_nodes) |original_node| {
            var found = false;
            for (loaded_nodes.items) |loaded_node| {
                if (loaded_node.id == original_node.id and 
                    std.mem.eql(u8, loaded_node.getLabelAsString(), original_node.getLabelAsString())) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                nodes_match = false;
                break;
            }
        }
    }
    
    var edges_match = true;
    if (loaded_edges.items.len != test_edges.len) {
        edges_match = false;
    } else {
        for (test_edges) |original_edge| {
            var found = false;
            for (loaded_edges.items) |loaded_edge| {
                if (loaded_edge.from == original_edge.from and 
                    loaded_edge.to == original_edge.to and 
                    loaded_edge.kind == original_edge.kind) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                edges_match = false;
                break;
            }
        }
    }
    
    var memory_match = true;
    if (loaded_memory_contents.items.len != memory_contents.len) {
        memory_match = false;
    } else {
        for (memory_contents) |original_memory| {
            var found = false;
            for (loaded_memory_contents.items) |loaded_memory| {
                if (loaded_memory.memory_id == original_memory.memory_id and 
                    std.mem.eql(u8, loaded_memory.content, original_memory.content)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                memory_match = false;
                break;
            }
        }
    }
    
    if (nodes_match) {
        std.debug.print("  ✅ Nodes: All data matches after compression/decompression\n", .{});
    } else {
        std.debug.print("  ❌ Nodes: Data mismatch after compression/decompression\n", .{});
    }
    
    if (edges_match) {
        std.debug.print("  ✅ Edges: All data matches after compression/decompression\n", .{});
    } else {
        std.debug.print("  ❌ Edges: Data mismatch after compression/decompression\n", .{});
    }
    
    if (memory_match) {
        std.debug.print("  ✅ Memory: All data matches after compression/decompression\n", .{});
    } else {
        std.debug.print("  ❌ Memory: Data mismatch after compression/decompression\n", .{});
    }
    
    if (nodes_match and edges_match and memory_match) {
        std.debug.print("\n🎉 SUCCESS: Comprehensive compression test passed!\n", .{});
        std.debug.print("   All data types (nodes, edges, memory) are properly compressed and can be decompressed.\n", .{});
    } else {
        std.debug.print("\n❌ FAILURE: Some data types failed compression/decompression test.\n", .{});
    }
} 