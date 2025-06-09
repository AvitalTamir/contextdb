const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");

const ContextDB = contextdb.ContextDB;
const ContextDBConfig = contextdb.ContextDBConfig;
const types = contextdb.types;
const http_api = contextdb.http_api;

test "HTTP API basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_http_api_data") catch {};
    defer std.fs.cwd().deleteTree("test_http_api_data") catch {};

    // Initialize database
    const config = ContextDBConfig{
        .data_path = "test_http_api_data",
        .enable_persistent_indexes = true,
    };

    var db = try ContextDB.init(allocator, config, null);
    defer db.deinit();

    // Test ApiServer initialization
    var api_server = http_api.ApiServer.init(allocator, &db, null, 8080, null);
    defer api_server.stop();

    // Insert test data directly to database for testing queries
    try db.insertNode(types.Node.init(1, "TestNode"));
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.related));
    
    const test_dims = [_]f32{1.0, 0.5, 0.0} ++ [_]f32{0.0} ** 125;
    try db.insertVector(types.Vector.init(1, &test_dims));

    // Test basic HTTP request parsing
    const test_request_data = "GET /api/v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var request = try api_server.parseHttpRequest(test_request_data);
    defer request.deinit();

    try testing.expect(request.method == .GET);
    try testing.expect(std.mem.eql(u8, request.path, "/api/v1/health"));

    std.debug.print("✓ HTTP API basic functionality test passed\n", .{});
}

test "HTTP API JSON serialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test NodeRequest JSON parsing
    const node_json = "{\"id\": 123, \"label\": \"TestNode\"}";
    var json_parser = try std.json.parseFromSlice(http_api.NodeRequest, allocator, node_json, .{});
    defer json_parser.deinit();

    const node_req = json_parser.value;
    try testing.expect(node_req.id == 123);
    try testing.expect(std.mem.eql(u8, node_req.label, "TestNode"));

    // Test EdgeRequest JSON parsing
    const edge_json = "{\"from\": 1, \"to\": 2, \"kind\": \"owns\"}";
    var edge_parser = try std.json.parseFromSlice(http_api.EdgeRequest, allocator, edge_json, .{});
    defer edge_parser.deinit();

    const edge_req = edge_parser.value;
    try testing.expect(edge_req.from == 1);
    try testing.expect(edge_req.to == 2);
    try testing.expect(std.mem.eql(u8, edge_req.kind, "owns"));

    // Test VectorRequest JSON parsing
    const vector_json = "{\"id\": 42, \"dims\": [1.0, 0.5, -0.2]}";
    var vector_parser = try std.json.parseFromSlice(http_api.VectorRequest, allocator, vector_json, .{});
    defer vector_parser.deinit();

    const vector_req = vector_parser.value;
    try testing.expect(vector_req.id == 42);
    try testing.expect(vector_req.dims.len == 3);
    try testing.expect(vector_req.dims[0] == 1.0);
    try testing.expect(vector_req.dims[1] == 0.5);
    try testing.expect(vector_req.dims[2] == -0.2);

    std.debug.print("✓ HTTP API JSON serialization test passed\n", .{});
}

test "HTTP API batch operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test BatchRequest JSON parsing
    const batch_json = 
        \\{
        \\  "nodes": [
        \\    {"id": 1, "label": "Node1"},
        \\    {"id": 2, "label": "Node2"}
        \\  ],
        \\  "edges": [
        \\    {"from": 1, "to": 2, "kind": "related"}
        \\  ],
        \\  "vectors": [
        \\    {"id": 1, "dims": [1.0, 0.0, 0.0]}
        \\  ]
        \\}
    ;

    var batch_parser = try std.json.parseFromSlice(http_api.BatchRequest, allocator, batch_json, .{});
    defer batch_parser.deinit();

    const batch_req = batch_parser.value;
    try testing.expect(batch_req.nodes.len == 2);
    try testing.expect(batch_req.edges.len == 1);
    try testing.expect(batch_req.vectors.len == 1);

    try testing.expect(batch_req.nodes[0].id == 1);
    try testing.expect(std.mem.eql(u8, batch_req.nodes[0].label, "Node1"));

    try testing.expect(batch_req.edges[0].from == 1);
    try testing.expect(batch_req.edges[0].to == 2);
    try testing.expect(std.mem.eql(u8, batch_req.edges[0].kind, "related"));

    try testing.expect(batch_req.vectors[0].id == 1);
    try testing.expect(batch_req.vectors[0].dims[0] == 1.0);

    std.debug.print("✓ HTTP API batch operations test passed\n", .{});
}

