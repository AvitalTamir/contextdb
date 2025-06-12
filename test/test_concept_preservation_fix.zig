const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "concept preservation during MemoryManager initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_concept_preservation") catch {};
    defer std.fs.cwd().deleteTree("test_concept_preservation") catch {};

    std.debug.print("\n=== Testing Concept Preservation During MemoryManager Init ===\n", .{});

    // Phase 1: Create database with concepts and create snapshot
    std.debug.print("\n--- Phase 1: Creating database with concepts ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_concept_preservation",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        // Create memory node
        const memory_node = memora.types.Node.init(1, "Test memory content");
        try db.insertNode(memory_node);

        // Create memory content entry in log (like MemoryManager does)
        const memory_content = "Test memory content for concept preservation";
        const content_log_entry = memora.types.LogEntry.initMemoryContent(1, memory_content);
        try db.append_log.append(content_log_entry);

        // Create concept nodes (like MCP server does)
        const concept_ids = [_]u64{ 0x8000000000000001, 0x8000000000000002, 0x8000000000000003 };
        const concept_labels = [_][]const u8{ "test", "memory", "concept" };

        for (concept_ids, concept_labels) |concept_id, label| {
            const concept_node = memora.types.Node.init(concept_id, label);
            try db.insertNode(concept_node);

            // Create edge from memory to concept
            const edge = memora.types.Edge.init(1, concept_id, memora.types.EdgeKind.related);
            try db.insertEdge(edge);

            std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ label, 1, concept_id });
        }

        // Create vector embedding
        const vector = memora.types.Vector.init(1, &[_]f32{0.1} ** 128);
        try db.insertVector(vector);

        std.debug.print("\n📊 State before snapshot:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Create snapshot to persist everything
        var snapshot_info = try db.createSnapshot();
        defer snapshot_info.deinit();
        std.debug.print("  ✅ Created snapshot {}\n", .{snapshot_info.snapshot_id});
    }

    // Phase 2: Restart database and initialize MemoryManager
    std.debug.print("\n--- Phase 2: Restart and test concept preservation ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_concept_preservation",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        std.debug.print("\n📊 State after database restart (before MemoryManager):\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Verify concept nodes exist before MemoryManager initialization
        const concept_ids = [_]u64{ 0x8000000000000001, 0x8000000000000002, 0x8000000000000003 };
        const concept_labels = [_][]const u8{ "test", "memory", "concept" };

        for (concept_ids, concept_labels) |concept_id, expected_label| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node exists: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                try testing.expectEqualStrings(expected_label, node.getLabelAsString());
            } else {
                std.debug.print("  ❌ Concept node missing: {}\n", .{concept_id});
                return error.ConceptNodeMissing;
            }
        }

        // Now initialize MemoryManager - this should NOT destroy concept nodes
        std.debug.print("\n🔄 Initializing MemoryManager...\n", .{});
        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("\n📊 State after MemoryManager initialization:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});
        std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});

        // Verify concept nodes still exist after MemoryManager initialization
        var preserved_concepts: u32 = 0;
        var preserved_edges: u32 = 0;

        for (concept_ids, concept_labels) |concept_id, expected_label| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node preserved: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                try testing.expectEqualStrings(expected_label, node.getLabelAsString());
                preserved_concepts += 1;

                // Check if edge from memory to concept still exists
                if (db.graph_index.getIncomingEdges(concept_id)) |edges| {
                    for (edges) |edge| {
                        if (edge.from == 1 and edge.getKind() == memora.types.EdgeKind.related) {
                            std.debug.print("    ✅ Edge preserved: {} -> {}\n", .{ edge.from, edge.to });
                            preserved_edges += 1;
                            break;
                        }
                    }
                }
            } else {
                std.debug.print("  ❌ Concept node lost: {}\n", .{concept_id});
                return error.ConceptNodeLost;
            }
        }

        // Verify memory node and content are accessible
        if (try mem_manager.getMemory(1)) |memory| {
            std.debug.print("  ✅ Memory content accessible: \"{s}\"\n", .{memory.getContentAsString()});
        } else {
            std.debug.print("  ❌ Memory content missing!\n", .{});
            return error.MemoryContentMissing;
        }

        // Verify vector embedding is preserved
        if (db.vector_index.getVector(1)) |_| {
            std.debug.print("  ✅ Vector embedding preserved\n", .{});
        } else {
            std.debug.print("  ❌ Vector embedding missing!\n", .{});
            return error.VectorEmbeddingMissing;
        }

        // Summary
        std.debug.print("\n📊 Preservation Summary:\n", .{});
        std.debug.print("  • Concepts preserved: {}/3\n", .{preserved_concepts});
        std.debug.print("  • Edges preserved: {}/3\n", .{preserved_edges});

        if (preserved_concepts == 3 and preserved_edges == 3) {
            std.debug.print("\n🎉 SUCCESS: All concepts and relationships preserved during MemoryManager init!\n", .{});
        } else {
            std.debug.print("\n❌ FAILURE: Some concepts or relationships were lost during MemoryManager init!\n", .{});
            return error.ConceptPreservationFailed;
        }
    }
} 