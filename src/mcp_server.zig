const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");

const ContextDB = main.ContextDB;

/// JSON-RPC 2.0 error codes
pub const JsonRpcError = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
};

/// MCP Protocol errors
pub const McpError = struct {
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
};

/// JSON-RPC 2.0 Request
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,
};

/// JSON-RPC 2.0 Response  
pub const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value,
    result: ?std.json.Value,
    @"error": ?JsonRpcErrorObject,
};

/// JSON-RPC 2.0 Error Object
pub const JsonRpcErrorObject = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value,
};

/// MCP Implementation Info
pub const McpImplementation = struct {
    name: []const u8,
    version: []const u8,
};

/// MCP Server Capabilities
pub const McpCapabilities = struct {
    resources: ?McpResourcesCapability,
    tools: ?McpToolsCapability,
    prompts: ?McpPromptsCapability,
    logging: ?McpLoggingCapability,
};

pub const McpResourcesCapability = struct {
    subscribe: ?bool,
    listChanged: ?bool,
};

pub const McpToolsCapability = struct {
    listChanged: ?bool,
};

pub const McpPromptsCapability = struct {
    listChanged: ?bool,
};

pub const McpLoggingCapability = struct {};

/// MCP Initialize Request
pub const McpInitializeRequest = struct {
    protocolVersion: []const u8,
    capabilities: McpCapabilities,
    clientInfo: McpImplementation,
};

/// MCP Initialize Response
pub const McpInitializeResponse = struct {
    protocolVersion: []const u8,
    capabilities: McpCapabilities,
    serverInfo: McpImplementation,
};

/// MCP Resource
pub const McpResource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8,
    mimeType: ?[]const u8,
};

/// MCP Tool
pub const McpTool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

/// MCP Prompt
pub const McpPrompt = struct {
    name: []const u8,
    description: []const u8,
    arguments: ?[]McpPromptArgument,
};

pub const McpPromptArgument = struct {
    name: []const u8,
    description: []const u8,
    required: ?bool,
};

