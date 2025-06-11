const std = @import("std");
const types = @import("types.zig");
const memory_types = @import("memory_types.zig");
const main = @import("main.zig");

const Memora = main.Memora;
const Memory = memory_types.Memory;
const MemoryType = memory_types.MemoryType;
const MemoryRelation = memory_types.MemoryRelation;
const MemoryRelationType = memory_types.MemoryRelationType;
const MemorySession = memory_types.MemorySession;
const MemoryQuery = memory_types.MemoryQuery;
const MemoryQueryResult = memory_types.MemoryQueryResult;
const MemoryStatistics = memory_types.MemoryStatistics;
const MemoryConfidence = memory_types.MemoryConfidence;
const MemoryImportance = memory_types.MemoryImportance;
const MemorySource = memory_types.MemorySource;

/// High-level memory manager for LLM operations
/// Provides semantic memory operations built on Memora's infrastructure
pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    memora: *Memora,
    
    // Memory content storage (memory ID -> content mapping)
    memory_content: std.AutoHashMap(u64, []u8),
    
    // Session management
    sessions: std.AutoHashMap(u64, MemorySession),
    current_session_id: u64,
    
    // Memory ID generation
    next_memory_id: u64,
    next_session_id: u64,
    
    // Embedding cache for semantic search
    embedding_cache: std.AutoHashMap(u64, [128]f32),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, memora: *Memora) Self {
        var manager = Self{
            .allocator = allocator,
            .memora = memora,
            .memory_content = std.AutoHashMap(u64, []u8).init(allocator),
            .sessions = std.AutoHashMap(u64, MemorySession).init(allocator),
            .current_session_id = 0,
            .next_memory_id = 1,
            .next_session_id = 1,
            .embedding_cache = std.AutoHashMap(u64, [128]f32).init(allocator),
        };
        
        // Load existing memory content from the log
        manager.loadExistingMemories() catch {
            // If we can't load existing memories, continue with empty state
            std.debug.print("Warning: Failed to load existing memories from log\n", .{});
        };
        
        return manager;
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up memory content strings
        var content_iter = self.memory_content.iterator();
        while (content_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory_content.deinit();
        
        self.sessions.deinit();
        self.embedding_cache.deinit();
    }
    
    /// Store a new memory with LLM-specific metadata
    pub fn storeMemory(self: *Self, memory_type: MemoryType, content: []const u8, options: struct {
        confidence: ?MemoryConfidence = null,
        importance: ?MemoryImportance = null,
        source: ?MemorySource = null,
        session_id: ?u64 = null,
        user_id: ?u64 = null,
        create_embedding: bool = true,
    }) !u64 {
        const memory_id = self.next_memory_id;
        self.next_memory_id += 1;
        
        // Create memory with metadata
        var memory = Memory.init(memory_id, memory_type, content);
        
        // Apply options
        if (options.confidence) |conf| memory.confidence = conf;
        if (options.importance) |imp| memory.importance = imp;
        if (options.source) |src| memory.source = src;
        if (options.session_id) |sid| memory.session_id = sid;
        if (options.user_id) |uid| memory.user_id = uid;
        
        // Store full content in the log for persistence (Node label is limited to 32 bytes)
        const content_log_entry = types.LogEntry.initMemoryContent(memory_id, content);
        try self.memora.append_log.append(content_log_entry);
        
        // Also store in in-memory cache for fast access
        const content_copy = try self.allocator.dupe(u8, content);
        try self.memory_content.put(memory_id, content_copy);
        
        // Convert to Node and store in underlying database
        const node = memory.toNode();
        try self.memora.insertNode(node);
        
        // Create semantic embedding if requested
        if (options.create_embedding) {
            const embedding = try self.generateEmbedding(content);
            const vector = types.Vector.init(memory_id, &embedding);
            try self.memora.insertVector(vector);
            try self.embedding_cache.put(memory_id, embedding);
        }
        
        // If this memory belongs to current session, update session activity
        if (options.session_id) |sid| {
            if (self.sessions.getPtr(sid)) |session| {
                                 session.last_active = @as(u64, @intCast(std.time.timestamp()));
                session.interaction_count += 1;
            }
        }
        
        return memory_id;
    }
    
    /// Create a relationship between two memories
    pub fn createRelationship(self: *Self, from_memory_id: u64, to_memory_id: u64, relation_type: MemoryRelationType, options: struct {
        strength: ?f32 = null,
        source: ?MemorySource = null,
    }) !void {
        var relation = MemoryRelation.init(from_memory_id, to_memory_id, relation_type);
        
        if (options.strength) |strength| relation.strength = strength;
        if (options.source) |source| relation.created_by = source;
        
        const edge = relation.toEdge();
        try self.memora.insertEdge(edge);
    }
    
    /// Retrieve memories based on query criteria
    pub fn queryMemories(self: *Self, query: MemoryQuery) !MemoryQueryResult {
        const start_time = std.time.nanoTimestamp();
        var result = MemoryQueryResult.init(self.allocator);
        
        // Vector-based semantic search if query text is provided
        if (query.query_text) |text| {
            try self.performSemanticSearch(&result, text, query);
        }
        
        // Graph-based filtering and traversal
        try self.performGraphSearch(&result, query);
        
        // Apply filters
        try self.applyFilters(&result, query);
        
        // Include related memories if requested
        if (query.include_related) {
            try self.includeRelatedMemories(&result, query);
        }
        
        // Sort and limit results
        try self.sortAndLimitResults(&result, query);
        
        const end_time = std.time.nanoTimestamp();
        result.execution_time_ms = @intCast(@divTrunc(end_time - start_time, 1_000_000));
        
        return result;
    }
    
    /// Retrieve a specific memory by ID
    pub fn getMemory(self: *Self, memory_id: u64) !?Memory {
        // Get the node from underlying database
        const node = self.memora.graph_index.getNode(memory_id) orelse return null;
        
        // Get the full content from cache or load from log
        var content = self.memory_content.get(memory_id);
        if (content == null) {
            // Content not in cache, try to load from log
            if (try self.loadContentFromLog(memory_id)) |log_content| {
                // Cache the loaded content
                const content_copy = try self.allocator.dupe(u8, log_content);
                try self.memory_content.put(memory_id, content_copy);
                content = self.memory_content.get(memory_id);
            }
        }
        
        const final_content = content orelse return null;
        
        // Reconstruct memory
        var memory = Memory.fromNode(node, final_content);
        
        // Update access tracking
        memory.markAccessed();
        
        // Update the node in the database with new access info
        const updated_node = memory.toNode();
        try self.memora.insertNode(updated_node); // This will overwrite existing
        
        return memory;
    }
    
    /// Create a new conversation session
    pub fn createSession(self: *Self, user_id: u64, title: []const u8, context: ?[]const u8) !u64 {
        const session_id = self.next_session_id;
        self.next_session_id += 1;
        
        var session = MemorySession.init(session_id, user_id, title);
        
        if (context) |ctx| {
            const copy_len = @min(ctx.len, 256);
            @memcpy(session.context[0..copy_len], ctx[0..copy_len]);
        }
        
        try self.sessions.put(session_id, session);
        self.current_session_id = session_id;
        
        return session_id;
    }
    
    /// Set the current active session
    pub fn setCurrentSession(self: *Self, session_id: u64) void {
        self.current_session_id = session_id;
    }
    
    /// Get current session information
    pub fn getCurrentSession(self: *Self) ?MemorySession {
        return self.sessions.get(self.current_session_id);
    }
    
    /// Update a memory's content and metadata
    pub fn updateMemory(self: *Self, memory_id: u64, new_content: ?[]const u8, updates: struct {
        confidence: ?MemoryConfidence = null,
        importance: ?MemoryImportance = null,
        memory_type: ?MemoryType = null,
    }) !void {
        // Get existing memory
        var memory = (try self.getMemory(memory_id)) orelse return error.MemoryNotFound;
        
        // Apply updates
        if (updates.confidence) |conf| memory.confidence = conf;
        if (updates.importance) |imp| memory.importance = imp;
        if (updates.memory_type) |mt| memory.memory_type = mt;
        
        // Update content if provided
        if (new_content) |content| {
            // Free old content and store new
            if (self.memory_content.get(memory_id)) |old_content| {
                self.allocator.free(old_content);
            }
            
            const content_copy = try self.allocator.dupe(u8, content);
            try self.memory_content.put(memory_id, content_copy);
            
            // Update memory content array
            const copy_len = @min(content.len, 256);
            @memset(memory.content[0..], 0);
            @memcpy(memory.content[0..copy_len], content[0..copy_len]);
            
            // Regenerate embedding
            const embedding = try self.generateEmbedding(content);
            const vector = types.Vector.init(memory_id, &embedding);
            try self.memora.insertVector(vector);
            try self.embedding_cache.put(memory_id, embedding);
        }
        
        // Increment version
        memory.version += 1;
        
        // Store updated memory
        const node = memory.toNode();
        try self.memora.insertNode(node);
    }
    
    /// Delete a memory and its relationships
    pub fn forgetMemory(self: *Self, memory_id: u64) !void {
        // Free stored content
        if (self.memory_content.get(memory_id)) |content| {
            self.allocator.free(content);
            _ = self.memory_content.remove(memory_id);
        }
        
        // Remove from embedding cache
        _ = self.embedding_cache.remove(memory_id);
        
        // TODO: Remove from underlying Memora database
        // This would need new functionality in Memora to delete nodes/edges/vectors
        // For now, we just mark it as forgotten in our layer
    }
    
    /// Get comprehensive memory statistics
    pub fn getStatistics(self: *Self) !MemoryStatistics {
        var stats = MemoryStatistics.init();
        
        // Count memories by type
        var node_iter = self.memora.graph_index.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            
            // Decode memory type from node label
            const memory_type: MemoryType = @enumFromInt(node.label[0]);
            const type_index = @intFromEnum(memory_type);
            if (type_index < stats.memory_counts_by_type.len) {
                stats.memory_counts_by_type[type_index] += 1;
            }
            
            // Decode confidence
            const confidence: MemoryConfidence = @enumFromInt(node.label[1]);
            const conf_index = @intFromEnum(confidence);
            if (conf_index < stats.confidence_distribution.len) {
                stats.confidence_distribution[conf_index] += 1;
            }
            
            // Decode importance
            const importance: MemoryImportance = @enumFromInt(node.label[2]);
            const imp_index = @intFromEnum(importance);
            if (imp_index < stats.importance_distribution.len) {
                stats.importance_distribution[imp_index] += 1;
            }
        }
        
        // Count active sessions
        var session_iter = self.sessions.iterator();
        while (session_iter.next()) |entry| {
            if (entry.value_ptr.is_active) {
                stats.active_sessions += 1;
            }
        }
        
        // Count relationships
        var edge_iter = self.memora.graph_index.outgoing_edges.iterator();
        while (edge_iter.next()) |entry| {
            stats.total_relationships += entry.value_ptr.items.len;
        }
        
        return stats;
    }
    
    // Private helper methods
    
    fn performSemanticSearch(self: *Self, result: *MemoryQueryResult, query_text: []const u8, query: MemoryQuery) !void {
        // Generate embedding for the query text
        const query_embedding = try self.generateEmbedding(query_text);
        
        // Create temporary vector for similarity search
        const query_vector = types.Vector.init(0, &query_embedding); // ID 0 for query vector
        
        // Find similar vectors using the query vector
        const similar_results = try self.memora.vector_search.querySimilarByVector(&self.memora.vector_index, query_vector, @intCast(query.limit));
        defer similar_results.deinit();
        
        // Convert similarity results to memories
        for (similar_results.items) |sim_result| {
            if (try self.getMemory(sim_result.id)) |memory| {
                try result.memories.append(memory);
                try result.similarity_scores.append(sim_result.similarity);
            }
        }
        
        result.total_matches = @intCast(similar_results.items.len);
    }
    
    fn performGraphSearch(self: *Self, result: *MemoryQueryResult, _: MemoryQuery) !void {
        // If we don't have semantic results yet, get all memories and filter
        if (result.memories.items.len == 0) {
            var node_iter = self.memora.graph_index.nodes.iterator();
            while (node_iter.next()) |entry| {
                const node = entry.value_ptr.*;
                if (try self.getMemory(node.id)) |memory| {
                    try result.memories.append(memory);
                }
            }
        }
    }
    
    fn applyFilters(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        _ = self;
        
        // Filter by memory types
        if (query.memory_types) |types_filter| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                for (types_filter) |allowed_type| {
                    if (memory.memory_type == allowed_type) {
                        try filtered.append(memory);
                        break;
                    }
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by confidence
        if (query.min_confidence) |min_conf| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (@intFromEnum(memory.confidence) >= @intFromEnum(min_conf)) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by importance
        if (query.min_importance) |min_imp| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (@intFromEnum(memory.importance) >= @intFromEnum(min_imp)) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by session
        if (query.session_id) |session_id| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (memory.session_id == session_id) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
        
        // Filter by user
        if (query.user_id) |user_id| {
            var filtered = std.ArrayList(Memory).init(result.memories.allocator);
            for (result.memories.items) |memory| {
                if (memory.user_id == user_id) {
                    try filtered.append(memory);
                }
            }
            result.memories.deinit();
            result.memories = filtered;
        }
    }
    
    fn includeRelatedMemories(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        // For each memory in results, find related memories
        for (result.memories.items) |memory| {
            const related_nodes = try self.memora.queryRelated(memory.id, query.max_depth);
            defer related_nodes.deinit();
            
            for (related_nodes.items) |node| {
                if (node.id != memory.id) { // Don't include the original memory
                    if (try self.getMemory(node.id)) |related_memory| {
                        try result.related_memories.append(related_memory);
                    }
                }
            }
            
            // Get edges for relationships - we need to query the graph directly
            if (self.memora.graph_index.getOutgoingEdges(memory.id)) |edges| {
                for (edges) |edge| {
                    const relation = MemoryRelation.fromEdge(edge);
                    try result.relationships.append(relation);
                }
            }
        }
    }
    
    fn sortAndLimitResults(self: *Self, result: *MemoryQueryResult, query: MemoryQuery) !void {
        _ = self;
        
        // Limit results
        if (result.memories.items.len > query.limit) {
            result.memories.shrinkAndFree(query.limit);
        }
        
        if (result.similarity_scores.items.len > query.limit) {
            result.similarity_scores.shrinkAndFree(query.limit);
        }
    }
    
    /// Load memory content from log by scanning for memory_content entries
    fn loadContentFromLog(self: *Self, memory_id: u64) !?[]const u8 {
        var iter = self.memora.append_log.iterator();
        
        // Scan through log entries to find the content for this memory ID
        while (iter.next()) |entry| {
            if (entry.getEntryType() == .memory_content) {
                if (entry.asMemoryContent()) |mem_content| {
                    if (mem_content.memory_id == memory_id) {
                        return mem_content.content;
                    }
                }
            }
        }
        
        return null;
    }

    fn generateEmbedding(self: *Self, content: []const u8) !([128]f32) {
        _ = self;
        
        // Simplified embedding generation for now
        // In production, this would use a real embedding model
        var embedding = [_]f32{0.0} ** 128;
        
        // Simple hash-based embedding
        var hash: u64 = 0;
        for (content) |byte| {
            hash = hash *% 31 +% byte;
        }
        
        // Convert hash to normalized embedding
        var prng = std.Random.DefaultPrng.init(hash);
        const random = prng.random();
        
        for (&embedding) |*dim| {
            dim.* = random.float(f32) * 2.0 - 1.0; // Range [-1, 1]
        }
        
        // Normalize
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
        
        return embedding;
    }
    
    /// Load existing memory content from the log and snapshots during initialization
    pub fn loadExistingMemories(self: *Self) !void {
        var max_memory_id: u64 = 0;
        
        // First try to load from the latest snapshot if available
        if (try self.memora.snapshot_manager.loadLatestSnapshot()) |snapshot_info| {
            defer snapshot_info.deinit();
            
            if (snapshot_info.memory_content_files.items.len > 0) {
                const memory_contents = try self.memora.snapshot_manager.loadMemoryContents(&snapshot_info);
                defer {
                    // Free the allocated content strings
                    for (memory_contents.items) |memory_content| {
                        self.allocator.free(memory_content.content);
                    }
                    memory_contents.deinit();
                }
                
                // Load memory contents from snapshot
                for (memory_contents.items) |memory_content| {
                    const content_copy = try self.allocator.dupe(u8, memory_content.content);
                    try self.memory_content.put(memory_content.memory_id, content_copy);
                    max_memory_id = @max(max_memory_id, memory_content.memory_id);
                }
                
                std.debug.print("Loaded {} memories from snapshot\n", .{memory_contents.items.len});
            }
        }
        
        // Then load any additional memory content entries from log
        var iter = self.memora.append_log.iterator();
        while (iter.next()) |entry| {
            if (entry.getEntryType() == .memory_content) {
                if (entry.asMemoryContent()) |mem_content| {
                    // Only add if we don't already have this memory ID from snapshot
                    if (!self.memory_content.contains(mem_content.memory_id)) {
                        const content_copy = try self.allocator.dupe(u8, mem_content.content);
                        try self.memory_content.put(mem_content.memory_id, content_copy);
                    }
                    
                    // Track the maximum memory ID
                    max_memory_id = @max(max_memory_id, mem_content.memory_id);
                }
            }
        }
        
        // Final pass: reconstruct content for memory nodes that exist but don't have content entries
        // This handles the case where snapshots were created and log was cleared
        try self.loadMemoriesFromLoadedNodes(max_memory_id);
        
        // Set the next memory ID to be one higher than the maximum found
        if (max_memory_id > 0) {
            self.next_memory_id = max_memory_id + 1;
        }
        
        std.debug.print("Loaded {} total memories, next ID: {}\n", .{ self.memory_content.count(), self.next_memory_id });
    }
    
    /// Load memory contents from snapshot data during database restoration
    pub fn loadMemoryContentsFromSnapshot(self: *Self, memory_contents: []const types.MemoryContent) !void {
        var max_memory_id: u64 = 0;
        
        // Clear existing content cache
        var iterator = self.memory_content.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory_content.clearAndFree();
        
        // Load memory contents from snapshot
        for (memory_contents) |memory_content| {
            const content_copy = try self.allocator.dupe(u8, memory_content.content);
            try self.memory_content.put(memory_content.memory_id, content_copy);
            max_memory_id = @max(max_memory_id, memory_content.memory_id);
        }
        
        // Update next_memory_id to prevent ID collisions
        if (max_memory_id > 0) {
            self.next_memory_id = max_memory_id + 1;
        }
        
        std.debug.print("Loaded {} memory contents from snapshot, next ID: {}\n", .{ memory_contents.len, self.next_memory_id });
    }
    
    /// Reconstruct memory content from nodes that were loaded from snapshots
    /// but don't have corresponding memory_content entries in the log
    fn loadMemoriesFromLoadedNodes(self: *Self, max_memory_id: u64) !void {
        _ = max_memory_id; // Mark unused
        var node_iter = self.memora.graph_index.nodes.iterator();
        
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr.*;
            const node_id = node.id;
            
            // Skip if we already have content for this memory ID
            if (self.memory_content.contains(node_id)) continue;
            
            // Check if this looks like a memory node by examining the label structure
            // Memory nodes have structured metadata in their label
            if (node.label[0] < 10 and node.label[1] < 5 and node.label[2] < 5 and node.label[3] < 6) {
                // This looks like a memory node - create a placeholder content string
                // since we can't recover the full original content from snapshots
                const placeholder_content = try std.fmt.allocPrint(self.allocator, "[Recovered memory ID {}]", .{node_id});
                try self.memory_content.put(node_id, placeholder_content);
                
                std.debug.print("Reconstructed memory {} from snapshot (content unavailable)\n", .{node_id});
            }
        }
    }
};

