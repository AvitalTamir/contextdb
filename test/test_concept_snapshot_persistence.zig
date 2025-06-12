const std = @import("std");
const memora = @import("memora");
const testing = std.testing;

test "concept nodes and edges persist through snapshot creation and restoration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_concept_snapshot_persistence") catch {};
    defer std.fs.cwd().deleteTree("test_concept_snapshot_persistence") catch {};

    std.debug.print("\n=== Testing Concept Snapshot Persistence ===\n", .{});

    const config = memora.MemoraConfig{
        .data_path = "test_concept_snapshot_persistence",
        .auto_snapshot_interval = null,
        .enable_persistent_indexes = false,
    };

    // Phase 1: Create database with concept nodes and create snapshot
    std.debug.print("\n--- Phase 1: Create concepts and snapshot ---\n", .{});
    var concept_ids = std.ArrayList(u64).init(allocator);
    defer concept_ids.deinit();
    
    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        var mcp_srv = memora.mcp_server.McpServer.init(allocator, &db, 0);
        defer mcp_srv.deinit();

        // Store a memory that will generate concepts
        const memory_id = try mcp_srv.memory_manager.storeMemory(
            memora.memory_types.MemoryType.experience,
            "User loves playing banjo and learning Zig programming language",
            .{ 
                .confidence = memora.memory_types.MemoryConfidence.high, 
                .importance = memora.memory_types.MemoryImportance.high,
                .create_embedding = true,
            }
        );
        std.debug.print("✅ Stored memory {} via MemoryManager\n", .{memory_id});

        // Extract concepts and create relationships like the MCP server does
        const concepts = try mcp_srv.extractConcepts("User loves playing banjo and learning Zig programming language");
        defer {
            for (concepts.items) |concept| {
                allocator.free(concept);
            }
            concepts.deinit();
        }

        for (concepts.items) |concept| {
            const concept_id = mcp_srv.generateConceptId(concept);
            try concept_ids.append(concept_id);
            
            // Create concept node (like MCP server does)
            const concept_node = memora.types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
            
            // Create relationship from memory to concept (like MCP server does)
            const memory_to_concept_edge = memora.types.Edge.init(memory_id, concept_id, memora.types.EdgeKind.related);
            try db.insertEdge(memory_to_concept_edge);
            
            std.debug.print("  ✅ Created concept '{s}': {} -> {}\n", .{ concept, memory_id, concept_id });
        }

        std.debug.print("\n📊 State before snapshot:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Verify concept nodes exist before snapshot
        for (concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node exists: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
            } else {
                std.debug.print("  ❌ Concept node missing: {}\n", .{concept_id});
                return error.ConceptNodeMissing;
            }
        }

        // Create snapshot using the same method as MCP server deinit
        std.debug.print("\n📸 Creating snapshot with MemoryManager...\n", .{});
        var snapshot_info = try db.createSnapshotWithMemoryManager(&mcp_srv.memory_manager);
        defer snapshot_info.deinit();
        std.debug.print("✅ Created snapshot {}\n", .{snapshot_info.snapshot_id});

        // Verify what's in the snapshot
        std.debug.print("\n🔍 Analyzing snapshot contents...\n", .{});
        
        // Load nodes from snapshot
        const snapshot_nodes = try db.snapshot_manager.loadNodes(&snapshot_info);
        defer snapshot_nodes.deinit();
        
        // Load edges from snapshot
        const snapshot_edges = try db.snapshot_manager.loadEdges(&snapshot_info);
        defer snapshot_edges.deinit();

        std.debug.print("  • Snapshot contains {} nodes\n", .{snapshot_nodes.items.len});
        std.debug.print("  • Snapshot contains {} edges\n", .{snapshot_edges.items.len});

        // Count concept nodes and edges in snapshot
        var concept_nodes_in_snapshot: u32 = 0;
        var concept_edges_in_snapshot: u32 = 0;

        for (snapshot_nodes.items) |node| {
            if (node.id >= 0x8000000000000000) {
                concept_nodes_in_snapshot += 1;
                std.debug.print("  🏷️  Snapshot contains concept node: '{s}' ({})\n", .{ node.getLabelAsString(), node.id });
            }
        }

        for (snapshot_edges.items) |edge| {
            if (edge.from >= 0x8000000000000000 or edge.to >= 0x8000000000000000) {
                concept_edges_in_snapshot += 1;
                std.debug.print("  🔗 Snapshot contains concept edge: {} -> {}\n", .{ edge.from, edge.to });
            }
        }

        std.debug.print("  • Concept nodes in snapshot: {}\n", .{concept_nodes_in_snapshot});
        std.debug.print("  • Concept edges in snapshot: {}\n", .{concept_edges_in_snapshot});

        if (concept_nodes_in_snapshot != concept_ids.items.len) {
            std.debug.print("❌ ISSUE: Not all concept nodes were saved to snapshot!\n", .{});
            return error.ConceptNodesNotInSnapshot;
        }

        if (concept_edges_in_snapshot != concept_ids.items.len) {
            std.debug.print("❌ ISSUE: Not all concept edges were saved to snapshot!\n", .{});
            return error.ConceptEdgesNotInSnapshot;
        }
    }

    // Phase 2: Restart and load from snapshot (simulating real restart)
    std.debug.print("\n--- Phase 2: Restart and load from snapshot ---\n", .{});
    {
        var db = try memora.Memora.init(allocator, config, null);
        defer db.deinit();

        std.debug.print("\n📊 State after restart (after loadFromStorage):\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Vectors: {}\n", .{db.vector_index.getVectorCount()});

        // Check if concept nodes were restored from snapshot
        var restored_concept_nodes: u32 = 0;
        var restored_concept_edges: u32 = 0;

        for (concept_ids.items) |concept_id| {
            if (db.graph_index.getNode(concept_id)) |node| {
                std.debug.print("  ✅ Concept node restored: '{s}' ({})\n", .{ node.getLabelAsString(), concept_id });
                restored_concept_nodes += 1;

                // Check if edges were restored
                if (db.graph_index.getIncomingEdges(concept_id)) |edges| {
                    for (edges) |edge| {
                        if (edge.from == 1 and edge.getKind() == memora.types.EdgeKind.related) {
                            std.debug.print("    ✅ Concept edge restored: {} -> {}\n", .{ edge.from, edge.to });
                            restored_concept_edges += 1;
                            break;
                        }
                    }
                }
            } else {
                std.debug.print("  ❌ Concept node missing: {}\n", .{concept_id});
            }
        }

        std.debug.print("\n🎯 Snapshot Restoration Results:\n", .{});
        std.debug.print("  • Expected concept nodes: {}\n", .{concept_ids.items.len});
        std.debug.print("  • Restored concept nodes: {}\n", .{restored_concept_nodes});
        std.debug.print("  • Expected concept edges: {}\n", .{concept_ids.items.len});
        std.debug.print("  • Restored concept edges: {}\n", .{restored_concept_edges});

        if (restored_concept_nodes != concept_ids.items.len) {
            std.debug.print("\n❌ ISSUE: Not all concept nodes were restored from snapshot!\n", .{});
            return error.ConceptNodesNotRestored;
        }

        if (restored_concept_edges != concept_ids.items.len) {
            std.debug.print("\n❌ ISSUE: Not all concept edges were restored from snapshot!\n", .{});
            return error.ConceptEdgesNotRestored;
        }

        // Phase 3: Initialize MemoryManager and test concept search
        std.debug.print("\n--- Phase 3: Initialize MemoryManager and test concept search ---\n", .{});
        
        var mcp_srv = memora.mcp_server.McpServer.init(allocator, &db, 0);
        defer mcp_srv.deinit();

        std.debug.print("\n📊 State after MemoryManager initialization:\n", .{});
        std.debug.print("  • Graph nodes: {}\n", .{db.graph_index.nodes.count()});
        std.debug.print("  • Graph edges: {}\n", .{db.graph_index.outgoing_edges.count()});
        std.debug.print("  • Memory content cache: {}\n", .{mcp_srv.memory_manager.memory_content.count()});

        // Test concept-based search functionality
        const test_concept = "programming";
        const test_concept_id = mcp_srv.generateConceptId(test_concept);
        
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

        std.debug.print("\n🎉 SUCCESS: All concepts properly persisted through snapshot!\n", .{});
    }
} 