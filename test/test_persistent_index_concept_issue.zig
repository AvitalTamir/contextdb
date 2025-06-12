const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "persistent index concept restoration issue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_persistent_index_concepts") catch {};
    defer std.fs.cwd().deleteTree("test_persistent_index_concepts") catch {};

    std.debug.print("\n=== Testing Persistent Index Concept Issue ===\n", .{});

    const config = memora.MemoraConfig{
        .data_path = "test_persistent_index_concepts",
        .auto_snapshot_interval = null,
        .enable_persistent_indexes = true, // ENABLE persistent indexes
    };

    // Phase 1: Create database, add concepts, save persistent indexes
    std.debug.print("\n--- Phase 1: Create concepts and save persistent indexes ---\n", .{});
    var concept_ids = std.ArrayList(u64).init(allocator);
    defer concept_ids.deinit();
    
    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        // Create memory node and content
        const memory_id: u64 = 1;
        const memory_node = memora.types.Node.init(memory_id, "Test memory");
        try db.insertNode(memory_node);
        
        const memory_content = memora.types.LogEntry.initMemoryContent(memory_id, "Test memory content");
        try db.append_log.append(memory_content);

        // Create vector
        const vector = memora.types.Vector.init(memory_id, &[_]f32{0.1} ** 128);
        try db.insertVector(vector);

        // Create concept nodes (like MCP server does)
        const concepts = [_][]const u8{ "test", "memory", "concept" };
        for (concepts, 0..) |concept, i| {
            const concept_id = 0x8000000000000000 + i + 1;
            try concept_ids.append(concept_id);
            
            // Create concept node
            const concept_node = memora.types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
            
            // Create edge from memory to concept
            const edge = memora.types.Edge.init(memory_id, concept_id, memora.types.EdgeKind.related);
            try db.insertEdge(edge);
            
            std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ concept, memory_id, concept_id });
        }

        std.debug.print("\n📊 State before saving persistent indexes:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Save persistent indexes (this captures current state)
        try db.savePersistentIndexes();
        std.debug.print("  ✅ Saved persistent indexes\n", .{});
    }

    // Phase 2: Add MORE concepts to log (after persistent index save)
    std.debug.print("\n--- Phase 2: Add more concepts to log (after index save) ---\n", .{});
    var new_concept_ids = std.ArrayList(u64).init(allocator);
    defer new_concept_ids.deinit();
    
    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        std.debug.print("📊 State after loading from persistent indexes:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Add NEW concepts that will only be in the log (not in persistent indexes)
        const new_concepts = [_][]const u8{ "new", "additional", "concepts" };
        for (new_concepts, 0..) |concept, i| {
            const concept_id = 0x8000000000000000 + 100 + i;
            try new_concept_ids.append(concept_id);
            
            // Create concept node
            const concept_node = memora.types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
            
            // Create edge from memory to concept
            const edge = memora.types.Edge.init(1, concept_id, memora.types.EdgeKind.related);
            try db.insertEdge(edge);
            
            std.debug.print("  ✅ Added NEW concept '{s}': {} -> {}\n", .{ concept, 1, concept_id });
        }

        std.debug.print("\n📊 State after adding new concepts:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});

        // Verify new concepts exist
        for (new_concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ New concept exists: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
            } else {
                std.debug.print("  ❌ New concept missing: {}\n", .{concept_id});
            }
        }
    }

    // Phase 3: Restart and test concept restoration
    std.debug.print("\n--- Phase 3: Restart and test concept restoration ---\n", .{});
    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        std.debug.print("📊 State after restart (persistent index loading):\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Check original concepts (should be restored from persistent indexes)
        std.debug.print("\n🔍 Checking original concepts (from persistent indexes):\n", .{});
        var original_restored: u32 = 0;
        for (concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Original concept restored: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                original_restored += 1;
            } else {
                std.debug.print("  ❌ Original concept missing: {}\n", .{concept_id});
            }
        }

        // Check new concepts (should be restored from log replay)
        std.debug.print("\n🔍 Checking new concepts (from log replay):\n", .{});
        var new_restored: u32 = 0;
        for (new_concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ New concept restored: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                new_restored += 1;
            } else {
                std.debug.print("  ❌ New concept LOST: {}\n", .{concept_id});
            }
        }

        std.debug.print("\n🎯 Final Results:\n", .{});
        std.debug.print("  • Original concepts (persistent indexes): {}/{}\n", .{original_restored, concept_ids.items.len});
        std.debug.print("  • New concepts (log replay): {}/{}\n", .{new_restored, new_concept_ids.items.len});

        if (original_restored == concept_ids.items.len and new_restored == new_concept_ids.items.len) {
            std.debug.print("\n🎉 SUCCESS: All concepts properly restored!\n", .{});
        } else if (original_restored == concept_ids.items.len and new_restored == 0) {
            std.debug.print("\n❌ CONFIRMED: Persistent index concepts work, but log replay concepts are LOST!\n", .{});
            std.debug.print("   This confirms the persistent index issue.\n", .{});
            return error.LogReplayConceptsLost;
        } else {
            std.debug.print("\n❌ UNEXPECTED: Mixed results - need further investigation\n", .{});
            return error.UnexpectedResults;
        }
    }
} 