// Tests
test "MemoryManager basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_memory_manager") catch {};
    defer std.fs.cwd().deleteTree("test_memory_manager") catch {};
    
    // Create test database
    const config = main.MemoraConfig{
        .data_path = "test_memory_manager",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };
    
    var memora_db = try Memora.init(allocator, config, null);
    defer memora_db.deinit();
    
    // Create memory manager
    var memory_manager = MemoryManager.init(allocator, &memora_db);
    defer memory_manager.deinit();
    
    // Store a memory
    const memory_id = try memory_manager.storeMemory(
        MemoryType.experience,
        "User prefers concise explanations",
        .{ .confidence = MemoryConfidence.high, .importance = MemoryImportance.high }
    );
    
    try std.testing.expect(memory_id == 1);
    
    // Retrieve the memory
    const retrieved = try memory_manager.getMemory(memory_id);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.memory_type == MemoryType.experience);
    try std.testing.expect(retrieved.?.confidence == MemoryConfidence.high);
    
    // Create a relationship
    const memory_id2 = try memory_manager.storeMemory(
        MemoryType.preference,
        "User likes technical details",
        .{}
    );
    
    try memory_manager.createRelationship(memory_id, memory_id2, MemoryRelationType.similar_to, .{});
    
    // Query memories
    var query = MemoryQuery.init();
    query.memory_types = &[_]MemoryType{MemoryType.experience};
    query.include_related = true;
    
    var results = try memory_manager.queryMemories(query);
    defer results.deinit();
    
    try std.testing.expect(results.memories.items.len >= 1);
}

