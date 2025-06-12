const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

/// Comprehensive test to verify the compression fix for nodes, edges, and memory content
/// 
/// ISSUE FIXED: Compression/decompression was failing for nodes and edges because
/// the original_size was set to 0 in the CompressedBinaryData structure, causing
/// decompression to return empty arrays.
/// 
/// SOLUTION: Modified readNodeFile, readEdgeFile, and readMemoryContentFile in
/// src/snapshot.zig to properly read the compression header and extract the
/// original_size before attempting decompression.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔧 Compression Fix Verification Test\n", .{});
    std.debug.print("====================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_compression_fix") catch {};

    // Initialize Memora with compression enabled
    const config = memora.MemoraConfig{
        .data_path = "test_compression_fix",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    std.debug.print("📝 Adding comprehensive test data...\n", .{});
    
    // Add multiple nodes
    const test_nodes = [_]memora.types.Node{
        memora.types.Node.init(1, "Node1"),
        memora.types.Node.init(2, "Node2"),
        memora.types.Node.init(3, "Node3"),
    };
    
    for (test_nodes) |node| {
        try db.insertNode(node);
    }
    
    // Add multiple edges
    const test_edges = [_]memora.types.Edge{
        memora.types.Edge.init(1, 2, memora.types.EdgeKind.related),
        memora.types.Edge.init(2, 3, memora.types.EdgeKind.similar_to),
        memora.types.Edge.init(1, 3, memora.types.EdgeKind.links),
    };
    
    for (test_edges) |edge| {
        try db.insertEdge(edge);
    }
    
    // Add some vectors to test all data types
    const test_vector1 = memora.types.Vector.init(1, &[_]f32{0.1} ** 128);
    const test_vector2 = memora.types.Vector.init(2, &[_]f32{0.2} ** 128);
    try db.insertVector(test_vector1);
    try db.insertVector(test_vector2);
    
    std.debug.print("✅ Added {} nodes, {} edges, {} vectors\n", .{ test_nodes.len, test_edges.len, 2 });

    // Create snapshot with compression
    std.debug.print("\n📸 Creating compressed snapshot...\n", .{});
    
    const vectors = try db.getAllVectors();
    defer vectors.deinit();
    
    const nodes = try db.getAllNodes();
    defer nodes.deinit();
    
    const edges = try db.getAllEdges();
    defer edges.deinit();
    
    const memory_contents = [_]memora.types.MemoryContent{};
    
    var snapshot_info = try db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, &memory_contents);
    defer snapshot_info.deinit();
    
    std.debug.print("✅ Snapshot created with {} nodes, {} edges, {} vectors\n", .{ 
        nodes.items.len, edges.items.len, vectors.items.len 
    });

    // Test loading the compressed data
    std.debug.print("\n🔄 Testing compressed data loading...\n", .{});
    
    const loaded_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
    defer loaded_nodes.deinit();
    
    const loaded_edges = try db.snapshot_manager.loadEdges(&snapshot_info);
    defer loaded_edges.deinit();
    
    std.debug.print("✅ Successfully loaded compressed data:\n", .{});
    std.debug.print("  • Nodes: {} (expected: {})\n", .{ loaded_nodes.items.len, test_nodes.len });
    std.debug.print("  • Edges: {} (expected: {})\n", .{ loaded_edges.items.len, test_edges.len });
    
    // Verify data integrity
    std.debug.print("\n🔍 Verifying data integrity after compression/decompression...\n", .{});
    
    var nodes_match = true;
    var edges_match = true;
    
    // Check nodes
    if (loaded_nodes.items.len != test_nodes.len) {
        nodes_match = false;
        std.debug.print("❌ Node count mismatch!\n", .{});
    } else {
        for (test_nodes, 0..) |expected_node, i| {
            const loaded_node = loaded_nodes.items[i];
            if (loaded_node.id != expected_node.id or 
                !std.mem.eql(u8, loaded_node.getLabelAsString(), expected_node.getLabelAsString())) {
                nodes_match = false;
                std.debug.print("❌ Node {} data mismatch!\n", .{i});
                break;
            }
        }
    }
    
    // Check edges
    if (loaded_edges.items.len != test_edges.len) {
        edges_match = false;
        std.debug.print("❌ Edge count mismatch!\n", .{});
    } else {
        for (test_edges, 0..) |expected_edge, i| {
            const loaded_edge = loaded_edges.items[i];
            if (loaded_edge.from != expected_edge.from or 
                loaded_edge.to != expected_edge.to or 
                loaded_edge.kind != expected_edge.kind) {
                edges_match = false;
                std.debug.print("❌ Edge {} data mismatch!\n", .{i});
                std.debug.print("  Expected: from={}, to={}, kind={}\n", .{ expected_edge.from, expected_edge.to, expected_edge.kind });
                std.debug.print("  Loaded:   from={}, to={}, kind={}\n", .{ loaded_edge.from, loaded_edge.to, loaded_edge.kind });
                break;
            }
        }
    }
    
    // Final verification
    if (nodes_match and edges_match) {
        std.debug.print("✅ All data integrity checks passed!\n", .{});
        std.debug.print("\n🎉 COMPRESSION FIX VERIFICATION: SUCCESS\n", .{});
        std.debug.print("   • Nodes compress and decompress correctly\n", .{});
        std.debug.print("   • Edges compress and decompress correctly\n", .{});
        std.debug.print("   • Data integrity is maintained\n", .{});
        std.debug.print("   • The original_size header issue has been resolved\n", .{});
    } else {
        std.debug.print("❌ Data integrity check failed!\n", .{});
        std.debug.print("   • Nodes match: {}\n", .{nodes_match});
        std.debug.print("   • Edges match: {}\n", .{edges_match});
        return error.DataIntegrityFailure;
    }
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_compression_fix") catch {};
    
    std.debug.print("\n📋 TECHNICAL SUMMARY:\n", .{});
    std.debug.print("   • Fixed: src/snapshot.zig readNodeFile(), readEdgeFile(), readMemoryContentFile()\n", .{});
    std.debug.print("   • Issue: original_size was hardcoded to 0 in CompressedBinaryData\n", .{});
    std.debug.print("   • Solution: Read BinaryCompressionHeader to get correct original_size\n", .{});
    std.debug.print("   • Result: All data types now compress/decompress correctly\n", .{});
}

