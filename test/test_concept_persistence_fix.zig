const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "concept persistence across MCP server restarts" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_concept_persistence") catch {};
    defer std.fs.cwd().deleteTree("test_concept_persistence") catch {};

    std.debug.print("\n=== Testing Concept Persistence Across MCP Server Restarts ===\n", .{});

    // Phase 1: Create MCP server and store memory with concepts
    std.debug.print("\n--- Phase 1: Creating memory with concepts ---\n", .{});
    var concept_ids = std.ArrayList(u64).init(allocator);
    defer concept_ids.deinit();
    {
        const config = memora.MemoraConfig{
            .data_path = "test_concept_persistence",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mcp_server = memora.mcp_server.McpServer.init(allocator, &db, 0);
        defer mcp_server.deinit(); // This should create final snapshot with concepts

        // Store a memory that will generate concepts
        const memory_id = try mcp_server.memory_manager.storeMemory(
            memora.memory_types.MemoryType.experience,
            "User loves playing banjo and learning Zig programming language",
            .{ 
                .confidence = memora.memory_types.MemoryConfidence.high, 
                .importance = memora.memory_types.MemoryImportance.high,
                .create_embedding = true,
            }
        );
        std.debug.print("✅ Stored memory {}\n", .{memory_id});

        // Manually extract concepts and create relationships like the MCP server does
        const concepts = try mcp_server.extractConcepts("User loves playing banjo and learning Zig programming language");
        defer {
            for (concepts.items) |concept| {
                allocator.free(concept);
            }
            concepts.deinit();
        }

        var created_concepts = std.ArrayList(u64).init(allocator);
        defer created_concepts.deinit();

        for (concepts.items) |concept| {
            const concept_id = mcp_server.generateConceptId(concept);
            concept_ids.append(concept_id) catch unreachable;
            
            // Create concept node
            const concept_node = memora.types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
            
            // Create relationship from memory to concept
            const memory_to_concept_edge = memora.types.Edge.init(memory_id, concept_id, memora.types.EdgeKind.related);
            try db.insertEdge(memory_to_concept_edge);
            
            try created_concepts.append(concept_id);
            std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ concept, memory_id, concept_id });
        }

        // Verify concepts exist before restart
        std.debug.print("\n📊 State before restart:\n", .{});
        std.debug.print("  • Memory content cache: {}\n", .{mcp_server.memory_manager.memory_content.count()});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vector embeddings: {}\n", .{db.vector_index.getVectorCount()});

        for (created_concepts.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node exists: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
            } else {
                std.debug.print("  ❌ Concept node missing: {}\n", .{concept_id});
            }
        }

        // MCP server deinit() will be called here, creating final snapshot with concepts
    }

    // Phase 2: Restart MCP server and verify concepts are restored
    std.debug.print("\n--- Phase 2: Restart and verify concept restoration ---\n", .{});
    {
        const config = memora.MemoraConfig{
            .data_path = "test_concept_persistence",
            .auto_snapshot_interval = null,
            .enable_persistent_indexes = false,
        };

        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mcp_server = memora.mcp_server.McpServer.init(allocator, &db, 0);
        defer mcp_server.deinit();

        std.debug.print("\n📊 State after restart:\n", .{});
        std.debug.print("  • Memory content cache: {}\n", .{mcp_server.memory_manager.memory_content.count()});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vector embeddings: {}\n", .{db.vector_index.getVectorCount()});

        // Verify memory content is restored
        if (try mcp_server.memory_manager.getMemory(1)) |memory| {
            std.debug.print("  ✅ Memory content restored: \"{s}\"\n", .{memory.getContentAsString()});
        } else {
            std.debug.print("  ❌ Memory content missing!\n", .{});
            return error.MemoryContentMissing;
        }

        // Verify vector embedding is restored
        if (db.vector_index.getVector(1)) |_| {
            std.debug.print("  ✅ Vector embedding restored\n", .{});
        } else {
            std.debug.print("  ❌ Vector embedding missing!\n", .{});
            return error.VectorEmbeddingMissing;
        }

        // Verify concept nodes are restored
        var restored_concepts: u32 = 0;
        var restored_edges: u32 = 0;

        for (concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node restored: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                restored_concepts += 1;

                // Check if edge from memory to concept exists
                if (db.graph_index.getIncomingEdges(concept_id)) |edges| {
                    for (edges) |edge| {
                        if (edge.from == 1 and edge.getKind() == memora.types.EdgeKind.related) {
                            std.debug.print("    ✅ Edge restored: {} -> {}\n", .{ edge.from, edge.to });
                            restored_edges += 1;
                            break;
                        }
                    }
                }
            } else {
                std.debug.print("  ❌ Concept node missing: {}\n", .{concept_id});
            }
        }

        // Test concept-based search functionality
        std.debug.print("\n🔍 Testing concept-based search:\n", .{});
        
        // Simulate the MCP server's search_memories_by_concept functionality
        const test_concept = "programming"; // One of the concepts we created
        const test_concept_id = mcp_server.generateConceptId(test_concept);
        
        if (db.graph_index.getNode(test_concept_id)) |_| {
            std.debug.print("  ✅ Concept '{s}' found in database\n", .{test_concept});
            
            // Check if there are incoming edges from memory nodes
            if (db.graph_index.getIncomingEdges(test_concept_id)) |incoming_edges| {
                var memory_connections: u32 = 0;
                for (incoming_edges) |edge| {
                    if (edge.from < 0x8000000000000000 and edge.getKind() == memora.types.EdgeKind.related) {
                        memory_connections += 1;
                    }
                }
                std.debug.print("  ✅ Found {} memory connections to concept '{s}'\n", .{ memory_connections, test_concept });
                
                if (memory_connections == 0) {
                    std.debug.print("  ❌ No memory connections found for concept!\n", .{});
                    return error.ConceptSearchFailed;
                }
            } else {
                std.debug.print("  ❌ No incoming edges found for concept!\n", .{});
                return error.ConceptSearchFailed;
            }
        } else {
            std.debug.print("  ❌ Concept '{s}' not found in database!\n", .{test_concept});
            return error.ConceptNotFound;
        }

        // Summary
        std.debug.print("\n📊 Restoration Summary:\n", .{});
        std.debug.print("  • Concepts restored: {}/{}\n", .{restored_concepts, concept_ids.items.len});
        std.debug.print("  • Edges restored: {}/{}\n", .{restored_edges, concept_ids.items.len});

        if (restored_concepts == concept_ids.items.len and restored_edges == concept_ids.items.len) {
            std.debug.print("\n🎉 SUCCESS: All concepts and relationships properly persisted!\n", .{});
        } else {
            std.debug.print("\n❌ FAILURE: Some concepts or relationships were lost!\n", .{});
            return error.ConceptPersistenceFailed;
        }
    }
} 