const std = @import("std");
const memora = @import("memora");
const memory_manager = memora.memory_manager;
const memory_types = memora.memory_types;
const types = memora.types;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🔧 Testing Vector Embedding Fix for MCP Server\n", .{});
    std.debug.print("==============================================\n\n", .{});

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_vector_fix") catch {};
    defer std.fs.cwd().deleteTree("test_vector_fix") catch {};

    // Initialize database
    const config = memora.MemoraConfig{
        .data_path = "test_vector_fix",
        .enable_persistent_indexes = false,
        .auto_snapshot_interval = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    var mem_manager = memory_manager.MemoryManager.init(allocator, &db);
    defer mem_manager.deinit();

    std.debug.print("📝 Testing memory storage with vector embeddings...\n", .{});

    // Test 1: Store memory with create_embedding = true (like the fixed MCP server)
    const memory_content = "User loves playing banjo and learning Zig programming";
    const memory_id = try mem_manager.storeMemory(
        memory_types.MemoryType.experience,
        memory_content,
        .{ 
            .confidence = memory_types.MemoryConfidence.high, 
            .importance = memory_types.MemoryImportance.high,
            .create_embedding = true, // This is what the fix adds
        }
    );
    
    std.debug.print("✅ Stored memory {}: \"{s}\"\n", .{ memory_id, memory_content });

    // Check if vector embedding was created
    if (db.vector_index.getVector(memory_id)) |vector| {
        std.debug.print("✅ Vector embedding created: {} dimensions\n", .{vector.dims.len});
        
        // Show first few dimensions
        std.debug.print("  First 5 dimensions: [", .{});
        for (vector.dims[0..5], 0..) |dim, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{d:.3}", .{dim});
        }
        std.debug.print("...]\n", .{});
    } else {
        std.debug.print("❌ Vector embedding missing!\n", .{});
    }

    // Test 2: Store another memory to test semantic similarity
    const memory_content2 = "User enjoys musical instruments and software development";
    const memory_id2 = try mem_manager.storeMemory(
        memory_types.MemoryType.preference,
        memory_content2,
        .{ 
            .confidence = memory_types.MemoryConfidence.medium, 
            .importance = memory_types.MemoryImportance.medium,
            .create_embedding = true,
        }
    );
    
    std.debug.print("✅ Stored memory {}: \"{s}\"\n", .{ memory_id2, memory_content2 });

    // Check if second vector embedding was created
    if (db.vector_index.getVector(memory_id2)) |_| {
        std.debug.print("✅ Second vector embedding created\n", .{});
    } else {
        std.debug.print("❌ Second vector embedding missing!\n", .{});
    }

    // Test 3: Test semantic similarity search (this should now work)
    std.debug.print("\n🔍 Testing semantic similarity search...\n", .{});
    
    const similar_results = try db.querySimilar(memory_id, 5);
    defer similar_results.deinit();
    
    std.debug.print("Found {} similar vectors to memory {}:\n", .{ similar_results.items.len, memory_id });
    for (similar_results.items) |result| {
        if (result.id != memory_id) { // Don't show self-similarity
            std.debug.print("  Memory {}: similarity = {d:.3}\n", .{ result.id, result.similarity });
        }
    }

    // Test 4: Test vector-based memory query (like recall_similar would use)
    std.debug.print("\n🧠 Testing memory query with semantic search...\n", .{});
    
    const query = memory_types.MemoryQuery{
        .query_text = "music and programming",
        .limit = 5,
        .include_related = false,
        .memory_types = null,
        .min_confidence = null,
        .min_importance = null,
        .session_id = null,
        .user_id = null,
        .created_after = null,
        .created_before = null,
        .accessed_after = null,
        .accessed_before = null,
        .relation_types = null,
        .max_depth = 2,
    };
    
    var query_result = try mem_manager.queryMemories(query);
    defer query_result.deinit();
    
    std.debug.print("Query for 'music and programming' found {} memories:\n", .{query_result.memories.items.len});
    for (query_result.memories.items) |memory| {
        std.debug.print("  Memory {}: \"{s}\" (confidence: {s})\n", .{ 
            memory.id, 
            memory.getContentAsString(), 
            @tagName(memory.confidence) 
        });
    }

    // Summary
    std.debug.print("\n📊 Test Summary:\n", .{});
    std.debug.print("  • Total vectors created: {}\n", .{db.vector_index.getVectorCount()});
    std.debug.print("  • Total graph nodes: {}\n", .{db.graph_index.nodes.count()});
    std.debug.print("  • Memory content cache: {}\n", .{mem_manager.memory_content.count()});

    if (db.vector_index.getVectorCount() >= 2) {
        std.debug.print("\n🎉 SUCCESS: Vector embeddings are now being created!\n", .{});
        std.debug.print("This should fix recall_similar and improve search_memories_by_concept\n", .{});
    } else {
        std.debug.print("\n❌ ISSUE: Vector embeddings still not being created properly\n", .{});
    }
} 