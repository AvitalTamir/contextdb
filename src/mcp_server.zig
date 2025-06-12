const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");
const memory_types = @import("memory_types.zig");
const memory_manager = @import("memory_manager.zig");

const Memora = main.Memora;
const MemoryManager = memory_manager.MemoryManager;
const Memory = memory_types.Memory;
const MemoryType = memory_types.MemoryType;
const MemoryConfidence = memory_types.MemoryConfidence;
const MemoryImportance = memory_types.MemoryImportance;
const MemorySource = memory_types.MemorySource;
const MemoryQuery = memory_types.MemoryQuery;
const MemoryRelationType = memory_types.MemoryRelationType;

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

/// JSON-RPC 2.0 Success Response
pub const JsonRpcSuccessResponse = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value,
    result: std.json.Value,
};

/// JSON-RPC 2.0 Error Response  
pub const JsonRpcErrorResponse = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value,
    @"error": JsonRpcErrorObject,
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
    db: *Memora,
    memory_manager: MemoryManager,
    port: u16,
    server_info: McpImplementation,
    capabilities: McpCapabilities,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, db: *Memora, port: u16) Self {
        return Self{
            .allocator = allocator,
            .db = db,
            .memory_manager = MemoryManager.init(allocator, db),
            .port = port,
            .server_info = McpImplementation{
                .name = "memora",
                .version = "2.0.0", // Updated for LLM Memory Data Models
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
    
    pub fn deinit(self: *Self) void {
        self.memory_manager.deinit();
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
                    std.debug.print("Error handling request: {any}\n", .{err});
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
        // Create JSON schema strings for tool inputs
        const store_memory_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "memory_type": {
            \\      "type": "string",
            \\      "enum": ["experience", "concept", "fact", "decision", "observation", "preference", "context", "skill", "intention", "emotion"],
            \\      "description": "Type of memory being stored",
            \\      "default": "experience"
            \\    },
            \\    "content": {
            \\      "type": "string",
            \\      "description": "The memory content to store"
            \\    },
            \\    "confidence": {
            \\      "type": "string",
            \\      "enum": ["very_low", "low", "medium", "high", "very_high"],
            \\      "description": "Confidence level in this memory",
            \\      "default": "medium"
            \\    },
            \\    "importance": {
            \\      "type": "string",
            \\      "enum": ["trivial", "low", "medium", "high", "critical"],
            \\      "description": "Importance level of this memory",
            \\      "default": "medium"
            \\    },
            \\    "source": {
            \\      "type": "string",
            \\      "enum": ["user_input", "llm_inference", "system_observation", "external_api", "computed"],
            \\      "description": "Source of this memory",
            \\      "default": "user_input"
            \\    },
            \\    "session_id": {
            \\      "type": "integer",
            \\      "description": "Session ID to associate with this memory (optional)"
            \\    },
            \\    "user_id": {
            \\      "type": "integer",
            \\      "description": "User ID to associate with this memory (optional)"
            \\    }
            \\  },
            \\  "required": ["content"]
            \\}
        ;
        
        const recall_similar_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "query": {
            \\      "type": "string",
            \\      "description": "Query to find similar memories"
            \\    },
            \\    "memory_types": {
            \\      "type": "array",
            \\      "items": {
            \\        "type": "string",
            \\        "enum": ["experience", "concept", "fact", "decision", "observation", "preference", "context", "skill", "intention", "emotion"]
            \\      },
            \\      "description": "Filter by specific memory types (optional)"
            \\    },
            \\    "min_confidence": {
            \\      "type": "string",
            \\      "enum": ["very_low", "low", "medium", "high", "very_high"],
            \\      "description": "Minimum confidence level (optional)"
            \\    },
            \\    "min_importance": {
            \\      "type": "string",
            \\      "enum": ["trivial", "low", "medium", "high", "critical"],
            \\      "description": "Minimum importance level (optional)"
            \\    },
            \\    "session_id": {
            \\      "type": "integer",
            \\      "description": "Filter by session ID (optional)"
            \\    },
            \\    "user_id": {
            \\      "type": "integer",
            \\      "description": "Filter by user ID (optional)"
            \\    },
            \\    "limit": {
            \\      "type": "integer",
            \\      "description": "Maximum number of results to return",
            \\      "default": 5
            \\    }
            \\  },
            \\  "required": ["query"]
            \\}
        ;
        
        const explore_relationships_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "node_id": {
            \\      "type": "integer",
            \\      "description": "Starting node ID for relationship exploration"
            \\    },
            \\    "depth": {
            \\      "type": "integer",
            \\      "description": "Maximum depth for relationship traversal",
            \\      "default": 2
            \\    }
            \\  },
            \\  "required": ["node_id"]
            \\}
        ;
        
        const recall_memories_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "memory_id": {
            \\      "type": "integer",
            \\      "description": "Specific memory ID to retrieve (optional)"
            \\    },
            \\    "text_query": {
            \\      "type": "string",
            \\      "description": "Exact text to search for in memory labels (optional)"
            \\    },
            \\    "limit": {
            \\      "type": "integer",
            \\      "description": "Maximum number of results to return",
            \\      "default": 10
            \\    }
            \\  }
            \\}
        ;
        
        const search_by_concept_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "concept": {
            \\      "type": "string",
            \\      "description": "Concept name to search for"
            \\    },
            \\    "limit": {
            \\      "type": "integer",
            \\      "description": "Maximum number of results to return",
            \\      "default": 10
            \\    }
            \\  },
            \\  "required": ["concept"]
            \\}
        ;
        
        const list_recent_memories_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "count": {
            \\      "type": "integer",
            \\      "description": "Number of recent memories to retrieve",
            \\      "default": 5
            \\    }
            \\  }
            \\}
        ;
        
        const update_memory_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "id": {
            \\      "type": "integer",
            \\      "description": "ID of the memory to update"
            \\    },
            \\    "new_label": {
            \\      "type": "string",
            \\      "description": "New content for the memory"
            \\    }
            \\  },
            \\  "required": ["id", "new_label"]
            \\}
        ;
        
        const forget_memory_schema_json = 
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "id": {
            \\      "type": "integer",
            \\      "description": "ID of the memory to forget/delete"
            \\    }
            \\  },
            \\  "required": ["id"]
            \\}
        ;
        
        // Parse the schema strings into JSON values
        var store_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, store_memory_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse store_memory schema", null);
        };
        defer store_schema_parsed.deinit();
        
        var recall_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, recall_similar_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse recall_similar schema", null);
        };
        defer recall_schema_parsed.deinit();
        
        var explore_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, explore_relationships_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse explore_relationships schema", null);
        };
        defer explore_schema_parsed.deinit();
        
        var recall_memories_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, recall_memories_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse recall_memories schema", null);
        };
        defer recall_memories_schema_parsed.deinit();
        
        var search_by_concept_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, search_by_concept_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse search_by_concept schema", null);
        };
        defer search_by_concept_schema_parsed.deinit();
        
        var list_recent_memories_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, list_recent_memories_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse list_recent_memories schema", null);
        };
        defer list_recent_memories_schema_parsed.deinit();
        
        var update_memory_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, update_memory_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse update_memory schema", null);
        };
        defer update_memory_schema_parsed.deinit();
        
        var forget_memory_schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, forget_memory_schema_json, .{}) catch {
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, "Failed to parse forget_memory schema", null);
        };
        defer forget_memory_schema_parsed.deinit();
        
        const tools = [_]McpTool{
            McpTool{
                .name = "store_memory",
                .description = "Store a new semantic memory with type, confidence, and importance tracking",
                .inputSchema = store_schema_parsed.value,
            },
            McpTool{
                .name = "recall_similar",
                .description = "Retrieve semantic memories similar to a given query using the LLM memory system",
                .inputSchema = recall_schema_parsed.value,
            },
            McpTool{
                .name = "explore_relationships",
                .description = "Explore concept relationships in memory",
                .inputSchema = explore_schema_parsed.value,
            },
            McpTool{
                .name = "recall_memories",
                .description = "Retrieve memories by ID or exact text match",
                .inputSchema = recall_memories_schema_parsed.value,
            },
            McpTool{
                .name = "search_memories_by_concept",
                .description = "Find all memories containing a specific concept",
                .inputSchema = search_by_concept_schema_parsed.value,
            },
            McpTool{
                .name = "list_recent_memories",
                .description = "Get the most recently stored memories",
                .inputSchema = list_recent_memories_schema_parsed.value,
            },
            McpTool{
                .name = "update_memory",
                .description = "Update an existing memory's content",
                .inputSchema = update_memory_schema_parsed.value,
            },
            McpTool{
                .name = "forget_memory",
                .description = "Delete a memory and clean up its relationships",
                .inputSchema = forget_memory_schema_parsed.value,
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
        } else if (std.mem.eql(u8, tool_name, "recall_memories")) {
            return self.handleRecallMemories(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "search_memories_by_concept")) {
            return self.handleSearchMemoriesByConcept(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "list_recent_memories")) {
            return self.handleListRecentMemories(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "update_memory")) {
            return self.handleUpdateMemory(id, arguments);
        } else if (std.mem.eql(u8, tool_name, "forget_memory")) {
            return self.handleForgetMemory(id, arguments);
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
    
    /// Handle store_memory tool - Store a new semantic memory using the LLM Memory Data Models
    fn handleStoreMemory(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const content_value = args_obj.get("content") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing memory content", null);
        };
        
        const content = content_value.string;
        
        // Parse memory type
        const memory_type_str = if (args_obj.get("memory_type")) |mt| mt.string else "experience";
        const memory_type = std.meta.stringToEnum(MemoryType, memory_type_str) orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Invalid memory_type", null);
        };
        
        // Parse confidence level
        const confidence_str = if (args_obj.get("confidence")) |c| c.string else "medium";
        const confidence = std.meta.stringToEnum(MemoryConfidence, confidence_str) orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Invalid confidence level", null);
        };
        
        // Parse importance level
        const importance_str = if (args_obj.get("importance")) |i| i.string else "medium";
        const importance = std.meta.stringToEnum(MemoryImportance, importance_str) orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Invalid importance level", null);
        };
        
        // Parse source
        const source_str = if (args_obj.get("source")) |s| s.string else "user_input";
        const source = std.meta.stringToEnum(MemorySource, source_str) orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Invalid source", null);
        };
        
        // Parse optional session and user IDs
        const session_id = if (args_obj.get("session_id")) |sid| @as(u64, @intCast(sid.integer)) else null;
        const user_id = if (args_obj.get("user_id")) |uid| @as(u64, @intCast(uid.integer)) else null;
        
        // Store the memory using the MemoryManager
        const memory_id = self.memory_manager.storeMemory(
            memory_type,
            content,
            .{
                .confidence = confidence,
                .importance = importance,
                .source = source,
                .session_id = session_id,
                .user_id = user_id,
            }
        ) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to store memory: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // Build success response
        var response_text = std.ArrayList(u8).init(self.allocator);
        defer response_text.deinit();
        
        const main_msg = try std.fmt.allocPrint(self.allocator, 
            "Memory stored successfully with ID {}!\n\nMemory Details:\n• Type: {s}\n• Content: \"{s}\"\n• Confidence: {s}\n• Importance: {s}\n• Source: {s}\n", 
            .{ memory_id, @tagName(memory_type), content, @tagName(confidence), @tagName(importance), @tagName(source) });
        defer self.allocator.free(main_msg);
        try response_text.appendSlice(main_msg);
        
        if (session_id) |sid| {
            const session_msg = try std.fmt.allocPrint(self.allocator, "• Session ID: {}\n", .{sid});
            defer self.allocator.free(session_msg);
            try response_text.appendSlice(session_msg);
        }
        
        if (user_id) |uid| {
            const user_msg = try std.fmt.allocPrint(self.allocator, "• User ID: {}\n", .{uid});
            defer self.allocator.free(user_msg);
            try response_text.appendSlice(user_msg);
        }
        
        // Extract and create concept relationships for the new memory
        const concepts = try self.extractConcepts(content);
        defer {
            for (concepts.items) |concept| {
                self.allocator.free(concept);
            }
            concepts.deinit();
        }
        
        var created_concepts = std.ArrayList(u64).init(self.allocator);
        defer created_concepts.deinit();
        
        for (concepts.items) |concept| {
            const concept_id = self.generateConceptId(concept);
            
            // Create concept node if it doesn't exist
            if (self.db.graph_index.getNode(concept_id) == null) {
                const concept_node = types.Node.init(concept_id, concept);
                self.db.insertNode(concept_node) catch |err| {
                    std.debug.print("Warning: Failed to create concept node '{s}': {any}\n", .{ concept, err });
                    continue;
                };
            }
            
            try created_concepts.append(concept_id);
            
            // Create semantic relationship from memory to concept
            const memory_to_concept_edge = types.Edge.init(memory_id, concept_id, types.EdgeKind.related);
            self.db.insertEdge(memory_to_concept_edge) catch |err| {
                std.debug.print("Warning: Failed to create memory->concept edge: {any}\n", .{err});
            };
        }
        
        // Create connections between related concepts
        if (created_concepts.items.len > 1) {
            for (created_concepts.items, 0..) |concept1_id, i| {
                for (created_concepts.items[i+1..]) |concept2_id| {
                    const concept_edge1 = types.Edge.init(concept1_id, concept2_id, types.EdgeKind.similar_to);
                    const concept_edge2 = types.Edge.init(concept2_id, concept1_id, types.EdgeKind.similar_to);
                    
                    self.db.insertEdge(concept_edge1) catch |err| {
                        std.debug.print("Warning: Failed to create concept relationship: {any}\n", .{err});
                    };
                    self.db.insertEdge(concept_edge2) catch |err| {
                        std.debug.print("Warning: Failed to create concept relationship: {any}\n", .{err});
                    };
                }
            }
        }
        
        // Add concept information to response
        if (created_concepts.items.len > 0) {
            const concepts_info = try std.fmt.allocPrint(self.allocator, 
                "\nExtracted {} concepts: ", .{created_concepts.items.len});
            defer self.allocator.free(concepts_info);
            try response_text.appendSlice(concepts_info);
            
            for (concepts.items, 0..) |concept, i| {
                if (i > 0) try response_text.appendSlice(", ");
                try response_text.appendSlice("\"");
                try response_text.appendSlice(concept);
                try response_text.appendSlice("\"");
            }
            
            const relationships_count = created_concepts.items.len + (created_concepts.items.len * (created_concepts.items.len - 1) / 2);
            const relationships_info = try std.fmt.allocPrint(self.allocator, 
                "\nCreated {} semantic relationships", .{relationships_count});
            defer self.allocator.free(relationships_info);
            try response_text.appendSlice(relationships_info);
        }
        
        try response_text.appendSlice("\n\nMemory is now available for semantic search and relationship exploration!");
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = response_text.items,
                },
            },
        });
    }
    
    /// Create a simple embedding based on text characteristics
    /// In production, this would use a proper embedding model like OpenAI, Sentence-BERT, etc.
    fn createSimpleEmbedding(self: *Self, text: []const u8) ![]f32 {
        var embedding = [_]f32{0.0} ** 128;
        
        // Simple heuristic-based embedding generation
        // This is a placeholder - in production you'd use a real embedding model
        
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
        
        return self.allocator.dupe(f32, &embedding);
    }
    
    /// Extract concepts from memory text
    /// This is a simple implementation - in production would use NLP/NER
    fn extractConcepts(self: *Self, text: []const u8) !std.ArrayList([]const u8) {
        var concepts = std.ArrayList([]const u8).init(self.allocator);
        
        // Simple concept extraction: split on whitespace and filter meaningful words
        var word_iter = std.mem.splitScalar(u8, text, ' ');
        while (word_iter.next()) |word| {
            // Clean up the word (remove punctuation, convert to lowercase)
            var cleaned_word = std.ArrayList(u8).init(self.allocator);
            defer cleaned_word.deinit();
            
            for (word) |c| {
                if (std.ascii.isAlphabetic(c)) {
                    try cleaned_word.append(std.ascii.toLower(c));
                }
            }
            
            // Skip short words, common stop words, etc.
            if (cleaned_word.items.len < 3) continue;
            
            const word_str = try self.allocator.dupe(u8, cleaned_word.items);
            
            // Skip common stop words
            if (std.mem.eql(u8, word_str, "the") or 
                std.mem.eql(u8, word_str, "and") or 
                std.mem.eql(u8, word_str, "with") or 
                std.mem.eql(u8, word_str, "for") or
                std.mem.eql(u8, word_str, "are") or
                std.mem.eql(u8, word_str, "was") or
                std.mem.eql(u8, word_str, "this") or
                std.mem.eql(u8, word_str, "that")) {
                self.allocator.free(word_str);
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
                self.allocator.free(word_str);
            }
        }
        
        return concepts;
    }
    
    /// Generate a deterministic ID for a concept based on its text
    fn generateConceptId(self: *Self, concept: []const u8) u64 {
        _ = self; // unused
        
        // Use a hash function to generate deterministic IDs for concepts
        var hash: u64 = 14695981039346656037; // FNV-1a offset basis
        for (concept) |byte| {
            hash ^= byte;
            hash *%= 1099511628211; // FNV-1a prime
        }
        
        // Ensure we don't conflict with memory IDs (use high range)
        return hash | 0x8000000000000000; // Set high bit to distinguish from memory IDs
    }
    
    /// Handle recall_similar tool - Query semantic memories using the LLM Memory Data Models
    fn handleRecallSimilar(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        // Extract query parameters
        const args_obj = args.object;
        const query = args_obj.get("query") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing query parameter", null);
        };
        
        const query_str = query.string;
        const limit_value = args_obj.get("limit") orelse std.json.Value{ .integer = 5 };
        const limit: u32 = @intCast(limit_value.integer);
        
        // Build MemoryQuery with advanced filtering
        var memory_query = MemoryQuery.init();
        memory_query.query_text = query_str;
        memory_query.limit = limit;
        memory_query.include_related = true;
        
        // Parse memory type filters
        if (args_obj.get("memory_types")) |mt_array| {
            // For simplicity, we'll just handle the first type filter for now
            // A full implementation would support multiple types
            if (mt_array.array.items.len > 0) {
                const first_type_str = mt_array.array.items[0].string;
                if (std.meta.stringToEnum(MemoryType, first_type_str)) |memory_type| {
                    memory_query.memory_types = &[_]MemoryType{memory_type};
                }
            }
        }
        
        // Parse confidence filter
        if (args_obj.get("min_confidence")) |conf| {
            if (std.meta.stringToEnum(MemoryConfidence, conf.string)) |confidence| {
                memory_query.min_confidence = confidence;
            }
        }
        
        // Parse importance filter
        if (args_obj.get("min_importance")) |imp| {
            if (std.meta.stringToEnum(MemoryImportance, imp.string)) |importance| {
                memory_query.min_importance = importance;
            }
        }
        
        // Parse session filter
        if (args_obj.get("session_id")) |sid| {
            memory_query.session_id = @intCast(sid.integer);
        }
        
        // Parse user filter
        if (args_obj.get("user_id")) |uid| {
            memory_query.user_id = @intCast(uid.integer);
        }
        
        // Execute the memory query using MemoryManager
        var query_results = self.memory_manager.queryMemories(memory_query) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to query memories: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        defer query_results.deinit();
        
        // Build response with semantic memory details
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Found {} memories similar to query \"{s}\":\n\n", 
            .{ query_results.memories.items.len, query_str });
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        if (query_results.memories.items.len == 0) {
            try content_list.appendSlice("No matching memories found.");
        } else {
            // Show execution details
            const exec_info = try std.fmt.allocPrint(self.allocator, 
                "Query executed in {}ms\n\n", .{query_results.execution_time_ms});
            defer self.allocator.free(exec_info);
            try content_list.appendSlice(exec_info);
            
            // List each memory with full semantic details
            for (query_results.memories.items, 0..) |memory, i| {
                const similarity_score = if (i < query_results.similarity_scores.items.len) 
                    query_results.similarity_scores.items[i] else 0.0;
                    
                const memory_info = try std.fmt.allocPrint(self.allocator,
                    "{}. Memory {} (Type: {s}, Confidence: {s}, Importance: {s})\n" ++
                    "   Content: \"{s}\"\n" ++
                    "   Source: {s}, Created: {}\n" ++
                    "   Similarity: {d:.3}\n",
                    .{ 
                        i + 1, memory.id, @tagName(memory.memory_type), 
                        @tagName(memory.confidence), @tagName(memory.importance),
                        memory.getContentAsString(),
                        @tagName(memory.source), memory.created_at,
                        similarity_score
                    });
                defer self.allocator.free(memory_info);
                try content_list.appendSlice(memory_info);
                
                if (memory.session_id != 0) {
                    const session_info = try std.fmt.allocPrint(self.allocator, "   Session: {}\n", .{memory.session_id});
                    defer self.allocator.free(session_info);
                    try content_list.appendSlice(session_info);
                }
                
                try content_list.appendSlice("\n");
            }
            
            // Show related memories and relationships if found
            if (query_results.related_memories.items.len > 0) {
                const related_header = try std.fmt.allocPrint(self.allocator, 
                    "Related memories found: {}\n", .{query_results.related_memories.items.len});
                defer self.allocator.free(related_header);
                try content_list.appendSlice(related_header);
            }
            
            if (query_results.relationships.items.len > 0) {
                const rel_header = try std.fmt.allocPrint(self.allocator, 
                    "Semantic relationships: {}\n", .{query_results.relationships.items.len});
                defer self.allocator.free(rel_header);
                try content_list.appendSlice(rel_header);
            }
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Fallback method for recall_similar using string matching
    fn handleRecallSimilarFallback(self: *Self, id: ?std.json.Value, query_str: []const u8, limit: u32) ![]u8 {
        var matching_memories = std.ArrayList(struct {
            id: u64,
            label: []const u8,
            relevance: f32,
        }).init(self.allocator);
        defer matching_memories.deinit();
        
        // Get all nodes and search for matches
        var node_iter = self.db.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            const node_label = node.getLabelAsString();
            
            // Simple string matching - check if query is contained in label
            if (std.mem.indexOf(u8, node_label, query_str) != null) {
                // Calculate relevance based on how well the query matches
                const relevance: f32 = if (std.mem.eql(u8, node_label, query_str)) 
                    1.0 
                else if (std.mem.startsWith(u8, node_label, query_str)) 
                    0.8 
                else 
                    0.6;
                    
                try matching_memories.append(.{
                    .id = node.id,
                    .label = node_label,
                    .relevance = relevance,
                });
            }
        }
        
        // Sort by relevance (descending)
        std.sort.pdq(@TypeOf(matching_memories.items[0]), matching_memories.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(matching_memories.items[0]), b: @TypeOf(matching_memories.items[0])) bool {
                return a.relevance > b.relevance;
            }
        }.lessThan);
        
        // Limit results
        const actual_limit = @min(limit, @as(u32, @intCast(matching_memories.items.len)));
        
        // Build response content
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        try content_list.appendSlice("Found memories similar to query \"");
        try content_list.appendSlice(query_str);
        try content_list.appendSlice("\" (using text search):\n\n");
        
        if (actual_limit == 0) {
            try content_list.appendSlice("No matching memories found.");
        } else {
            for (matching_memories.items[0..actual_limit]) |memory| {
                const memory_text = try std.fmt.allocPrint(self.allocator, 
                    "Memory {}: {s} (relevance: {d:.2})\n", 
                    .{ memory.id, memory.label, memory.relevance });
                defer self.allocator.free(memory_text);
                try content_list.appendSlice(memory_text);
            }
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle explore_relationships tool
    fn handleExploreRelationships(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        // Extract relationship exploration parameters
        const args_obj = args.object;
        const node_id = args_obj.get("node_id") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing node_id parameter", null);
        };
        
        const depth_value = args_obj.get("depth") orelse std.json.Value{ .integer = 2 };
        const depth: u8 = @intCast(depth_value.integer);
        
        const start_node_id: u64 = @intCast(node_id.integer);
        
        // Check if the starting node exists
        const start_node = self.db.graph_index.getNode(start_node_id) orelse {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Node {} not found", .{start_node_id});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, error_msg, null);
        };
        
        // Perform graph traversal to find related nodes
        const related_nodes = self.db.queryRelated(start_node_id, depth) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to explore relationships: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        defer related_nodes.deinit();
        
        // Build response content with relationship information
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Exploring relationships from node {} (\"{s}\") with depth {}:\n\n", 
            .{ start_node.id, start_node.getLabelAsString(), depth });
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        if (related_nodes.items.len == 0) {
            try content_list.appendSlice("No related nodes found.");
        } else {
            try content_list.appendSlice("Related nodes:\n");
            
            for (related_nodes.items, 0..) |node, i| {
                // For each node, also show its connections
                const node_info = try std.fmt.allocPrint(self.allocator, 
                    "{}. Node {} (\"{s}\")", 
                    .{ i + 1, node.id, node.getLabelAsString() });
                defer self.allocator.free(node_info);
                try content_list.appendSlice(node_info);
                
                // Show outgoing edges
                if (self.db.graph_index.getOutgoingEdges(node.id)) |outgoing_edges| {
                    if (outgoing_edges.len > 0) {
                        try content_list.appendSlice(" → [");
                        for (outgoing_edges, 0..) |edge, edge_idx| {
                            if (edge_idx > 0) try content_list.appendSlice(", ");
                            const edge_info = try std.fmt.allocPrint(self.allocator, "{}", .{edge.to});
                            defer self.allocator.free(edge_info);
                            try content_list.appendSlice(edge_info);
                        }
                        try content_list.appendSlice("]");
                    }
                }
                
                // Show incoming edges  
                if (self.db.graph_index.getIncomingEdges(node.id)) |incoming_edges| {
                    if (incoming_edges.len > 0) {
                        try content_list.appendSlice(" ← [");
                        for (incoming_edges, 0..) |edge, edge_idx| {
                            if (edge_idx > 0) try content_list.appendSlice(", ");
                            const edge_info = try std.fmt.allocPrint(self.allocator, "{}", .{edge.from});
                            defer self.allocator.free(edge_info);
                            try content_list.appendSlice(edge_info);
                        }
                        try content_list.appendSlice("]");
                    }
                }
                
                try content_list.appendSlice("\n");
            }
            
            // Summary statistics
            const summary = try std.fmt.allocPrint(self.allocator, 
                "\nSummary: Found {} related nodes within {} hops of node {}.", 
                .{ related_nodes.items.len, depth, start_node_id });
            defer self.allocator.free(summary);
            try content_list.appendSlice(summary);
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle recall_memories tool - Direct recall by ID or text match
    fn handleRecallMemories(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const memory_id_value = args_obj.get("memory_id");
        const text_query_value = args_obj.get("text_query");
        const limit_value = args_obj.get("limit") orelse std.json.Value{ .integer = 10 };
        const limit: u32 = @intCast(limit_value.integer);
        
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        if (memory_id_value) |mem_id| {
            // Direct recall by ID
            const memory_id: u64 = @intCast(mem_id.integer);
            
            if (self.db.graph_index.getNode(memory_id)) |node| {
                // Get full memory content from MemoryManager instead of just the label
                const memory_content = if (try self.memory_manager.getMemory(memory_id)) |memory| 
                    memory.getContentAsString() 
                else 
                    node.getLabelAsString(); // Fallback to label if memory retrieval fails
                
                const memory_text = try std.fmt.allocPrint(self.allocator, 
                    "Memory {}: \"{s}\"\n\n", .{ memory_id, memory_content });
                defer self.allocator.free(memory_text);
                try content_list.appendSlice(memory_text);
                
                // Show related concepts
                if (self.db.graph_index.getOutgoingEdges(memory_id)) |edges| {
                    try content_list.appendSlice("Related concepts: ");
                    var concept_count: u32 = 0;
                    for (edges) |edge| {
                        if (edge.getKind() == types.EdgeKind.related) {
                            if (self.db.graph_index.getNode(edge.to)) |concept_node| {
                                if (concept_count > 0) try content_list.appendSlice(", ");
                                try content_list.appendSlice(concept_node.getLabelAsString());
                                concept_count += 1;
                            }
                        }
                    }
                    if (concept_count == 0) {
                        try content_list.appendSlice("None");
                    }
                    try content_list.appendSlice("\n");
                }
            } else {
                const error_msg = try std.fmt.allocPrint(self.allocator, "Memory {} not found", .{memory_id});
                defer self.allocator.free(error_msg);
                try content_list.appendSlice(error_msg);
            }
        } else if (text_query_value) |text_query| {
            // Search by exact text match
            const query_str = text_query.string;
            try content_list.appendSlice("Searching for memories containing: \"");
            try content_list.appendSlice(query_str);
            try content_list.appendSlice("\"\n\n");
            
            var found_count: u32 = 0;
            var node_iter = self.db.graph_index.nodes.iterator();
            while (node_iter.next()) |entry| {
                if (found_count >= limit) break;
                
                const node = entry.value_ptr.*;
                // Check if this is a memory node (not a concept node)
                if (node.id >= 0x8000000000000000) continue;
                
                // Get full memory content from MemoryManager
                const memory_content = if (try self.memory_manager.getMemory(node.id)) |memory| 
                    memory.getContentAsString() 
                else 
                    node.getLabelAsString(); // Fallback to label if memory retrieval fails
                
                if (std.mem.indexOf(u8, memory_content, query_str) != null) {
                    found_count += 1;
                    const memory_text = try std.fmt.allocPrint(self.allocator, 
                        "{}. Memory {}: \"{s}\"\n", .{ found_count, node.id, memory_content });
                    defer self.allocator.free(memory_text);
                    try content_list.appendSlice(memory_text);
                }
            }
            
            if (found_count == 0) {
                try content_list.appendSlice("No memories found containing the specified text.");
            }
        } else {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Must provide either memory_id or text_query", null);
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle search_memories_by_concept tool - Find memories containing specific concepts
    fn handleSearchMemoriesByConcept(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const concept_value = args_obj.get("concept") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing concept parameter", null);
        };
        const limit_value = args_obj.get("limit") orelse std.json.Value{ .integer = 10 };
        const limit: u32 = @intCast(limit_value.integer);
        
        const concept_name = concept_value.string;
        
        // Find the concept node
        const concept_id = self.generateConceptId(concept_name);
        
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Memories containing concept \"{s}\":\n\n", .{concept_name});
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        if (self.db.graph_index.getNode(concept_id)) |_| {
            // Find all memories that link to this concept
            var found_count: u32 = 0;
            
            if (self.db.graph_index.getIncomingEdges(concept_id)) |incoming_edges| {
                for (incoming_edges) |edge| {
                    if (found_count >= limit) break;
                    
                    if (edge.getKind() == types.EdgeKind.related) {
                        if (self.db.graph_index.getNode(edge.from)) |memory_node| {
                            // Check if this is a memory node (not another concept)
                            if (edge.from < 0x8000000000000000) { // Memory nodes have lower IDs
                                found_count += 1;
                                
                                // Get full memory content from MemoryManager
                                const memory_content = if (try self.memory_manager.getMemory(memory_node.id)) |memory| 
                                    memory.getContentAsString() 
                                else 
                                    memory_node.getLabelAsString(); // Fallback to label if memory retrieval fails
                                
                                const memory_text = try std.fmt.allocPrint(self.allocator, 
                                    "{}. Memory {}: \"{s}\"\n", 
                                    .{ found_count, memory_node.id, memory_content });
                                defer self.allocator.free(memory_text);
                                try content_list.appendSlice(memory_text);
                            }
                        }
                    }
                }
            }
            
            if (found_count == 0) {
                try content_list.appendSlice("No memories found for this concept.");
            } else {
                const summary = try std.fmt.allocPrint(self.allocator, 
                    "\nFound {} memories containing concept \"{s}\".", .{ found_count, concept_name });
                defer self.allocator.free(summary);
                try content_list.appendSlice(summary);
            }
        } else {
            try content_list.appendSlice("Concept not found in memory database.");
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle list_recent_memories tool - Get the most recently stored memories
    fn handleListRecentMemories(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const count_value = args_obj.get("count") orelse std.json.Value{ .integer = 5 };
        const count: u32 = @intCast(count_value.integer);
        
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Most recent {} memories:\n\n", .{count});
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        // Collect all memory nodes (excluding concept nodes)
        var memory_nodes = std.ArrayList(types.Node).init(self.allocator);
        defer memory_nodes.deinit();
        
        var node_iter = self.db.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            // Memory nodes have lower IDs (concept nodes have high bit set)
            if (node.id < 0x8000000000000000) {
                try memory_nodes.append(node);
            }
        }
        
        // Sort by ID (assuming higher IDs are more recent)
        std.sort.pdq(types.Node, memory_nodes.items, {}, struct {
            fn lessThan(_: void, a: types.Node, b: types.Node) bool {
                return a.id > b.id; // Descending order (most recent first)
            }
        }.lessThan);
        
        // Show the most recent memories
        const actual_count = @min(count, @as(u32, @intCast(memory_nodes.items.len)));
        
        if (actual_count == 0) {
            try content_list.appendSlice("No memories found in the database.");
        } else {
            for (memory_nodes.items[0..actual_count], 0..) |node, i| {
                // Get full memory content from MemoryManager instead of just the label
                const memory_content = if (try self.memory_manager.getMemory(node.id)) |memory| 
                    memory.getContentAsString() 
                else 
                    node.getLabelAsString(); // Fallback to label if memory retrieval fails
                
                const memory_text = try std.fmt.allocPrint(self.allocator, 
                    "{}. Memory {}: \"{s}\"\n", 
                    .{ i + 1, node.id, memory_content });
                defer self.allocator.free(memory_text);
                try content_list.appendSlice(memory_text);
            }
            
            const summary = try std.fmt.allocPrint(self.allocator, 
                "\nShowing {} most recent memories.", .{actual_count});
            defer self.allocator.free(summary);
            try content_list.appendSlice(summary);
        }
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle update_memory tool - Update an existing memory's content
    fn handleUpdateMemory(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const memory_id_value = args_obj.get("id") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing id parameter", null);
        };
        const new_label_value = args_obj.get("new_label") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing new_label parameter", null);
        };
        
        const memory_id: u64 = @intCast(memory_id_value.integer);
        const new_label = new_label_value.string;
        
        // Get existing memory for reporting (also validates it exists)
        const existing_memory = try self.memory_manager.getMemory(memory_id) orelse {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Memory {} not found", .{memory_id});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, error_msg, null);
        };
        
        // Store old content for reporting
        const old_content = existing_memory.getContentAsString();
        
        // First, clean up old relationships (concept-related edges)
        _ = try self.cleanupMemoryRelationships(memory_id);
        
        // Update the memory using MemoryManager (this handles content persistence and embedding)
        self.memory_manager.updateMemory(memory_id, new_label, .{}) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to update memory: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // Extract and create new concept relationships
        const concepts = try self.extractConcepts(new_label);
        defer {
            for (concepts.items) |concept| {
                self.allocator.free(concept);
            }
            concepts.deinit();
        }
        
        var created_concepts = std.ArrayList(u64).init(self.allocator);
        defer created_concepts.deinit();
        
        for (concepts.items) |concept| {
            const concept_id = self.generateConceptId(concept);
            
            // Create concept node if it doesn't exist
            if (self.db.graph_index.getNode(concept_id) == null) {
                const concept_node = types.Node.init(concept_id, concept);
                self.db.insertNode(concept_node) catch |err| {
                    std.debug.print("Warning: Failed to create concept node '{s}': {any}\n", .{ concept, err });
                    continue;
                };
            }
            
            try created_concepts.append(concept_id);
            
            // Create semantic relationship from memory to concept
            const memory_to_concept_edge = types.Edge.init(memory_id, concept_id, types.EdgeKind.related);
            self.db.insertEdge(memory_to_concept_edge) catch |err| {
                std.debug.print("Warning: Failed to create memory->concept edge: {any}\n", .{err});
            };
        }
        
        // Create connections between related concepts
        if (created_concepts.items.len > 1) {
            for (created_concepts.items, 0..) |concept1_id, i| {
                for (created_concepts.items[i+1..]) |concept2_id| {
                    const concept_edge1 = types.Edge.init(concept1_id, concept2_id, types.EdgeKind.similar_to);
                    const concept_edge2 = types.Edge.init(concept2_id, concept1_id, types.EdgeKind.similar_to);
                    
                    self.db.insertEdge(concept_edge1) catch |err| {
                        std.debug.print("Warning: Failed to create concept relationship: {any}\n", .{err});
                    };
                    self.db.insertEdge(concept_edge2) catch |err| {
                        std.debug.print("Warning: Failed to create concept relationship: {any}\n", .{err});
                    };
                }
            }
        }
        
        // Build response
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Memory {} updated successfully!\n\n", .{memory_id});
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        const old_info = try std.fmt.allocPrint(self.allocator, 
            "Old content: \"{s}\"\n", .{old_content});
        defer self.allocator.free(old_info);
        try content_list.appendSlice(old_info);
        
        const new_info = try std.fmt.allocPrint(self.allocator, 
            "New content: \"{s}\"\n\n", .{new_label});
        defer self.allocator.free(new_info);
        try content_list.appendSlice(new_info);
        
        try content_list.appendSlice("• Updated vector embedding: 128 dimensions\n");
        
        if (created_concepts.items.len > 0) {
            const concepts_info = try std.fmt.allocPrint(self.allocator, 
                "• Extracted {} new concepts: ", .{created_concepts.items.len});
            defer self.allocator.free(concepts_info);
            try content_list.appendSlice(concepts_info);
            
            for (concepts.items, 0..) |concept, i| {
                if (i > 0) try content_list.appendSlice(", ");
                try content_list.appendSlice(concept);
            }
            try content_list.appendSlice("\n");
            
            // Count relationships
            const total_relationships = created_concepts.items.len + 
                (created_concepts.items.len * (created_concepts.items.len - 1)); // memory->concepts + concept-concept pairs
            
            const relationships_info = try std.fmt.allocPrint(self.allocator, 
                "• Created {} semantic relationships\n", .{total_relationships});
            defer self.allocator.free(relationships_info);
            try content_list.appendSlice(relationships_info);
        }
        
        const summary = try std.fmt.allocPrint(self.allocator, 
            "\nMemory content and semantic relationships have been successfully updated.", .{});
        defer self.allocator.free(summary);
        try content_list.appendSlice(summary);
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Handle forget_memory tool - Delete a memory and clean up its relationships
    fn handleForgetMemory(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        const args_obj = args.object;
        const memory_id_value = args_obj.get("id") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing id parameter", null);
        };
        
        const memory_id: u64 = @intCast(memory_id_value.integer);
        
        // Get existing memory for reporting and validation (also validates it exists)
        const existing_memory = try self.memory_manager.getMemory(memory_id) orelse {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Memory {} not found", .{memory_id});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, error_msg, null);
        };
        
        const memory_content = existing_memory.getContentAsString();
        
        // Count relationships before deletion for reporting
        var deleted_edges: u32 = 0;
        var orphaned_concepts: u32 = 0;
        
        // Clean up all relationships
        deleted_edges = try self.cleanupMemoryRelationships(memory_id);
        
        // Check for orphaned concept nodes and clean them up
        orphaned_concepts = try self.cleanupOrphanedConcepts();
        
        // Remove the memory using MemoryManager (this handles content cache cleanup)
        self.memory_manager.forgetMemory(memory_id) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to forget memory: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // Remove the memory node from database
        self.db.graph_index.removeNode(memory_id) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to remove memory node: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // Remove the vector
        const vector_removed = self.db.vector_index.removeVector(memory_id);
        if (!vector_removed) {
            std.debug.print("Warning: Vector for memory {} was not found or could not be removed\n", .{memory_id});
        }
        
        // Build response
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Memory {} forgotten successfully!\n\n", .{memory_id});
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        const forgotten_info = try std.fmt.allocPrint(self.allocator, 
            "Forgotten memory: \"{s}\"\n\n", .{memory_content});
        defer self.allocator.free(forgotten_info);
        try content_list.appendSlice(forgotten_info);
        
        try content_list.appendSlice("Cleanup summary:\n");
        
        const edges_info = try std.fmt.allocPrint(self.allocator, 
            "• Removed {} relationship edges\n", .{deleted_edges});
        defer self.allocator.free(edges_info);
        try content_list.appendSlice(edges_info);
        
        if (orphaned_concepts > 0) {
            const concepts_info = try std.fmt.allocPrint(self.allocator, 
                "• Cleaned up {} orphaned concept nodes\n", .{orphaned_concepts});
            defer self.allocator.free(concepts_info);
            try content_list.appendSlice(concepts_info);
        }
        
        try content_list.appendSlice("• Removed vector embedding\n");
        try content_list.appendSlice("• Removed memory node\n");
        try content_list.appendSlice("• Cleaned up memory content cache\n");
        
        try content_list.appendSlice("\nMemory and all associated data have been completely removed from the database.");
        
        return self.createSuccessResponse(id, .{
            .content = [_]struct { 
                type: []const u8, 
                text: []const u8 
            }{
                .{
                    .type = "text",
                    .text = content_list.items,
                },
            },
        });
    }
    
    /// Helper function to clean up relationships for a memory
    fn cleanupMemoryRelationships(self: *Self, memory_id: u64) !u32 {
        var deleted_count: u32 = 0;
        
        // Remove all outgoing edges from this memory
        if (self.db.graph_index.getOutgoingEdges(memory_id)) |outgoing_edges| {
            for (outgoing_edges) |edge| {
                self.db.graph_index.removeEdge(edge.from, edge.to) catch |err| {
                    std.debug.print("Warning: Failed to remove outgoing edge {}->{}: {any}\n", .{ edge.from, edge.to, err });
                };
                deleted_count += 1;
            }
        }
        
        // Remove all incoming edges to this memory
        if (self.db.graph_index.getIncomingEdges(memory_id)) |incoming_edges| {
            for (incoming_edges) |edge| {
                self.db.graph_index.removeEdge(edge.from, edge.to) catch |err| {
                    std.debug.print("Warning: Failed to remove incoming edge {}->{}: {any}\n", .{ edge.from, edge.to, err });
                };
                deleted_count += 1;
            }
        }
        
        return deleted_count;
    }
    
    /// Helper function to clean up orphaned concept nodes
    /// A concept is considered orphaned only if it has NO connections to memory nodes
    fn cleanupOrphanedConcepts(self: *Self) !u32 {
        var orphaned_count: u32 = 0;
        var concepts_to_remove = std.ArrayList(u64).init(self.allocator);
        defer concepts_to_remove.deinit();
        
        // Find concept nodes that are truly orphaned
        var node_iter = self.db.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node_id = entry.key_ptr.*;
            
            // Check if this is a concept node (high bit set)
            if (node_id >= 0x8000000000000000) {
                var has_memory_connections = false;
                
                // Check incoming edges - are there any memory nodes pointing to this concept?
                if (self.db.graph_index.getIncomingEdges(node_id)) |incoming_edges| {
                    for (incoming_edges) |edge| {
                        // If the source is a memory node (not a concept), this concept is still in use
                        if (edge.from < 0x8000000000000000 and edge.getKind() == types.EdgeKind.related) {
                            has_memory_connections = true;
                            break;
                        }
                    }
                }
                
                // Check outgoing edges - does this concept point to any memory nodes?
                if (!has_memory_connections) {
                    if (self.db.graph_index.getOutgoingEdges(node_id)) |outgoing_edges| {
                        for (outgoing_edges) |edge| {
                            // If the target is a memory node, this concept is still in use  
                            if (edge.to < 0x8000000000000000 and edge.getKind() == types.EdgeKind.related) {
                                has_memory_connections = true;
                                break;
                            }
                        }
                    }
                }
                
                // Only mark for removal if it has no connections to memory nodes
                if (!has_memory_connections) {
                    try concepts_to_remove.append(node_id);
                }
            }
        }
        
        // Remove truly orphaned concepts and clean up their concept-to-concept relationships
        for (concepts_to_remove.items) |concept_id| {
            // First remove all edges involving this concept
            _ = try self.cleanupMemoryRelationships(concept_id);
            
            // Then remove the concept node itself
            self.db.graph_index.removeNode(concept_id) catch |err| {
                std.debug.print("Warning: Failed to remove orphaned concept {}: {any}\n", .{ concept_id, err });
                continue;
            };
            orphaned_count += 1;
        }
        
        return orphaned_count;
    }
    
    /// Create a success response
    fn createSuccessResponse(self: *Self, id: ?std.json.Value, result: anytype) ![]u8 {
        // Convert result to JSON Value
        var json_string = std.ArrayList(u8).init(self.allocator);
        defer json_string.deinit();
        
        try std.json.stringify(result, .{}, json_string.writer());
        
        var result_value = try std.json.parseFromSlice(std.json.Value, self.allocator, json_string.items, .{});
        defer result_value.deinit();
        
        const response = JsonRpcSuccessResponse{
            .jsonrpc = "2.0",
            .id = id,
            .result = result_value.value,
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
        
        const response = JsonRpcErrorResponse{
            .jsonrpc = "2.0",
            .id = id,
            .@"error" = error_obj,
        };
        
        var response_json = std.ArrayList(u8).init(self.allocator);
        defer response_json.deinit();
        
        try std.json.stringify(response, .{}, response_json.writer());
        
        return self.allocator.dupe(u8, response_json.items);
    }

    /// Create a snapshot using MemoryManager's cache for proper memory content persistence
    pub fn createSnapshotWithMemoryManager(self: *Self) !main.snapshot.SnapshotInfo {
        // Sync log to disk first
        try self.db.append_log.sync();

        // Extract current data
        const vectors = try self.db.getAllVectors();
        defer vectors.deinit();
        
        const nodes = try self.db.getAllNodes();
        defer nodes.deinit();
        
        const edges = try self.db.getAllEdges();
        defer edges.deinit();
        
        // Get memory contents from MemoryManager's cache (not just the log)
        const memory_contents = try self.db.getAllMemoryContentFromManager(&self.memory_manager);
        defer {
            // Free the allocated content strings
            for (memory_contents.items) |memory_content| {
                self.allocator.free(memory_content.content);
            }
            memory_contents.deinit();
        }

        // Create snapshot with memory contents included
        const snapshot_info = try self.db.snapshot_manager.createSnapshot(vectors.items, nodes.items, edges.items, memory_contents.items);

        // Now we can safely clear the append log since memory content is preserved in snapshot files
        try self.db.append_log.clear();

        // Upload to S3 if configured
        if (self.db.s3_sync) |*s3_client| {
            if (self.db.config.s3_prefix) |prefix| {
                try s3_client.uploadSnapshot(self.db.config.data_path, snapshot_info.snapshot_id, prefix);
            }
        }

        return snapshot_info;
    }
}; 