/// MCP Server implementation
pub const McpServer = struct {
    allocator: std.mem.Allocator,
    db: *ContextDB,
    port: u16,
    server_info: McpImplementation,
    capabilities: McpCapabilities,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, db: *ContextDB, port: u16) Self {
        return Self{
            .allocator = allocator,
            .db = db,
            .port = port,
            .server_info = McpImplementation{
                .name = "memora",
                .version = "1.0.0",
            },
            .capabilities = McpCapabilities{
                .resources = McpResourcesCapability{
                    .subscribe = true,
                    .listChanged = true,
                },
                .tools = McpToolsCapability{
                    .listChanged = false,
                },
                .prompts = McpPromptsCapability{
                    .listChanged = false,
                },
                .logging = McpLoggingCapability{},
            },
        };
    }
    
    /// Start the MCP server using stdio transport
    pub fn start(self: *Self) !void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        
        std.debug.print("Memora MCP Server starting on stdio transport\n", .{});
        
        var buf: [4096]u8 = undefined;
        
        while (true) {
            // Read JSON-RPC message from stdin
            if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
                if (line.len == 0) continue;
                
                // Process the request and send response
                const response = self.handleRequest(line) catch |err| {
                    std.debug.print("Error handling request: {}\n", .{err});
                    continue;
                };
                defer self.allocator.free(response);
                
                // Send response to stdout
                try stdout.print("{s}\n", .{response});
            } else {
                break; // EOF
            }
        }
    }
    
    /// Handle a JSON-RPC request
    pub fn handleRequest(self: *Self, request_json: []const u8) ![]u8 {
        // Parse JSON-RPC request
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request_json, .{}) catch {
            return self.createErrorResponse(null, JsonRpcError.PARSE_ERROR, "Parse error", null);
        };
        defer parsed.deinit();
        
        const request_obj = parsed.value.object;
        
        // Validate JSON-RPC 2.0 format
        const jsonrpc = request_obj.get("jsonrpc") orelse {
            return self.createErrorResponse(null, JsonRpcError.INVALID_REQUEST, "Missing jsonrpc field", null);
        };
        
        if (!std.mem.eql(u8, jsonrpc.string, "2.0")) {
            return self.createErrorResponse(null, JsonRpcError.INVALID_REQUEST, "Invalid jsonrpc version", null);
        }
        
        const id = request_obj.get("id");
        const method = request_obj.get("method") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_REQUEST, "Missing method field", null);
        };
        const params = request_obj.get("params");
        
        // Route to appropriate handler
        const method_str = method.string;
        
        if (std.mem.eql(u8, method_str, "initialize")) {
            return self.handleInitialize(id, params);
        } else if (std.mem.eql(u8, method_str, "ping")) {
            return self.handlePing(id);
        } else if (std.mem.eql(u8, method_str, "resources/list")) {
            return self.handleResourcesList(id);
        } else if (std.mem.eql(u8, method_str, "resources/read")) {
            return self.handleResourcesRead(id, params);
        } else if (std.mem.eql(u8, method_str, "tools/list")) {
            return self.handleToolsList(id);
        } else if (std.mem.eql(u8, method_str, "tools/call")) {
            return self.handleToolsCall(id, params);
        } else if (std.mem.eql(u8, method_str, "prompts/list")) {
            return self.handlePromptsList(id);
        } else if (std.mem.eql(u8, method_str, "prompts/get")) {
            return self.handlePromptsGet(id, params);
        } else {
            return self.createErrorResponse(id, JsonRpcError.METHOD_NOT_FOUND, "Method not found", null);
        }
    }
    
    /// Handle initialize request
    fn handleInitialize(self: *Self, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        _ = params; // TODO: Parse and validate client capabilities
        
        const result = McpInitializeResponse{
            .protocolVersion = "2024-11-05",
            .capabilities = self.capabilities,
            .serverInfo = self.server_info,
        };
        
        return self.createSuccessResponse(id, result);
    }
    
    /// Handle ping request
    fn handlePing(self: *Self, id: ?std.json.Value) ![]u8 {
        return self.createSuccessResponse(id, .{});
    }
    
    /// Handle resources/list request
    fn handleResourcesList(self: *Self, id: ?std.json.Value) ![]u8 {
        const resources = [_]McpResource{
            McpResource{
                .uri = "memora://stats",
                .name = "Database Statistics",
                .description = "Current memory database statistics",
                .mimeType = "application/json",
            },
            McpResource{
                .uri = "memora://nodes",
                .name = "Memory Nodes",
                .description = "All concept nodes in memory",
                .mimeType = "application/json",
            },
            McpResource{
                .uri = "memora://edges", 
                .name = "Memory Relationships",
                .description = "All relationships between concepts",
                .mimeType = "application/json",
            },
            McpResource{
                .uri = "memora://vectors",
                .name = "Semantic Vectors",
                .description = "All semantic embeddings in memory",
                .mimeType = "application/json",
            },
        };
        
        return self.createSuccessResponse(id, .{ .resources = resources });
    }
    
    /// Handle resources/read request
    fn handleResourcesRead(self: *Self, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const params_obj = params orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing params", null);
        };
        
        const uri = params_obj.object.get("uri") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing uri parameter", null);
        };
        
        const uri_str = uri.string;
        
        if (std.mem.eql(u8, uri_str, "memora://stats")) {
            const stats = self.db.getStats();
            const stats_json = try std.fmt.allocPrint(self.allocator, 
                "{{\"node_count\":{},\"edge_count\":{},\"vector_count\":{}}}", 
                .{ stats.node_count, stats.edge_count, stats.vector_count });
            defer self.allocator.free(stats_json);
            
            return self.createSuccessResponse(id, .{
                .contents = [_]struct { 
                    uri: []const u8, 
                    mimeType: []const u8, 
                    text: []const u8 
                }{
                    .{
                        .uri = uri_str,
                        .mimeType = "application/json",
                        .text = stats_json,
                    },
                },
            });
        } else {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Unknown resource URI", null);
        }
    }
    
    /// Handle tools/list request
    fn handleToolsList(self: *Self, id: ?std.json.Value) ![]u8 {
        const tools = [_]McpTool{
            McpTool{
                .name = "store_memory",
                .description = "Store a new memory/experience in the database",
                .inputSchema = std.json.Value{
                    .object = std.json.ObjectMap.init(self.allocator),
                },
            },
            McpTool{
                .name = "recall_similar",
                .description = "Retrieve memories similar to a given query",
                .inputSchema = std.json.Value{
                    .object = std.json.ObjectMap.init(self.allocator),
                },
            },
            McpTool{
                .name = "explore_relationships",
                .description = "Explore concept relationships in memory",
                .inputSchema = std.json.Value{
                    .object = std.json.ObjectMap.init(self.allocator),
                },
            },
        };
        
        return self.createSuccessResponse(id, .{ .tools = tools });
    }
    
    /// Handle tools/call request
    fn handleToolsCall(self: *Self, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        const params_obj = params orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing params", null);
        };
        
        const name = params_obj.object.get("name") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing tool name", null);
        };
        
        const arguments = params_obj.object.get("arguments");
        
        const tool_name = name.string;
        
        if (std.mem.eql(u8, tool_name, "store_memory")) {
            return self.handleStoreMemory(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "recall_similar")) {
            return self.handleRecallSimilar(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "explore_relationships")) {
            return self.handleExploreRelationships(id, arguments);
        } else {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Unknown tool", null);
        }
    }
    
    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, id: ?std.json.Value) ![]u8 {
        var memory_context_args = std.ArrayList(McpPromptArgument).init(self.allocator);
        defer memory_context_args.deinit();
        
        try memory_context_args.append(McpPromptArgument{
            .name = "query",
            .description = "The query to find relevant memories for",
            .required = true,
        });
        try memory_context_args.append(McpPromptArgument{
            .name = "limit",
            .description = "Maximum number of memories to retrieve",
            .required = false,
        });
        
        const prompts = [_]McpPrompt{
            McpPrompt{
                .name = "memory_context",
                .description = "Generate context from stored memories for a query",
                .arguments = memory_context_args.items,
            },
        };
        
        return self.createSuccessResponse(id, .{ .prompts = prompts });
    }
    
    /// Handle prompts/get request  
    fn handlePromptsGet(self: *Self, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
        _ = params; // TODO: Implement prompt template generation
        return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Prompts not yet implemented", null);
    }
    
    /// Handle store_memory tool
    fn handleStoreMemory(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        // Extract memory data from arguments
        const args_obj = args.object;
        const node_id = args_obj.get("id") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing id", null);
        };
        const label = args_obj.get("label") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing label", null);
        };
        
        // Store the memory as a node
        const memory_node = types.Node.init(@intCast(node_id.integer), label.string);
        self.db.insertNode(memory_node) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to store memory: {}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        const result_msg = try std.fmt.allocPrint(self.allocator, "Memory stored successfully with ID {}", .{node_id.integer});
        defer self.allocator.free(result_msg);
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = result_msg,
                },
            },
        });
    }
    
    /// Handle recall_similar tool
    fn handleRecallSimilar(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        _ = arguments; // TODO: Implement similarity search
        return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Similarity search not yet implemented", null);
    }
    
    /// Handle explore_relationships tool
    fn handleExploreRelationships(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        _ = arguments; // TODO: Implement relationship exploration
        return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Relationship exploration not yet implemented", null);
    }
    
    /// Create a success response
    fn createSuccessResponse(self: *Self, id: ?std.json.Value, result: anytype) ![]u8 {
        // Convert result to JSON Value
        var json_string = std.ArrayList(u8).init(self.allocator);
        defer json_string.deinit();
        
        try std.json.stringify(result, .{}, json_string.writer());
        
        var result_value = try std.json.parseFromSlice(std.json.Value, self.allocator, json_string.items, .{});
        defer result_value.deinit();
        
        const response = JsonRpcResponse{
            .jsonrpc = "2.0",
            .id = id,
            .result = result_value.value,
            .@"error" = null,
        };
        
        var response_json = std.ArrayList(u8).init(self.allocator);
        defer response_json.deinit();
        
        try std.json.stringify(response, .{}, response_json.writer());
        
        return self.allocator.dupe(u8, response_json.items);
    }
    
    /// Create an error response
    fn createErrorResponse(self: *Self, id: ?std.json.Value, code: i32, message: []const u8, data: ?std.json.Value) ![]u8 {
        const error_obj = JsonRpcErrorObject{
            .code = code,
            .message = message,
            .data = data,
        };
        
        const response = JsonRpcResponse{
            .jsonrpc = "2.0",
            .id = id,
            .result = null,
            .@"error" = error_obj,
        };
        
        var response_json = std.ArrayList(u8).init(self.allocator);
        defer response_json.deinit();
        
        try std.json.stringify(response, .{}, response_json.writer());
        
        return self.allocator.dupe(u8, response_json.items);
    }
}; 