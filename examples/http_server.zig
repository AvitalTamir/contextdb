const std = @import("std");
const memora = @import("memora");

const Memora = memora.Memora;
const types = memora.types;
const http_api = memora.http_api;

/// Standalone HTTP API server for Memora
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var port: u16 = 8080;
    var data_path = "memora_http_data";

    // Simple argument parsing
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg[7..], 10) catch {
                std.debug.print("Invalid port: {s}\n", .{arg[7..]});
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            data_path = arg[7..];
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
    }

    std.debug.print("Starting Memora HTTP API server...\n", .{});
    std.debug.print("Data path: {s}\n", .{data_path});
    std.debug.print("Port: {}\n", .{port});

    // Initialize Memora
    const config = Memora.MemoraConfig{
        .data_path = data_path,
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = Memora.init(allocator, config) catch |err| {
        std.debug.print("Failed to initialize Memora: {}\n", .{err});
        return;
    };
    defer db.deinit();

    std.debug.print("Memora initialized successfully\n", .{});

    // Pre-populate with some sample data for demo purposes
    if (try shouldPopulateSampleData(&db)) {
        try populateSampleData(&db);
        std.debug.print("Sample data populated\n", .{});
    }

    // Initialize HTTP API server
    var api_server = http_api.ApiServer.init(allocator, &db, null, port, null);
    defer api_server.stop();

    std.debug.print("Starting HTTP server...\n\n", .{});

    // Handle graceful shutdown on Ctrl+C
    const original_handler = std.posix.signal.SIGINT;
    _ = original_handler;
    
    // Start the server (this will block)
    api_server.start() catch |err| {
        std.debug.print("Failed to start HTTP server: {}\n", .{err});
        return;
    };
}

fn printHelp() void {
    std.debug.print("Memora HTTP API Server\n\n");
    std.debug.print("Usage: http_server [options]\n\n");
    std.debug.print("Options:\n");
    std.debug.print("  --port=PORT    Set server port (default: 8080)\n");
    std.debug.print("  --data=PATH    Set data directory (default: memora_http_data)\n");
    std.debug.print("  --help         Show this help message\n\n");
    std.debug.print("Example:\n");
    std.debug.print("  http_server --port=9090 --data=/var/lib/memora\n");
}

fn shouldPopulateSampleData(db: *Memora) !bool {
    const stats = db.getStats();
    return stats.node_count == 0 and stats.edge_count == 0 and stats.vector_count == 0;
}

fn populateSampleData(db: *Memora) !void {
    std.debug.print("Populating sample data...\n", .{});

    // Create sample nodes
    try db.insertNode(types.Node.init(1, "Alice"));
    try db.insertNode(types.Node.init(2, "Bob"));
    try db.insertNode(types.Node.init(3, "Document1"));
    try db.insertNode(types.Node.init(4, "Document2"));
    try db.insertNode(types.Node.init(5, "Topic_AI"));
    try db.insertNode(types.Node.init(6, "Topic_DB"));

    // Create relationships
    try db.insertEdge(types.Edge.init(1, 3, types.EdgeKind.owns));      // Alice owns Document1
    try db.insertEdge(types.Edge.init(2, 4, types.EdgeKind.owns));      // Bob owns Document2
    try db.insertEdge(types.Edge.init(3, 5, types.EdgeKind.related));   // Document1 related to AI
    try db.insertEdge(types.Edge.init(4, 6, types.EdgeKind.related));   // Document2 related to DB
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.similar_to)); // Alice similar to Bob
    try db.insertEdge(types.Edge.init(5, 6, types.EdgeKind.links));     // AI links to DB

    // Create sample vectors with different patterns
    const alice_embedding = generateRandomVector(1.0, 0.2, 0.1);
    const bob_embedding = generateRandomVector(0.8, 0.5, 0.1);
    const doc1_embedding = generateRandomVector(0.9, 0.3, 0.2);
    const doc2_embedding = generateRandomVector(0.7, 0.4, 0.2);
    const ai_embedding = generateRandomVector(0.1, 0.9, 0.3);
    const db_embedding = generateRandomVector(0.2, 0.8, 0.4);

    try db.insertVector(types.Vector.init(1, &alice_embedding));
    try db.insertVector(types.Vector.init(2, &bob_embedding));
    try db.insertVector(types.Vector.init(3, &doc1_embedding));
    try db.insertVector(types.Vector.init(4, &doc2_embedding));
    try db.insertVector(types.Vector.init(5, &ai_embedding));
    try db.insertVector(types.Vector.init(6, &db_embedding));

    std.debug.print("Sample data:\n");
    std.debug.print("  Nodes: Alice(1), Bob(2), Document1(3), Document2(4), Topic_AI(5), Topic_DB(6)\n");
    std.debug.print("  Edges: ownership, relationships, similarities\n");
    std.debug.print("  Vectors: 128-dimensional embeddings for each entity\n");
}

fn generateRandomVector(base1: f32, base2: f32, base3: f32) [128]f32 {
    var vector = [_]f32{0.0} ** 128;
    
    // Set some significant dimensions with pattern
    vector[0] = base1;
    vector[1] = base2;
    vector[2] = base3;
    
    // Add some randomness to other dimensions
    var prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();
    
    for (3..10) |i| {
        vector[i] = random.float(f32) * 0.1;
    }
    
    return vector;
} 