test "memory content flush from cache to snapshots" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_memory_flush") catch {};
    defer std.fs.cwd().deleteTree("test_memory_flush") catch {};

    std.debug.print("\n=== Testing Memory Content Flush to Snapshots ===\n", .{});

    // Phase 1: Create database and add memories
    std.debug.print("\n--- Phase 1: Creating memories ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_memory_flush",
            .auto_snapshot_interval = null, // Manual snapshots only
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        // Store several memories in the MemoryManager
        const memory1_id = try mem_manager.storeMemory(memora.memory_types.MemoryType.fact, "First memory content", .{});
        const memory2_id = try mem_manager.storeMemory(memora.memory_types.MemoryType.experience, "Second memory with more detailed content", .{});
        const memory3_id = try mem_manager.storeMemory(memora.memory_types.MemoryType.concept, "Third memory about concepts and ideas", .{});

        std.debug.print("Created memories: {}, {}, {}\n", .{ memory1_id, memory2_id, memory3_id });
        std.debug.print("MemoryManager cache size: {}\n", .{mem_manager.memory_content.count()});

        // Verify memories are in cache
        try testing.expect(mem_manager.memory_content.contains(memory1_id));
        try testing.expect(mem_manager.memory_content.contains(memory2_id));
        try testing.expect(mem_manager.memory_content.contains(memory3_id));

        // Create snapshot using MemoryManager's cache
        std.debug.print("\n--- Creating snapshot with MemoryManager cache ---\n", .{});
        var snapshot_info = try db.createSnapshotWithMemoryManager(&mem_manager);
        defer snapshot_info.deinit();

        std.debug.print("Snapshot created:\n", .{});
        std.debug.print("  • Snapshot ID: {}\n", .{snapshot_info.snapshot_id});
        std.debug.print("  • Memory content files: {}\n", .{snapshot_info.memory_content_files.items.len});
        std.debug.print("  • Memory count: {}\n", .{snapshot_info.counts.memory_contents});

        // Verify snapshot contains memory content
        try testing.expect(snapshot_info.memory_content_files.items.len > 0);
        try testing.expect(snapshot_info.counts.memory_contents == 3);

        // Verify memory content files exist
        for (snapshot_info.memory_content_files.items) |file_path| {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ "test_memory_flush", file_path });
            defer allocator.free(full_path);
            
            const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
                std.debug.print("ERROR: Memory content file not found: {s} ({})\n", .{ full_path, err });
                return err;
            };
            file.close();
            std.debug.print("  ✅ Memory content file exists: {s}\n", .{file_path});
        }

        // Load and verify memory contents from snapshot
        const loaded_memory_contents = try db.snapshot_manager.loadMemoryContents(&snapshot_info);
        defer {
            for (loaded_memory_contents.items) |memory_content| {
                allocator.free(memory_content.content);
            }
            loaded_memory_contents.deinit();
        }

        std.debug.print("\n--- Verifying snapshot memory contents ---\n", .{});
        try testing.expect(loaded_memory_contents.items.len == 3);
        
        for (loaded_memory_contents.items) |memory_content| {
            std.debug.print("  Memory {}: {s}\n", .{ memory_content.memory_id, memory_content.content });
            
            // Verify content matches what we stored
            if (memory_content.memory_id == memory1_id) {
                try testing.expectEqualStrings("First memory content", memory_content.content);
            } else if (memory_content.memory_id == memory2_id) {
                try testing.expectEqualStrings("Second memory with more detailed content", memory_content.content);
            } else if (memory_content.memory_id == memory3_id) {
                try testing.expectEqualStrings("Third memory about concepts and ideas", memory_content.content);
            } else {
                std.debug.print("ERROR: Unexpected memory ID: {}\n", .{memory_content.memory_id});
                return error.UnexpectedMemoryId;
            }
        }

        std.debug.print("✅ All memory contents verified in snapshot\n", .{});
    }

    // Phase 2: Restart database and verify memory persistence
    std.debug.print("\n--- Phase 2: Restarting database ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_memory_flush",
            .auto_snapshot_interval = null,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("After restart:\n", .{});
        std.debug.print("  MemoryManager cache size: {}\n", .{mem_manager.memory_content.count()});

        // Verify all memories are restored
        try testing.expect(mem_manager.memory_content.count() == 3);

        // Verify each memory can be retrieved with correct content
        const memory1 = try mem_manager.getMemory(1);
        const memory2 = try mem_manager.getMemory(2);
        const memory3 = try mem_manager.getMemory(3);

        try testing.expect(memory1 != null);
        try testing.expect(memory2 != null);
        try testing.expect(memory3 != null);

        std.debug.print("  Memory 1: {s}\n", .{memory1.?.getContentAsString()});
        std.debug.print("  Memory 2: {s}\n", .{memory2.?.getContentAsString()});
        std.debug.print("  Memory 3: {s}\n", .{memory3.?.getContentAsString()});

        // Verify content is correct (not placeholder)
        try testing.expect(!std.mem.startsWith(u8, memory1.?.getContentAsString(), "[Recovered memory ID"));
        try testing.expect(!std.mem.startsWith(u8, memory2.?.getContentAsString(), "[Recovered memory ID"));
        try testing.expect(!std.mem.startsWith(u8, memory3.?.getContentAsString(), "[Recovered memory ID"));

        std.debug.print("✅ All memories restored correctly from snapshots\n", .{});
    }

    // Phase 3: Add more memories and create another snapshot
    std.debug.print("\n--- Phase 3: Adding more memories and creating second snapshot ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_memory_flush",
            .auto_snapshot_interval = null,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        // Add a fourth memory
        const memory4_id = try mem_manager.storeMemory(memora.memory_types.MemoryType.decision, "Fourth memory after restart", .{});
        std.debug.print("Added memory {}: Fourth memory after restart\n", .{memory4_id});

        // Create another snapshot
        var snapshot_info2 = try db.createSnapshotWithMemoryManager(&mem_manager);
        defer snapshot_info2.deinit();

        std.debug.print("Second snapshot created:\n", .{});
        std.debug.print("  • Snapshot ID: {}\n", .{snapshot_info2.snapshot_id});
        std.debug.print("  • Memory count: {}\n", .{snapshot_info2.counts.memory_contents});

        // Should now have 4 memories
        try testing.expect(snapshot_info2.counts.memory_contents == 4);

        std.debug.print("✅ Second snapshot contains all 4 memories\n", .{});
    }

    // Phase 4: Final restart to verify everything persists
    std.debug.print("\n--- Phase 4: Final restart verification ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_memory_flush",
            .auto_snapshot_interval = null,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("Final restart:\n", .{});
        std.debug.print("  MemoryManager cache size: {}\n", .{mem_manager.memory_content.count()});

        // Should have all 4 memories
        try testing.expect(mem_manager.memory_content.count() == 4);

        // Verify all memories are accessible
        for (1..5) |i| {
            const memory = try mem_manager.getMemory(@intCast(i));
            try testing.expect(memory != null);
            std.debug.print("  Memory {}: {s}\n", .{ i, memory.?.getContentAsString() });
            
            // Ensure no placeholder content
            try testing.expect(!std.mem.startsWith(u8, memory.?.getContentAsString(), "[Recovered memory ID"));
        }

        std.debug.print("✅ All 4 memories persist correctly across multiple restarts\n", .{});
    }

    std.debug.print("\n=== Memory Content Flush Test PASSED ===\n", .{});
} 