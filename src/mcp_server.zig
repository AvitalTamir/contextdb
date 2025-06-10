const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");

const Memora = main.Memora;

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
    port: u16,
    server_info: McpImplementation,
    capabilities: McpCapabilities,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, db: *Memora, port: u16) Self {
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
            \\    "id": {
            \\      "type": "integer",
            \\      "description": "Unique identifier for the memory"
            \\    },
            \\    "label": {
            \\      "type": "string",
            \\      "description": "Label describing the memory content"
            \\    }
            \\  },
            \\  "required": ["id", "label"]
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
                .description = "Store a new memory/experience in the database",
                .inputSchema = store_schema_parsed.value,
            },
            McpTool{
                .name = "recall_similar",
                .description = "Retrieve memories similar to a given query",
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
        
        const memory_id: u64 = @intCast(node_id.integer);
        const memory_text = label.string;
        
        // 1. Create the main memory node
        const memory_node = types.Node.init(memory_id, memory_text);
        self.db.insertNode(memory_node) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to store memory node: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // 2. Create vector embedding for semantic similarity search
        // For now, we'll create a simple embedding based on text characteristics
        // In production, this would use a proper embedding model
        const embedding = try self.createSimpleEmbedding(memory_text);
        defer self.allocator.free(embedding);
        const vector = types.Vector.init(memory_id, embedding);
        self.db.insertVector(vector) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to store memory vector: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // 3. Extract and create concept nodes
        const concepts = try self.extractConcepts(memory_text);
        defer {
            for (concepts.items) |concept| {
                self.allocator.free(concept);
            }
            concepts.deinit();
        }
        
        var created_concepts = std.ArrayList(u64).init(self.allocator);
        defer created_concepts.deinit();
        
        for (concepts.items) |concept| {
            // Create concept node with a derived ID
            const concept_id = self.generateConceptId(concept);
            
            // Check if concept already exists, if not create it
            if (self.db.graph_index.getNode(concept_id) == null) {
                const concept_node = types.Node.init(concept_id, concept);
                self.db.insertNode(concept_node) catch |err| {
                    std.debug.print("Warning: Failed to create concept node '{s}': {any}\n", .{ concept, err });
                    continue;
                };
            }
            
            try created_concepts.append(concept_id);
            
            // 4. Create semantic relationship from memory to concept
            const memory_to_concept_edge = types.Edge.init(memory_id, concept_id, types.EdgeKind.related);
            self.db.insertEdge(memory_to_concept_edge) catch |err| {
                std.debug.print("Warning: Failed to create memory->concept edge: {any}\n", .{err});
            };
        }
        
        // 5. Create connections between related concepts
        if (created_concepts.items.len > 1) {
            for (created_concepts.items, 0..) |concept1_id, i| {
                for (created_concepts.items[i+1..]) |concept2_id| {
                    // Create bidirectional concept relationships
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
        
        // Build detailed response
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        const header = try std.fmt.allocPrint(self.allocator, 
            "Memory stored successfully with ID {}!\n\n", .{memory_id});
        defer self.allocator.free(header);
        try content_list.appendSlice(header);
        
        try content_list.appendSlice("Created memory structure:\n");
        
        const memory_info = try std.fmt.allocPrint(self.allocator, 
            "• Memory Node: {} (\"{s}\")\n", .{ memory_id, memory_text });
        defer self.allocator.free(memory_info);
        try content_list.appendSlice(memory_info);
        
        const vector_info = try std.fmt.allocPrint(self.allocator, 
            "• Vector Embedding: {} dimensions for semantic search\n", .{embedding.len});
        defer self.allocator.free(vector_info);
        try content_list.appendSlice(vector_info);
        
        if (created_concepts.items.len > 0) {
            const concepts_info = try std.fmt.allocPrint(self.allocator, 
                "• Extracted {} concepts: ", .{created_concepts.items.len});
            defer self.allocator.free(concepts_info);
            try content_list.appendSlice(concepts_info);
            
            for (concepts.items, 0..) |concept, i| {
                if (i > 0) try content_list.appendSlice(", ");
                try content_list.appendSlice("\"");
                try content_list.appendSlice(concept);
                try content_list.appendSlice("\"");
            }
            try content_list.appendSlice("\n");
            
            const relationships_count = created_concepts.items.len + (created_concepts.items.len * (created_concepts.items.len - 1) / 2);
            const relationships_info = try std.fmt.allocPrint(self.allocator, 
                "• Created {} semantic relationships\n", .{relationships_count});
            defer self.allocator.free(relationships_info);
            try content_list.appendSlice(relationships_info);
        }
        
        try content_list.appendSlice("\nMemory is now searchable and explorable through the graph!");
        
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
    
    /// Handle recall_similar tool
    fn handleRecallSimilar(self: *Self, id: ?std.json.Value, arguments: ?std.json.Value) ![]u8 {
        const args = arguments orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing arguments", null);
        };
        
        // Extract query parameters
        const args_obj = args.object;
        const query = args_obj.get("query") orelse {
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, "Missing query parameter", null);
        };
        
        const limit_value = args_obj.get("limit") orelse std.json.Value{ .integer = 5 };
        const limit: u32 = @intCast(limit_value.integer);
        
        const query_str = query.string;
        
        // 1. Create embedding for the query
        const query_embedding = try self.createSimpleEmbedding(query_str);
        defer self.allocator.free(query_embedding);
        
        // 2. Create a temporary vector for similarity search
        const query_vector = types.Vector.init(0, query_embedding); // ID 0 for query
        
        // 3. Use vector similarity search to find related memories
        const similar_vectors = self.db.vector_search.querySimilarByVector(&self.db.vector_index, query_vector, limit) catch |err| {
            // Fallback to string matching if vector search fails
            std.debug.print("Vector search failed, falling back to string matching: {any}\n", .{err});
            return self.handleRecallSimilarFallback(id, query_str, limit);
        };
        defer similar_vectors.deinit();
        
        // 4. Build response with similar memories
        var content_list = std.ArrayList(u8).init(self.allocator);
        defer content_list.deinit();
        
        try content_list.appendSlice("Found memories similar to query \"");
        try content_list.appendSlice(query_str);
        try content_list.appendSlice("\":\n\n");
        
        if (similar_vectors.items.len == 0) {
            try content_list.appendSlice("No similar memories found.");
        } else {
            for (similar_vectors.items, 0..) |result, i| {
                // Get the memory node for this vector
                if (self.db.graph_index.getNode(result.id)) |memory_node| {
                    const memory_text = try std.fmt.allocPrint(self.allocator, 
                        "{}. Memory {}: \"{s}\" (similarity: {d:.3})\n", 
                        .{ i + 1, result.id, memory_node.getLabelAsString(), result.similarity });
                    defer self.allocator.free(memory_text);
                    try content_list.appendSlice(memory_text);
                    
                    // Show related concepts
                    if (self.db.graph_index.getOutgoingEdges(result.id)) |edges| {
                        var concept_names = std.ArrayList([]const u8).init(self.allocator);
                        defer concept_names.deinit();
                        
                        for (edges) |edge| {
                            if (edge.getKind() == types.EdgeKind.related) {
                                if (self.db.graph_index.getNode(edge.to)) |concept_node| {
                                    try concept_names.append(concept_node.getLabelAsString());
                                }
                            }
                        }
                        
                        if (concept_names.items.len > 0) {
                            try content_list.appendSlice("   Concepts: ");
                            for (concept_names.items, 0..) |concept, j| {
                                if (j > 0) try content_list.appendSlice(", ");
                                try content_list.appendSlice(concept);
                            }
                            try content_list.appendSlice("\n");
                        }
                    }
                    try content_list.appendSlice("\n");
                }
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
                const memory_text = try std.fmt.allocPrint(self.allocator, 
                    "Memory {}: \"{s}\"\n\n", .{ memory_id, node.getLabelAsString() });
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
                const node_label = node.getLabelAsString();
                
                if (std.mem.indexOf(u8, node_label, query_str) != null) {
                    found_count += 1;
                    const memory_text = try std.fmt.allocPrint(self.allocator, 
                        "{}. Memory {}: \"{s}\"\n", .{ found_count, node.id, node_label });
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
                                const memory_text = try std.fmt.allocPrint(self.allocator, 
                                    "{}. Memory {}: \"{s}\"\n", 
                                    .{ found_count, memory_node.id, memory_node.getLabelAsString() });
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
                const memory_text = try std.fmt.allocPrint(self.allocator, 
                    "{}. Memory {}: \"{s}\"\n", 
                    .{ i + 1, node.id, node.getLabelAsString() });
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
        
        // Check if the memory exists
        const existing_node = self.db.graph_index.getNode(memory_id) orelse {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Memory {} not found", .{memory_id});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, error_msg, null);
        };
        
        // Store old label for reporting
        const old_label = existing_node.getLabelAsString();
        
        // First, clean up old relationships
        _ = try self.cleanupMemoryRelationships(memory_id);
        
        // Update the memory node with new content
        const updated_node = types.Node.init(memory_id, new_label);
        self.db.insertNode(updated_node) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to update memory node: {any}", .{err});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INTERNAL_ERROR, error_msg, null);
        };
        
        // Create new vector embedding for the updated content
        const embedding = try self.createSimpleEmbedding(new_label);
        defer self.allocator.free(embedding);
        const vector = types.Vector.init(memory_id, embedding);
        self.db.insertVector(vector) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Failed to update memory vector: {any}", .{err});
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
            "Old content: \"{s}\"\n", .{old_label});
        defer self.allocator.free(old_info);
        try content_list.appendSlice(old_info);
        
        const new_info = try std.fmt.allocPrint(self.allocator, 
            "New content: \"{s}\"\n\n", .{new_label});
        defer self.allocator.free(new_info);
        try content_list.appendSlice(new_info);
        
        const vector_info = try std.fmt.allocPrint(self.allocator, 
            "• Updated vector embedding: {} dimensions\n", .{embedding.len});
        defer self.allocator.free(vector_info);
        try content_list.appendSlice(vector_info);
        
        if (created_concepts.items.len > 0) {
            const concepts_info = try std.fmt.allocPrint(self.allocator, 
                "• Extracted {} new concepts: ", .{created_concepts.items.len});
            defer self.allocator.free(concepts_info);
            try content_list.appendSlice(concepts_info);
            
            for (concepts.items, 0..) |concept, i| {
                if (i > 0) try content_list.appendSlice(", ");
                try content_list.appendSlice("\"");
                try content_list.appendSlice(concept);
                try content_list.appendSlice("\"");
            }
            try content_list.appendSlice("\n");
            
            const relationships_count = created_concepts.items.len + (created_concepts.items.len * (created_concepts.items.len - 1) / 2);
            const relationships_info = try std.fmt.allocPrint(self.allocator, 
                "• Created {} new semantic relationships\n", .{relationships_count});
            defer self.allocator.free(relationships_info);
            try content_list.appendSlice(relationships_info);
        }
        
        // Clean up any orphaned concepts from the old relationships
        const orphaned_concepts = try self.cleanupOrphanedConcepts();
        if (orphaned_concepts > 0) {
            const cleanup_info = try std.fmt.allocPrint(self.allocator, 
                "• Cleaned up {} orphaned concept nodes from old relationships\n", .{orphaned_concepts});
            defer self.allocator.free(cleanup_info);
            try content_list.appendSlice(cleanup_info);
        }
        
        try content_list.appendSlice("\nMemory has been updated and is ready for semantic search!");
        
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
        
        // Check if the memory exists and get its label for reporting
        const existing_node = self.db.graph_index.getNode(memory_id) orelse {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Memory {} not found", .{memory_id});
            defer self.allocator.free(error_msg);
            return self.createErrorResponse(id, JsonRpcError.INVALID_PARAMS, error_msg, null);
        };
        
        const memory_label = existing_node.getLabelAsString();
        
        // Count relationships before deletion for reporting
        var deleted_edges: u32 = 0;
        var orphaned_concepts: u32 = 0;
        
        // Clean up all relationships
        deleted_edges = try self.cleanupMemoryRelationships(memory_id);
        
        // Check for orphaned concept nodes and clean them up
        orphaned_concepts = try self.cleanupOrphanedConcepts();
        
        // Remove the memory node itself
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
            "Forgotten memory: \"{s}\"\n\n", .{memory_label});
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
}; 