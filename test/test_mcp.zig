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
    var server = mcp_server.McpServer.init(allocator, &db, 0);
    defer server.deinit();

    // Check server info
    try testing.expectEqualStrings("memora", server.server_info.name);
    try testing.expectEqualStrings("2.0.0", server.server_info.version);

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
    defer server.deinit();

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
    try testing.expectEqualStrings("2.0.0", server_info.get("version").?.string);
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
    defer server.deinit();

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
    defer server.deinit();

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
    defer server.deinit();

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
    defer server.deinit();

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
    defer server.deinit();

    // Create tools/call request for store_memory using new semantic schema
    const request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 6,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "store_memory",
        \\    "arguments": {
        \\      "content": "TestMemory content for LLM memory system",
        \\      "memory_type": "experience",
        \\      "confidence": "high",
        \\      "importance": "medium",
        \\      "source": "user_input"
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
    defer server.deinit();

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
    defer server.deinit();

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

test "MCP MemoryManager integration - store, update, delete cycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Clean up test data
    std.fs.cwd().deleteTree("test_mcp_memory_integration") catch {};
    defer std.fs.cwd().deleteTree("test_mcp_memory_integration") catch {};

    // Create test database
    const config = MemoraConfig{
        .data_path = "test_mcp_memory_integration",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = true,
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize MCP server
    var server = mcp_server.McpServer.init(allocator, &db, 0);
    defer server.deinit();

    // Step 1: Store a memory
    const store_request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "store_memory",
        \\    "arguments": {
        \\      "content": "Original memory content with important information",
        \\      "memory_type": "experience",
        \\      "confidence": "high",
        \\      "importance": "medium",
        \\      "source": "user_input"
        \\    }
        \\  }
        \\}
    ;

    const store_response = try server.handleRequest(store_request);
    defer allocator.free(store_response);
    
    // Verify store was successful
    var store_parsed = try std.json.parseFromSlice(std.json.Value, allocator, store_response, .{});
    defer store_parsed.deinit();
    const store_obj = store_parsed.value.object;
    try testing.expect(store_obj.get("error") == null);
    
    // Step 2: Recall the memory to verify it was stored with full content
    const recall_request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 2,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "recall_memories",
        \\    "arguments": {
        \\      "memory_id": 1
        \\    }
        \\  }
        \\}
    ;

    const recall_response = try server.handleRequest(recall_request);
    defer allocator.free(recall_response);
    
    var recall_parsed = try std.json.parseFromSlice(std.json.Value, allocator, recall_response, .{});
    defer recall_parsed.deinit();
    const recall_obj = recall_parsed.value.object;
    try testing.expect(recall_obj.get("error") == null);
    
    // Verify the full content is returned (not truncated to 32 bytes)
    const recall_result = recall_obj.get("result").?.object;
    const recall_content = recall_result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, recall_content, "Original memory content with important information") != null);

    // Step 3: Update the memory content
    const update_request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 3,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "update_memory",
        \\    "arguments": {
        \\      "id": 1,
        \\      "new_label": "Updated memory content with completely different information and concepts"
        \\    }
        \\  }
        \\}
    ;

    const update_response = try server.handleRequest(update_request);
    defer allocator.free(update_response);
    
    var update_parsed = try std.json.parseFromSlice(std.json.Value, allocator, update_response, .{});
    defer update_parsed.deinit();
    const update_obj = update_parsed.value.object;
    try testing.expect(update_obj.get("error") == null);
    
    // Verify update success message includes both old and new content
    const update_result = update_obj.get("result").?.object;
    const update_content = update_result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, update_content, "Old content:") != null);
    try testing.expect(std.mem.indexOf(u8, update_content, "New content:") != null);
    try testing.expect(std.mem.indexOf(u8, update_content, "Updated memory content with completely different") != null);

    // Step 4: Recall the memory again to verify the update persisted
    const recall2_response = try server.handleRequest(recall_request);
    defer allocator.free(recall2_response);
    
    var recall2_parsed = try std.json.parseFromSlice(std.json.Value, allocator, recall2_response, .{});
    defer recall2_parsed.deinit();
    const recall2_obj = recall2_parsed.value.object;
    try testing.expect(recall2_obj.get("error") == null);
    
    // Verify the updated content is now returned
    const recall2_result = recall2_obj.get("result").?.object;
    const recall2_content = recall2_result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, recall2_content, "Updated memory content with completely different") != null);
    try testing.expect(std.mem.indexOf(u8, recall2_content, "Original memory content") == null);

    // Step 5: Test semantic search to verify embedding was updated
    const search_request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 4,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "recall_similar",
        \\    "arguments": {
        \\      "query": "different information concepts",
        \\      "limit": 3
        \\    }
        \\  }
        \\}
    ;

    const search_response = try server.handleRequest(search_request);
    defer allocator.free(search_response);
    
    var search_parsed = try std.json.parseFromSlice(std.json.Value, allocator, search_response, .{});
    defer search_parsed.deinit();
    const search_obj = search_parsed.value.object;
    try testing.expect(search_obj.get("error") == null);

    // Step 6: Delete the memory  
    const delete_request = 
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 5,
        \\  "method": "tools/call",
        \\  "params": {
        \\    "name": "forget_memory",
        \\    "arguments": {
        \\      "id": 1
        \\    }
        \\  }
        \\}
    ;

    const delete_response = try server.handleRequest(delete_request);
    defer allocator.free(delete_response);
    
    var delete_parsed = try std.json.parseFromSlice(std.json.Value, allocator, delete_response, .{});
    defer delete_parsed.deinit();
    const delete_obj = delete_parsed.value.object;
    try testing.expect(delete_obj.get("error") == null);
    
    // Verify deletion success message includes the deleted content
    const delete_result = delete_obj.get("result").?.object;
    const delete_content = delete_result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, delete_content, "forgotten successfully") != null);
    try testing.expect(std.mem.indexOf(u8, delete_content, "Updated memory content with completely different") != null);
    try testing.expect(std.mem.indexOf(u8, delete_content, "Cleaned up memory content cache") != null);

    // Step 7: Try to recall the deleted memory (should fail)
    const recall3_response = try server.handleRequest(recall_request);
    defer allocator.free(recall3_response);
    
    var recall3_parsed = try std.json.parseFromSlice(std.json.Value, allocator, recall3_response, .{});
    defer recall3_parsed.deinit();
    const recall3_obj = recall3_parsed.value.object;
    
    // The memory should either error out or return empty/not found
    // Let's just verify the response is different from when the memory existed
    if (recall3_obj.get("error")) |_| {
        // Error response is fine - memory was deleted
        std.debug.print("Memory deletion verified: got error response as expected\n", .{});
    } else if (recall3_obj.get("result")) |result| {
        // Check if result indicates memory not found
        const recall3_result = result.object;
        const recall3_content = recall3_result.get("content").?.array.items[0].object.get("text").?.string;
        // Should not contain the updated content anymore
        try testing.expect(std.mem.indexOf(u8, recall3_content, "Updated memory content with completely different") == null);
        std.debug.print("Memory deletion verified: memory content no longer accessible\n", .{});
    } else {
        try testing.expect(false); // Should have either error or result
    }
} 