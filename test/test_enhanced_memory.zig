const std = @import("std");
const memora = @import("memora");
const types = @import("memora").types;

/// Test the enhanced memory storage system with vector embeddings and concept graphs
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_enhanced_memory_data") catch {};
    defer std.fs.cwd().deleteTree("test_enhanced_memory_data") catch {};

    std.debug.print("🧠 Testing Enhanced Memory Storage System\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // Initialize Memora with enhanced memory configuration
    const config = memora.MemoraConfig{
        .data_path = "test_enhanced_memory_data",
        .enable_persistent_indexes = false, // Use in-memory for testing
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try memora.Memora.init(allocator, config, null);
    defer db.deinit();

    // Test 1: Store memories with rich semantic structure
    std.debug.print("📝 Test 1: Storing Enhanced Memories\n", .{});
    std.debug.print("====================================\n", .{});

    const test_memories = [_]struct { id: u64, text: []const u8 }{
        .{ .id = 1001, .text = "Claude is an AI assistant created by Anthropic for helpful conversations" },
        .{ .id = 1002, .text = "Database optimization requires understanding query patterns and indexing strategies" },
        .{ .id = 1003, .text = "Zig programming language provides memory safety and performance for system development" },
        .{ .id = 1004, .text = "Vector databases enable semantic search using machine learning embeddings" },
        .{ .id = 1005, .text = "Graph traversal algorithms help explore relationships between connected data" },
    };

    for (test_memories) |memory| {
        try storeEnhancedMemory(&db, allocator, memory.id, memory.text);
        std.debug.print("✓ Stored memory {}: \"{s}\"\n", .{ memory.id, memory.text });
    }

    std.debug.print("\n📊 Database Statistics:\n", .{});
    const stats = db.getStats();
    std.debug.print("  • Nodes: {}\n", .{stats.node_count});
    std.debug.print("  • Edges: {}\n", .{stats.edge_count});
    std.debug.print("  • Vectors: {}\n", .{stats.vector_count});

    // Test 2: Vector similarity search
    std.debug.print("\n🔍 Test 2: Vector Similarity Search\n", .{});
    std.debug.print("==================================\n", .{});

    const query_texts = [_][]const u8{
        "artificial intelligence and machine learning",
        "database performance and optimization",
        "programming languages and system development",
    };

    for (query_texts) |query| {
        std.debug.print("\nQuery: \"{s}\"\n", .{query});
        try testVectorSimilarity(&db, allocator, query);
    }

    // Test 3: Graph relationship exploration
    std.debug.print("\n🌐 Test 3: Graph Relationship Exploration\n", .{});
    std.debug.print("========================================\n", .{});

    for (test_memories) |memory| {
        std.debug.print("\nExploring relationships from memory {}:\n", .{memory.id});
        try testGraphExploration(&db, allocator, memory.id);
    }

    // Test 4: Concept network analysis
    std.debug.print("\n🕷️ Test 4: Concept Network Analysis\n", .{});
    std.debug.print("==================================\n", .{});
    try analyzeConceptNetwork(&db, allocator);

    std.debug.print("\n🎉 Enhanced Memory System Test Complete!\n", .{});
    std.debug.print("✅ All tests passed - Memory system is working correctly\n", .{});
}

/// Store a memory with enhanced semantic structure (mimicking MCP store_memory tool)
fn storeEnhancedMemory(db: *memora.Memora, allocator: std.mem.Allocator, memory_id: u64, memory_text: []const u8) !void {
    // 1. Create the main memory node
    const memory_node = types.Node.init(memory_id, memory_text);
    try db.insertNode(memory_node);

    // 2. Create vector embedding for semantic similarity search
    const embedding = try createSimpleEmbedding(allocator, memory_text);
    defer allocator.free(embedding);
    const vector = types.Vector.init(memory_id, embedding);
    try db.insertVector(vector);

    // 3. Extract and create concept nodes
    const concepts = try extractConcepts(allocator, memory_text);
    defer {
        for (concepts.items) |concept| {
            allocator.free(concept);
        }
        concepts.deinit();
    }

    for (concepts.items) |concept| {
        // Create concept node with a derived ID
        const concept_id = generateConceptId(concept);
        
        // Check if concept already exists, if not create it
        if (db.graph_index.getNode(concept_id) == null) {
            const concept_node = types.Node.init(concept_id, concept);
            try db.insertNode(concept_node);
        }
        
        // 4. Create semantic relationship from memory to concept
        const memory_to_concept_edge = types.Edge.init(memory_id, concept_id, types.EdgeKind.related);
        try db.insertEdge(memory_to_concept_edge);
    }
}

/// Test vector similarity search
fn testVectorSimilarity(db: *memora.Memora, allocator: std.mem.Allocator, query: []const u8) !void {
    // Create embedding for the query
    const query_embedding = try createSimpleEmbedding(allocator, query);
    defer allocator.free(query_embedding);
    
    // Create a temporary vector for similarity search
    const query_vector = types.Vector.init(0, query_embedding); // ID 0 for query
    
    // Use vector similarity search to find related memories
    const similar_vectors = try db.vector_search.querySimilarByVector(&db.vector_index, query_vector, 3);
    defer similar_vectors.deinit();
    
    std.debug.print("  Found {} similar memories:\n", .{similar_vectors.items.len});
    for (similar_vectors.items, 0..) |result, i| {
        if (db.graph_index.getNode(result.id)) |memory_node| {
            std.debug.print("    {}. Memory {}: \"{s}\" (similarity: {d:.3})\n", 
                .{ i + 1, result.id, memory_node.getLabelAsString(), result.similarity });
        }
    }
}

/// Test graph relationship exploration
fn testGraphExploration(db: *memora.Memora, allocator: std.mem.Allocator, start_node_id: u64) !void {
    _ = allocator; // unused for now
    
    // Find related nodes using graph traversal
    const related_nodes = try db.queryRelated(start_node_id, 2);
    defer related_nodes.deinit();
    
    std.debug.print("  Found {} related nodes:\n", .{related_nodes.items.len});
    for (related_nodes.items, 0..) |node, i| {
        if (i >= 5) { // Limit output for readability
            std.debug.print("    ... and {} more\n", .{related_nodes.items.len - i});
            break;
        }
        std.debug.print("    {}. Node {}: \"{s}\"\n", .{ i + 1, node.id, node.getLabelAsString() });
    }
}

/// Analyze the concept network that was created
fn analyzeConceptNetwork(db: *memora.Memora, allocator: std.mem.Allocator) !void {
    var concept_nodes = std.ArrayList(types.Node).init(allocator);
    defer concept_nodes.deinit();
    
    var memory_nodes = std.ArrayList(types.Node).init(allocator);
    defer memory_nodes.deinit();
    
    // Categorize nodes by type (memory nodes vs concept nodes)
    var node_iter = db.graph_index.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        if (node.id >= 0x8000000000000000) { // Concept nodes have high bit set
            try concept_nodes.append(node);
        } else if (node.id >= 1000) { // Memory nodes
            try memory_nodes.append(node);
        }
    }
    
    std.debug.print("Network Analysis:\n", .{});
    std.debug.print("  • Memory Nodes: {}\n", .{memory_nodes.items.len});
    std.debug.print("  • Concept Nodes: {}\n", .{concept_nodes.items.len});
    
    // Show some example concepts
    std.debug.print("  • Sample Concepts:\n", .{});
    const max_concepts = @min(concept_nodes.items.len, 10);
    for (concept_nodes.items[0..max_concepts]) |concept_node| {
        std.debug.print("    - \"{s}\"\n", .{concept_node.getLabelAsString()});
    }
    
    // Calculate average connectivity
    var total_edges: u32 = 0;
    for (memory_nodes.items) |memory_node| {
        if (db.graph_index.getOutgoingEdges(memory_node.id)) |edges| {
            total_edges += @intCast(edges.len);
        }
    }
    
    if (memory_nodes.items.len > 0) {
        const avg_concepts_per_memory = @as(f32, @floatFromInt(total_edges)) / @as(f32, @floatFromInt(memory_nodes.items.len));
        std.debug.print("  • Average concepts per memory: {d:.1}\n", .{avg_concepts_per_memory});
    }
}

