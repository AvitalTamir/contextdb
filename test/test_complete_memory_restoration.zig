const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "complete memory restoration with vector embeddings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_complete_restoration") catch {};
    defer std.fs.cwd().deleteTree("test_complete_restoration") catch {};

    std.debug.print("\n=== Testing Complete Memory Restoration (Content + Vectors) ===\n", .{});

    // Phase 1: Create memories with vector embeddings
    std.debug.print("\n--- Phase 1: Creating memories with vector embeddings ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_complete_restoration",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        // Store test memories with semantic content
        const test_memories = [_][]const u8{
            "User loves playing banjo and learning Zig programming language",
            "Technical discussion about memory management and vector embeddings",
            "Conversation about music instruments and software development patterns",
        };

        var memory_ids = std.ArrayList(u64).init(allocator);
        defer memory_ids.deinit();

        for (test_memories) |content| {
            const memory_id = try mem_manager.storeMemory(
                memora.memory_types.MemoryType.experience,
                content,
                .{ 
                    .confidence = memora.memory_types.MemoryConfidence.high, 
                    .importance = memora.memory_types.MemoryImportance.high,
                    .create_embedding = true, // Ensure vector embeddings are created
                }
            );
            try memory_ids.append(memory_id);
            std.debug.print("✅ Stored memory {}: \"{s}\"\n", .{ memory_id, content });
        }

        // Verify vector embeddings exist before restart
        std.debug.print("\n📊 State before restart:\n", .{});
        std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});
        std.debug.print("  • Vector embeddings: {}\n", .{db.vector_index.getVectorCount()});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});

        for (memory_ids.items) |memory_id| {
            if (db.vector_index.getVector(memory_id)) |_| {
                std.debug.print("  ✅ Vector embedding exists for memory {}\n", .{memory_id});
            } else {
                std.debug.print("  ❌ Vector embedding missing for memory {}\n", .{memory_id});
            }
        }

        // Test semantic search before restart
        std.debug.print("\n🔍 Testing semantic search before restart:\n", .{});
        const similar_results = try db.querySimilar(memory_ids.items[0], 3);
        defer similar_results.deinit();
        std.debug.print("  Found {} similar vectors\n", .{similar_results.items.len});

        // Create snapshot to persist everything
        const snapshot_info = try db.createSnapshotWithMemoryManager(&mem_manager);
        defer snapshot_info.deinit();
        std.debug.print("\n📸 Created snapshot {} with {} memory contents\n", .{ snapshot_info.snapshot_id, snapshot_info.counts.memory_contents });
    }

    // Phase 2: Restart and verify complete restoration
    std.debug.print("\n--- Phase 2: Restart and verify complete restoration ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_complete_restoration",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memora.memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("\n📊 State after restart:\n", .{});
        std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});
        std.debug.print("  • Vector embeddings: {}\n", .{db.vector_index.getVectorCount()});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});

        // Verify all memories are restored with content
        const expected_memory_ids = [_]u64{ 1, 2, 3 };
        for (expected_memory_ids) |memory_id| {
            if (try mem_manager.getMemory(memory_id)) |memory| {
                std.debug.print("  ✅ Memory {} content restored: \"{s}\"\n", .{ memory_id, memory.getContentAsString() });
            } else {
                std.debug.print("  ❌ Memory {} content missing!\n", .{memory_id});
                return error.MemoryContentMissing;
            }

            // Verify vector embedding is restored
            if (db.vector_index.getVector(memory_id)) |_| {
                std.debug.print("  ✅ Vector embedding restored for memory {}\n", .{memory_id});
            } else {
                std.debug.print("  ❌ Vector embedding missing for memory {}!\n", .{memory_id});
                return error.VectorEmbeddingMissing;
            }
        }

        // Test semantic search after restart
        std.debug.print("\n🔍 Testing semantic search after restart:\n", .{});
        const similar_results = try db.querySimilar(1, 3);
        defer similar_results.deinit();
        std.debug.print("  Found {} similar vectors\n", .{similar_results.items.len});

        if (similar_results.items.len == 0) {
            std.debug.print("  ❌ Semantic search returned no results!\n", .{});
            return error.SemanticSearchFailed;
        }

        for (similar_results.items) |result| {
            std.debug.print("    Memory {}: similarity = {d:.3}\n", .{ result.id, result.similarity });
        }

        // Test concept-based search
        std.debug.print("\n🔍 Testing concept-based search:\n", .{});
        const query_embedding = try mem_manager.generateEmbedding("programming music");
        const query_vector = memora.types.Vector.init(0, &query_embedding);
        
        const concept_results = try db.vector_search.querySimilarByVector(&db.vector_index, query_vector, 3);
        defer concept_results.deinit();
        
        std.debug.print("  Found {} conceptually similar memories\n", .{concept_results.items.len});
        for (concept_results.items) |result| {
            std.debug.print("    Memory {}: similarity = {d:.3}\n", .{ result.id, result.similarity });
        }

        if (concept_results.items.len == 0) {
            std.debug.print("  ❌ Concept-based search returned no results!\n", .{});
            return error.ConceptSearchFailed;
        }

        std.debug.print("\n🎉 SUCCESS: Complete memory restoration verified!\n", .{});
        std.debug.print("  ✅ Memory content persistence\n", .{});
        std.debug.print("  ✅ Vector embedding restoration\n", .{});
        std.debug.print("  ✅ Semantic search functionality\n", .{});
        std.debug.print("  ✅ Concept-based search functionality\n", .{});
    }
} 