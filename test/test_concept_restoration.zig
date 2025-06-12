const std = @import("std");
const memora = @import("memora");
const memory_manager = memora.memory_manager;
const memory_types = memora.memory_types;
const types = memora.types;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔍 Testing Concept and Vector Restoration After Restart\n", .{});
    std.debug.print("=====================================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_concept_restoration") catch {};
    defer std.fs.cwd().deleteTree("test_concept_restoration") catch {};

    // Phase 1: Store memories with concepts and vectors
    {
        std.debug.print("📝 Phase 1: Storing memories with concepts and vectors...\n", .{});
        
        const config = memora.MemoraConfig{
            .data_path = "test_concept_restoration",
            .enable_persistent_indexes = false,
            .auto_snapshot_interval = null,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        // Store a memory with extractable concepts
        const memory_content = "User loves playing banjo and learning Zig programming language";
        const memory_id = try mem_manager.storeMemory(
            memory_types.MemoryType.experience,
            memory_content,
            .{ .confidence = memory_types.MemoryConfidence.high, .importance = memory_types.MemoryImportance.high }
        );
        
        std.debug.print("✅ Stored memory {}: \"{s}\"\n", .{ memory_id, memory_content });

        // Manually create concepts and edges like the MCP server does
        const concepts = [_][]const u8{ "banjo", "programming", "language" };
        for (concepts) |concept| {
            const concept_id = generateConceptId(concept);
            
            // Create concept node
            const concept_node = types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
            
            // Create edge from memory to concept
            const edge = types.Edge.init(memory_id, concept_id, types.EdgeKind.related);
            try db.insertEdge(edge);
            
                         std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ concept, memory_id, concept_id });
        }

        // Create vector embedding
        var embedding: [128]f32 = undefined;
        for (&embedding, 0..) |*dim, i| {
            dim.* = @sin(@as(f32, @floatFromInt(i)) * 0.1); // Simple pattern
        }
        const vector = types.Vector.init(memory_id, &embedding);
        try db.insertVector(vector);
        
        std.debug.print("  ✅ Created vector embedding for memory {}\n", .{memory_id});

        // Check current state
        std.debug.print("\n📊 Current state before restart:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});
        std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});
        
        // Check if we can find concepts
        for (concepts) |concept| {
            const concept_id = generateConceptId(concept);
                         if (db.graph_index.getNode(concept_id)) |node| {
                 std.debug.print("  • Found concept node '{s}': {}\n", .{ node.getLabelAsString(), concept_id });
             } else {
                 std.debug.print("  ❌ Missing concept node: {s}\n", .{concept});
             }
        }
    }

    // Phase 2: Restart and check what's restored
    {
        std.debug.print("\n🔄 Phase 2: Simulating restart...\n", .{});
        
        const config = memora.MemoraConfig{
            .data_path = "test_concept_restoration",
            .enable_persistent_indexes = false,
            .auto_snapshot_interval = null,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mem_manager = memory_manager.MemoryManager.init(allocator, &db);
        defer mem_manager.deinit();

        std.debug.print("\n📊 State after restart:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});
        std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});

        // Check if memory content is restored
        if (try mem_manager.getMemory(1)) |memory| {
            std.debug.print("  ✅ Memory content restored: \"{s}\"\n", .{memory.getContentAsString()});
        } else {
            std.debug.print("  ❌ Memory content missing!\n", .{});
        }

        // Check if concepts are restored
        const concepts = [_][]const u8{ "banjo", "programming", "language" };
        var restored_concepts: u32 = 0;
        var restored_edges: u32 = 0;
        
        for (concepts) |concept| {
            const concept_id = generateConceptId(concept);
                         if (db.graph_index.getNode(concept_id)) |node| {
                 std.debug.print("  ✅ Concept node restored: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                 restored_concepts += 1;
                 
                 // Check if edge exists
                 if (db.graph_index.getIncomingEdges(concept_id)) |edges| {
                     for (edges) |edge| {
                         if (edge.from == 1 and edge.getKind() == types.EdgeKind.related) {
                             std.debug.print("    ✅ Edge restored: {} -> {}\n", .{ edge.from, edge.to });
                             restored_edges += 1;
                             break;
                         }
                     }
                 }
             } else {
                 std.debug.print("  ❌ Concept node missing: '{s}' ({})\n", .{ concept, concept_id });
             }
        }

        // Check if vector is restored
        var restored_vector = false;
        if (db.vector_index.getVector(1)) |_| {
            std.debug.print("  ✅ Vector embedding restored\n", .{});
            restored_vector = true;
        } else {
            std.debug.print("  ❌ Vector embedding missing!\n", .{});
        }

        // Summary
        std.debug.print("\n📊 Restoration Summary:\n", .{});
        std.debug.print("  • Concepts restored: {}/3\n", .{restored_concepts});
        std.debug.print("  • Edges restored: {}/3\n", .{restored_edges});
        std.debug.print("  • Vector restored: {}\n", .{restored_vector});

        if (restored_concepts == 3 and restored_edges == 3 and restored_vector) {
            std.debug.print("\n🎉 SUCCESS: All concepts and vectors properly restored!\n", .{});
        } else {
            std.debug.print("\n❌ ISSUE: Concepts/vectors not fully restored after restart\n", .{});
            std.debug.print("This explains why recall_similar and search_memories_by_concept don't work\n", .{});
        }
    }
}

/// Generate a deterministic ID for a concept based on its text
fn generateConceptId(concept: []const u8) u64 {
    // Use a hash function to generate deterministic IDs for concepts
    var hash: u64 = 14695981039346656037; // FNV-1a offset basis
    for (concept) |byte| {
        hash ^= byte;
        hash *%= 1099511628211; // FNV-1a prime
    }
    
    // Ensure we don't conflict with memory IDs (use high range)
    return hash | 0x8000000000000000; // Set high bit to distinguish from memory IDs
} 