test "MemoryManager session management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Clean up test data
    std.fs.cwd().deleteTree("test_memory_sessions") catch {};
    defer std.fs.cwd().deleteTree("test_memory_sessions") catch {};
    
    // Create test database
    const config = main.MemoraConfig{
        .data_path = "test_memory_sessions",
        .auto_snapshot_interval = 100,
        .enable_persistent_indexes = false,
    };
    
    var memora_db = try Memora.init(allocator, config, null);
    defer memora_db.deinit();
    
    // Create memory manager
    var memory_manager = MemoryManager.init(allocator, &memora_db);
    defer memory_manager.deinit();
    
    // Create a session
    const session_id = try memory_manager.createSession(1, "Programming Help", "User learning Zig");
    try std.testing.expect(session_id == 1);
    
    // Get current session
    const session = memory_manager.getCurrentSession();
    try std.testing.expect(session != null);
    try std.testing.expectEqualStrings("Programming Help", session.?.getTitleAsString());
    
    // Store memory in session
    const memory_id = try memory_manager.storeMemory(
        MemoryType.context,
        "User is learning Zig programming",
        .{ .session_id = session_id }
    );
    
    try std.testing.expect(memory_id == 1);
    
    // Verify memory is associated with session
    const memory = try memory_manager.getMemory(memory_id);
    try std.testing.expect(memory.?.session_id == session_id);
} 