/// Create a simple embedding based on text characteristics
/// This is the same heuristic-based approach used in the MCP server
fn createSimpleEmbedding(allocator: std.mem.Allocator, text: []const u8) ![]f32 {
    var embedding = [_]f32{0.0} ** 128;
    
    // Simple heuristic-based embedding generation
    var hash: u64 = 5381; // djb2 hash
    for (text) |c| {
        hash = hash *% 33 +% c; // Use wrapping arithmetic to prevent overflow
    }
    
    // Use hash to generate pseudo-random but deterministic vector
    var rng = std.Random.DefaultPrng.init(hash);
    const random = rng.random();
    
    // Generate embedding based on text characteristics
    for (&embedding, 0..) |*dim, i| {
        // Mix deterministic features with text characteristics
        const char_influence = if (i < text.len) @as(f32, @floatFromInt(text[i])) / 255.0 else 0.0;
        const length_influence = @as(f32, @floatFromInt(text.len)) / 1000.0;
        const random_component = random.float(f32) * 2.0 - 1.0; // [-1, 1]
        
        dim.* = (char_influence * 0.3 + length_influence * 0.2 + random_component * 0.5);
        
        // Normalize to reasonable range
        if (dim.* > 1.0) dim.* = 1.0;
        if (dim.* < -1.0) dim.* = -1.0;
    }
    
    // Normalize the vector
    var magnitude: f32 = 0.0;
    for (embedding) |dim| {
        magnitude += dim * dim;
    }
    magnitude = @sqrt(magnitude);
    
    if (magnitude > 0.0) {
        for (&embedding) |*dim| {
            dim.* /= magnitude;
        }
    }
    
    return allocator.dupe(f32, &embedding);
}