test "HTTP response construction" {
    // Test basic response construction
    const json_response = http_api.HttpResponse.json(.ok, "{\"test\": true}");
    try testing.expect(json_response.status == .ok);
    try testing.expect(std.mem.eql(u8, json_response.body, "{\"test\": true}"));
    try testing.expect(std.mem.eql(u8, json_response.content_type, "application/json"));

    const text_response = http_api.HttpResponse.text(.not_found, "Not Found");
    try testing.expect(text_response.status == .not_found);
    try testing.expect(std.mem.eql(u8, text_response.body, "Not Found"));
    try testing.expect(std.mem.eql(u8, text_response.content_type, "text/plain"));

    std.debug.print("✓ HTTP response construction test passed\n", .{});
}

test "HTTP method parsing" {
    try testing.expect(http_api.HttpMethod.fromString("GET") == .GET);
    try testing.expect(http_api.HttpMethod.fromString("POST") == .POST);
    try testing.expect(http_api.HttpMethod.fromString("PUT") == .PUT);
    try testing.expect(http_api.HttpMethod.fromString("DELETE") == .DELETE);
    try testing.expect(http_api.HttpMethod.fromString("OPTIONS") == .OPTIONS);
    try testing.expect(http_api.HttpMethod.fromString("INVALID") == .UNKNOWN);

    std.debug.print("✓ HTTP method parsing test passed\n", .{});
}

test "HTTP API configuration integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_http_config_data") catch {};
    defer std.fs.cwd().deleteTree("test_http_config_data") catch {};

    // Initialize database
    const db_config = ContextDBConfig{
        .data_path = "test_http_config_data",
        .enable_persistent_indexes = true,
    };

    var db = try ContextDB.init(allocator, db_config, null);
    defer db.deinit();

    // Create custom HTTP configuration
    const http_config_data = contextdb.config_mod.Config{
        .http_port = 9090,
        .http_request_buffer_size = 2048,
        .http_response_buffer_size = 4096,
        .health_memory_warning_gb = 0.5,
        .health_memory_critical_gb = 1.5,
        .health_error_rate_warning = 2.0,
        .health_error_rate_critical = 8.0,
    };

    // Test ApiServer with custom configuration
    var api_server = http_api.ApiServer.init(allocator, &db, null, null, http_config_data);
    defer api_server.stop();

    // Verify configuration values are applied correctly
    try testing.expect(api_server.port == 9090); // Port from config
    try testing.expect(api_server.http_config.request_buffer_size == 2048);
    try testing.expect(api_server.http_config.response_buffer_size == 4096);
    try testing.expect(api_server.http_config.memory_warning_bytes == 500_000_000); // 0.5GB
    try testing.expect(api_server.http_config.memory_critical_bytes == 1_500_000_000); // 1.5GB
    try testing.expect(api_server.http_config.error_rate_warning == 2.0);
    try testing.expect(api_server.http_config.error_rate_critical == 8.0);

    // Test that port override works
    var api_server_override = http_api.ApiServer.init(allocator, &db, null, 3000, http_config_data);
    defer api_server_override.stop();

    try testing.expect(api_server_override.port == 3000); // Port override takes precedence
    try testing.expect(api_server_override.http_config.request_buffer_size == 2048); // Config values still used

    std.debug.print("✓ HTTP API configuration integration test passed\n", .{});
} 