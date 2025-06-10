const std = @import("std");
const testing = std.testing;
const memora = @import("memora");

const Memora = memora.Memora;
const MemoraConfig = memora.MemoraConfig;
const mcp_server = memora.mcp_server;
const types = memora.types;

test "MCP server initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    const server = mcp_server.McpServer.init(allocator, &db, 0);

    // Check server info
    try testing.expectEqualStrings("memora", server.server_info.name);
    try testing.expectEqualStrings("1.0.0", server.server_info.version);

    // Check capabilities
    try testing.expect(server.capabilities.resources != null);
    try testing.expect(server.capabilities.tools != null);
    try testing.expect(server.capabilities.prompts != null);
}

test "MCP JSON-RPC initialize request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Send initialize request
    const request = 
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}
    ;
    
    const response = try server.handleRequest(request);
    defer allocator.free(response);
    
    // Parse response
    var parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed_response.deinit();
    const response_obj = parsed_response.value.object;
    
    // Check for successful response
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 1);
    try testing.expect(response_obj.get("result") != null);
    const error_field = response_obj.get("error");
    try testing.expect(error_field == null or error_field.? == .null);

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 1);
    try testing.expect(response_obj.get("result") != null);

    // Check result contents
    const result = response_obj.get("result").?.object;
    try testing.expectEqualStrings("2024-11-05", result.get("protocolVersion").?.string);
    
    const server_info = result.get("serverInfo").?.object;
    try testing.expectEqualStrings("memora", server_info.get("name").?.string);
    try testing.expectEqualStrings("1.0.0", server_info.get("version").?.string);
}

test "MCP ping request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data  
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create ping request
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "ping"
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 2);
    try testing.expect(response_obj.get("result") != null);
    const error_field_ping = response_obj.get("error");
    try testing.expect(error_field_ping == null or error_field_ping.? == .null);
}

test "MCP resources/list request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create resources/list request  
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "resources/list"
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 3);
    try testing.expect(response_obj.get("result") != null);
    const error_field_resources = response_obj.get("error");
    try testing.expect(error_field_resources == null or error_field_resources.? == .null);

    // Check that we have resources
    const result = response_obj.get("result").?.object;
    const resources = result.get("resources").?.array;
    try testing.expect(resources.items.len >= 4); // Should have stats, nodes, edges, vectors
}

test "MCP resources/read stats request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Add some test data
    try db.insertNode(types.Node.init(1, "TestNode"));

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create resources/read request
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 4,
        \\  "method": "resources/read",
        \\  "params": {
        \\    "uri": "memora://stats"
        \\  }
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 4);
    try testing.expect(response_obj.get("result") != null);
    const error_field_stats = response_obj.get("error");
    try testing.expect(error_field_stats == null or error_field_stats.? == .null);

    // Check contents
    const result = response_obj.get("result").?.object;
    const contents = result.get("contents").?.array;
    try testing.expect(contents.items.len == 1);
    
    const content = contents.items[0].object;
    try testing.expectEqualStrings("memora://stats", content.get("uri").?.string);
    try testing.expectEqualStrings("application/json", content.get("mimeType").?.string);
    
    // Parse the stats JSON
    const stats_text = content.get("text").?.string;
    var stats_parsed = try std.json.parseFromSlice(std.json.Value, allocator, stats_text, .{});
    defer stats_parsed.deinit();
    
    const stats = stats_parsed.value.object;
    try testing.expect(stats.get("node_count").?.integer >= 1);
}

test "MCP tools/list request" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create tools/list request
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 5,
        \\  "method": "tools/list"
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 5);
    try testing.expect(response_obj.get("result") != null);
    const error_field_tools = response_obj.get("error");
    try testing.expect(error_field_tools == null or error_field_tools.? == .null);

    // Check that we have memory tools
    const result = response_obj.get("result").?.object;
    const tools = result.get("tools").?.array;
    try testing.expect(tools.items.len >= 3); // Should have store_memory, recall_similar, explore_relationships
}

test "MCP store_memory tool call" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create tools/call request for store_memory
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 6,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "store_memory",
        \\    "arguments": {
        \\      "id": 42,
        \\      "label": "TestMemory"
        \\    }
        \\  }
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate response structure
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 6);
    try testing.expect(response_obj.get("result") != null);
    const error_field_store = response_obj.get("error");
    try testing.expect(error_field_store == null or error_field_store.? == .null);

    // Verify memory was stored in the database
    const stats = db.getStats();
    try testing.expect(stats.node_count >= 1);
}

test "MCP error handling - invalid JSON" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create invalid JSON request
    const request = "{ invalid json }";

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate error response
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    const result_field = response_obj.get("result");
    try testing.expect(result_field == null or result_field.? == .null);
    try testing.expect(response_obj.get("error") != null);
    
    const error_obj = response_obj.get("error").?.object;
    try testing.expect(error_obj.get("code").?.integer == mcp_server.JsonRpcError.PARSE_ERROR);
}

test "MCP error handling - method not found" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_data") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_data") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_data",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);

    // Create request with unknown method
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 7,
        \\  "method": "unknown_method"
        \\}
    ;

    // Handle the request
    const response = try server.handleRequest(request);
    defer allocator.free(response);

    // Parse response
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    const response_obj = parsed.value.object;

    // Validate error response
    try testing.expectEqualStrings("2.0", response_obj.get("jsonrpc").?.string);
    try testing.expect(response_obj.get("id").?.integer == 7);
    const result_field_method = response_obj.get("result");
    try testing.expect(result_field_method == null or result_field_method.? == .null);
    try testing.expect(response_obj.get("error") != null);
    
    const error_obj = response_obj.get("error").?.object;
    try testing.expect(error_obj.get("code").?.integer == mcp_server.JsonRpcError.METHOD_NOT_FOUND);
} 