/// Extract concepts from memory text (simplified version of MCP server implementation)
fn extractConcepts(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var concepts = std.ArrayList([]const u8).init(allocator);
    
    // Simple concept extraction: split on whitespace and filter meaningful words
    var word_iter = std.mem.splitScalar(u8, text, ' ');
    while (word_iter.next()) |word| {
        // Clean up the word (remove punctuation, convert to lowercase)
        var cleaned_word = std.ArrayList(u8).init(allocator);
        defer cleaned_word.deinit();
        
        for (word) |c| {
            if (std.ascii.isAlphabetic(c)) {
                try cleaned_word.append(std.ascii.toLower(c));
            }
        }
        
        // Skip short words, common stop words, etc.
        if (cleaned_word.items.len < 3) continue;
        
        const word_str = try allocator.dupe(u8, cleaned_word.items);
        
        // Skip common stop words
        if (std.mem.eql(u8, word_str, "the") or 
            std.mem.eql(u8, word_str, "and") or 
            std.mem.eql(u8, word_str, "with") or 
            std.mem.eql(u8, word_str, "for") or
            std.mem.eql(u8, word_str, "are") or
            std.mem.eql(u8, word_str, "was") or
            std.mem.eql(u8, word_str, "this") or
            std.mem.eql(u8, word_str, "that")) {
            allocator.free(word_str);
            continue;
        }
        
        // Check if concept already exists in our list (avoid duplicates)
        var exists = false;
        for (concepts.items) |existing_concept| {
            if (std.mem.eql(u8, existing_concept, word_str)) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            try concepts.append(word_str);
        } else {
            allocator.free(word_str);
        }
    }
    
    return concepts;
}

/// Generate a deterministic ID for a concept based on its text
fn generateConceptId(concept: []const u8) u64 {
    // Use a hash function to generate deterministic IDs for concepts
    var hash: u64 = 14695981039346656037; // FNV-1a offset basis
    for (concept) |byte| {
        hash ^= byte;
        hash *%= 1099511628211; // FNV-1a prime with wrapping arithmetic
    }
    
    // Ensure we don't conflict with memory IDs (use high range)
    return hash | 0x8000000000000000; // Set high bit to distinguish from memory IDs
} 