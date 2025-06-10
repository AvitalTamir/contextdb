const std = @import("std");
const contextdb = @import("contextdb");

const ContextDB = contextdb.ContextDB;
const mcp_server = contextdb.mcp_server;

/// Standalone MCP server for Memora - provides Model Context Protocol access to the memory database
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var data_path: []const u8 = "memora_mcp_data";
    var transport_type: []const u8 = "stdio";

    // Simple argument parsing
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--data=")) {
            data_path = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--transport=")) {
            transport_type = arg[12..];
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
    }

    // Only stdio transport is supported for now
    if (!std.mem.eql(u8, transport_type, "stdio")) {
        std.debug.print("Error: Only stdio transport is currently supported\n", .{});
        std.debug.print("Use --transport=stdio or omit the argument\n", .{});
        return;
    }

    // Write startup message to stderr so it doesn't interfere with JSON-RPC on stdout
    std.debug.print("Memora MCP Server initializing...\n", .{});
    std.debug.print("Data path: {s}\n", .{data_path});
    std.debug.print("Transport: {s}\n", .{transport_type});

    // Initialize ContextDB for memory storage
    const config = contextdb.ContextDBConfig{
        .data_path = data_path,
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = ContextDB.init(allocator, config, null) catch |err| {
        std.debug.print("Failed to initialize Memora database: {}\n", .{err});
        return;
    };
    defer db.deinit();

    std.debug.print("Memora database initialized successfully\n", .{});

    // Pre-populate with some sample memories for demo purposes
    if (try shouldPopulateSampleMemories(&db)) {
        try populateSampleMemories(&db);
        std.debug.print("Sample memories populated\n", .{});
    }

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0); // Port not used for stdio

    std.debug.print("Starting MCP server on stdio transport...\n", .{});
    std.debug.print("Ready to accept MCP requests from LLMs\n\n", .{});

    // Start the MCP server (this will block and communicate via stdio)
    server.start() catch |err| {
        std.debug.print("MCP server error: {}\n", .{err});
        return;
    };
}

fn printHelp() void {
    std.debug.print("Memora MCP Server - Model Context Protocol interface for LLM memory\n\n", .{});
    std.debug.print("Usage: mcp_server [options]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --data=PATH        Set memory data directory (default: memora_mcp_data)\n", .{});
    std.debug.print("  --transport=TYPE   Set transport type (default: stdio)\n", .{});
    std.debug.print("  --help             Show this help message\n\n", .{});
    std.debug.print("Transport Types:\n", .{});
    std.debug.print("  stdio              Standard input/output (for direct LLM integration)\n\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  mcp_server                                   # Default stdio transport\n", .{});
    std.debug.print("  mcp_server --data=/var/lib/memora           # Custom data directory\n", .{});
    std.debug.print("  mcp_server --transport=stdio --data=./mem   # Explicit configuration\n\n", .{});
    std.debug.print("LLM Integration:\n", .{});
    std.debug.print("  This server implements the Model Context Protocol (MCP) for LLM integration.\n", .{});
    std.debug.print("  LLMs can use this server to store and retrieve long-term memories.\n", .{});
    std.debug.print("  Configure your LLM client to use this server as an MCP server.\n", .{});
}

fn shouldPopulateSampleMemories(db: *ContextDB) !bool {
    const stats = db.getStats();
    return stats.node_count == 0 and stats.edge_count == 0 and stats.vector_count == 0;
}

fn populateSampleMemories(db: *ContextDB) !void {
    std.debug.print("Populating sample memories for LLM integration...\n", .{});

    // Create sample memory nodes representing different types of memories
    try db.insertNode(contextdb.types.Node.init(1, "UserPreference_ConciseHelp"));
    try db.insertNode(contextdb.types.Node.init(2, "ConversationContext_Programming"));
    try db.insertNode(contextdb.types.Node.init(3, "LearnedFact_UserSkillLevel"));
    try db.insertNode(contextdb.types.Node.init(4, "Experience_SuccessfulSolution"));
    try db.insertNode(contextdb.types.Node.init(5, "Concept_AsyncProgramming"));
    try db.insertNode(contextdb.types.Node.init(6, "Pattern_CodeReviewStyle"));

    // Create memory relationships
    try db.insertEdge(contextdb.types.Edge.init(1, 2, contextdb.types.EdgeKind.related));    // User preferences related to programming context
    try db.insertEdge(contextdb.types.Edge.init(2, 3, contextdb.types.EdgeKind.child_of));   // Context contains skill level info
    try db.insertEdge(contextdb.types.Edge.init(3, 4, contextdb.types.EdgeKind.links));      // Skill level linked to successful solution
    try db.insertEdge(contextdb.types.Edge.init(4, 5, contextdb.types.EdgeKind.related));    // Solution related to async programming
    try db.insertEdge(contextdb.types.Edge.init(5, 6, contextdb.types.EdgeKind.similar_to)); // Async concepts similar to review patterns

    // Create semantic embeddings for memory retrieval
    const preference_embedding = generateMemoryEmbedding(0.9, 0.2, 0.1, 0.8);      // User preference signal
    const context_embedding = generateMemoryEmbedding(0.7, 0.8, 0.3, 0.6);        // Programming context
    const skill_embedding = generateMemoryEmbedding(0.5, 0.9, 0.4, 0.7);          // Skill assessment
    const solution_embedding = generateMemoryEmbedding(0.8, 0.6, 0.9, 0.5);       // Successful solution
    const concept_embedding = generateMemoryEmbedding(0.3, 0.7, 0.8, 0.9);        // Technical concept
    const pattern_embedding = generateMemoryEmbedding(0.6, 0.5, 0.7, 0.8);        // Code pattern

    try db.insertVector(contextdb.types.Vector.init(1, &preference_embedding));
    try db.insertVector(contextdb.types.Vector.init(2, &context_embedding));
    try db.insertVector(contextdb.types.Vector.init(3, &skill_embedding));
    try db.insertVector(contextdb.types.Vector.init(4, &solution_embedding));
    try db.insertVector(contextdb.types.Vector.init(5, &concept_embedding));
    try db.insertVector(contextdb.types.Vector.init(6, &pattern_embedding));

    std.debug.print("Sample memories created:\n", .{});
    std.debug.print("  - User preferences and communication style\n", .{});
    std.debug.print("  - Programming conversation contexts\n", .{});
    std.debug.print("  - Learned facts about user skill levels\n", .{});
    std.debug.print("  - Successful solution experiences\n", .{});
    std.debug.print("  - Technical concepts and patterns\n", .{});
    std.debug.print("  - Semantic embeddings for memory similarity search\n", .{});
}

fn generateMemoryEmbedding(dim1: f32, dim2: f32, dim3: f32, dim4: f32) [128]f32 {
    var vector = [_]f32{0.0} ** 128;
    
    // Set key dimensions for memory categorization
    vector[0] = dim1;  // Memory type strength
    vector[1] = dim2;  // Context relevance 
    vector[2] = dim3;  // Confidence level
    vector[3] = dim4;  // Temporal relevance
    
    // Add some structured variation for realistic embeddings
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();
    
    for (4..16) |i| {
        vector[i] = (dim1 + dim2 + dim3 + dim4) / 4.0 + random.float(f32) * 0.2 - 0.1;
    }
    
    // Add noise to remaining dimensions
    for (16..128) |i| {
        vector[i] = random.float(f32) * 0.1;
    }
    
    return vector;
} 