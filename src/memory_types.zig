const std = @import("std");
const types = @import("types.zig");

/// LLM Memory Data Models
/// These types provide semantic meaning for LLM memory operations,
/// building on the foundational Node/Edge/Vector infrastructure.

/// Types of memories that LLMs can store and retrieve
pub const MemoryType = enum(u8) {
    /// Direct experiences from interactions
    experience = 0,
    /// Abstract concepts learned or referenced
    concept = 1,
    /// Facts or information about users, domains, or the world
    fact = 2,
    /// Decisions made or reasoning patterns
    decision = 3,
    /// Observations about patterns, behaviors, or phenomena
    observation = 4,
    /// User preferences and behavioral patterns
    preference = 5,
    /// Contextual information about conversations or sessions
    context = 6,
    /// Skills, capabilities, or learned procedures
    skill = 7,
    /// Goals, intentions, or planned actions
    intention = 8,
    /// Emotional or affective states and responses
    emotion = 9,
    _,
};

/// Confidence levels for memory reliability
pub const MemoryConfidence = enum(u8) {
    /// Very low confidence - might be incorrect
    very_low = 0,
    /// Low confidence - uncertain
    low = 1,
    /// Medium confidence - reasonably sure
    medium = 2,
    /// High confidence - very sure
    high = 3,
    /// Very high confidence - extremely certain
    very_high = 4,
    _,
};

/// Memory importance for retention decisions
pub const MemoryImportance = enum(u8) {
    /// Trivial - can be forgotten quickly
    trivial = 0,
    /// Low importance
    low = 1,
    /// Medium importance
    medium = 2,
    /// High importance - should be retained
    high = 3,
    /// Critical - must be retained long-term
    critical = 4,
    _,
};

/// Source of the memory for provenance tracking
pub const MemorySource = enum(u8) {
    /// Direct user input or conversation
    user_input = 0,
    /// LLM inference or reasoning
    llm_inference = 1,
    /// External knowledge base or tool
    external_tool = 2,
    /// System observation or monitoring
    system_observation = 3,
    /// Cross-session memory transfer
    memory_transfer = 4,
    /// Human curator or administrator
    human_curation = 5,
    _,
};

/// Enhanced memory structure for LLM-specific needs
pub const Memory = struct {
    /// Unique identifier for this memory
    id: u64,
    
    /// Type of memory (experience, concept, fact, etc.)
    memory_type: MemoryType,
    
    /// Human-readable description of the memory
    content: [256]u8, // Increased from Node's 32 bytes for richer content
    
    /// Confidence level in this memory's accuracy
    confidence: MemoryConfidence,
    
    /// Importance level for retention decisions
    importance: MemoryImportance,
    
    /// Source of this memory for provenance
    source: MemorySource,
    
    /// Timestamp when memory was created (Unix timestamp)
    created_at: u64,
    
    /// Timestamp when memory was last accessed (for LRU)
    last_accessed: u64,
    
    /// Number of times this memory has been accessed
    access_count: u32,
    
    /// Session ID where this memory was created
    session_id: u64,
    
    /// User ID this memory is associated with (0 for global)
    user_id: u64,
    
    /// Version number for memory updates
    version: u32,
    
    pub fn init(id: u64, memory_type: MemoryType, content: []const u8) Memory {
        var content_array = [_]u8{0} ** 256;
        const copy_len = @min(content.len, 256);
        @memcpy(content_array[0..copy_len], content[0..copy_len]);
        
        const now: u64 = @intCast(std.time.timestamp());
        
        return Memory{
            .id = id,
            .memory_type = memory_type,
            .content = content_array,
            .confidence = MemoryConfidence.medium,
            .importance = MemoryImportance.medium,
            .source = MemorySource.llm_inference,
            .created_at = now,
            .last_accessed = now,
            .access_count = 0,
            .session_id = 0,
            .user_id = 0,
            .version = 1,
        };
    }
    
    pub fn getContentAsString(self: *const Memory) []const u8 {
        var end: usize = 0;
        for (self.content) |byte| {
            if (byte == 0) break;
            end += 1;
        }
        return self.content[0..end];
    }
    
    /// Update access tracking when memory is retrieved
    pub fn markAccessed(self: *Memory) void {
        self.last_accessed = @as(u64, @intCast(std.time.timestamp()));
        self.access_count += 1;
    }
    
    /// Convert to underlying Node for storage
    pub fn toNode(self: *const Memory) types.Node {
        // Encode memory metadata into node label
        var label_buffer: [32]u8 = [_]u8{0} ** 32;
        
        // Pack metadata into label: [type:4][conf:4][imp:4][src:4][reserved:16]
        label_buffer[0] = @intFromEnum(self.memory_type);
        label_buffer[1] = @intFromEnum(self.confidence);
        label_buffer[2] = @intFromEnum(self.importance);
        label_buffer[3] = @intFromEnum(self.source);
        
        // Store version in bytes 4-7
        std.mem.writeInt(u32, label_buffer[4..8], self.version, .little);
        
        // Store session_id in bytes 8-15
        std.mem.writeInt(u64, label_buffer[8..16], self.session_id, .little);
        
        // Store user_id in bytes 16-23
        std.mem.writeInt(u64, label_buffer[16..24], self.user_id, .little);
        
        // Store access_count in bytes 24-27
        std.mem.writeInt(u32, label_buffer[24..28], self.access_count, .little);
        
        return types.Node{
            .id = self.id,
            .label = label_buffer,
        };
    }
    
    /// Create from underlying Node
    pub fn fromNode(node: types.Node, content: []const u8) Memory {
        const label = node.label;
        
        return Memory{
            .id = node.id,
            .memory_type = @enumFromInt(label[0]),
            .content = blk: {
                var content_array = [_]u8{0} ** 256;
                const copy_len = @min(content.len, 256);
                @memcpy(content_array[0..copy_len], content[0..copy_len]);
                break :blk content_array;
            },
            .confidence = @enumFromInt(label[1]),
            .importance = @enumFromInt(label[2]),
            .source = @enumFromInt(label[3]),
            .version = std.mem.readInt(u32, label[4..8], .little),
            .session_id = std.mem.readInt(u64, label[8..16], .little),
            .user_id = std.mem.readInt(u64, label[16..24], .little),
            .access_count = std.mem.readInt(u32, label[24..28], .little),
            .created_at = 0, // Will need to be loaded from metadata
            .last_accessed = 0, // Will need to be loaded from metadata
        };
    }
};

/// Types of relationships between memories
pub const MemoryRelationType = enum(u8) {
    /// One memory caused or led to another
    caused_by = 0,
    /// Memories are similar in content or context
    similar_to = 1,
    /// One memory contradicts another
    contradicts = 2,
    /// One memory supports or reinforces another
    supports = 3,
    /// Memories are part of the same conversation/session
    co_occurred = 4,
    /// One memory is an updated version of another
    replaces = 5,
    /// One memory references or mentions another
    references = 6,
    /// Temporal sequence - one happened before another
    precedes = 7,
    /// Conceptual hierarchy - one is a subset of another
    subset_of = 8,
    /// User preference or pattern relationship
    user_pattern = 9,
    _,
};

/// Enhanced edge for memory relationships
pub const MemoryRelation = struct {
    /// Source memory ID
    from_memory: u64,
    
    /// Target memory ID
    to_memory: u64,
    
    /// Type of relationship
    relation_type: MemoryRelationType,
    
    /// Strength of the relationship (0.0 to 1.0)
    strength: f32,
    
    /// When this relationship was discovered/created
    created_at: u64,
    
    /// Who or what created this relationship
    created_by: MemorySource,
    
    pub fn init(from: u64, to: u64, relation_type: MemoryRelationType) MemoryRelation {
        return MemoryRelation{
            .from_memory = from,
            .to_memory = to,
            .relation_type = relation_type,
            .strength = 1.0,
            .created_at = @as(u64, @intCast(std.time.timestamp())),
            .created_by = MemorySource.llm_inference,
        };
    }
    
    /// Convert to underlying Edge for storage
    pub fn toEdge(self: *const MemoryRelation) types.Edge {
        return types.Edge{
            .from = self.from_memory,
            .to = self.to_memory,
            .kind = @intFromEnum(self.relation_type),
        };
    }
    
    /// Create from underlying Edge
    pub fn fromEdge(edge: types.Edge) MemoryRelation {
        return MemoryRelation{
            .from_memory = edge.from,
            .to_memory = edge.to,
            .relation_type = @enumFromInt(edge.kind),
            .strength = 1.0, // Default strength
            .created_at = 0, // Will need to be loaded from metadata
            .created_by = MemorySource.llm_inference,
        };
    }
};

/// Session information for tracking conversations
pub const MemorySession = struct {
    /// Unique session identifier
    id: u64,
    
    /// User this session belongs to
    user_id: u64,
    
    /// When the session started
    started_at: u64,
    
    /// When the session last had activity
    last_active: u64,
    
    /// Session title or description
    title: [128]u8,
    
    /// Session context or purpose
    context: [256]u8,
    
    /// Number of interactions in this session
    interaction_count: u32,
    
    /// Whether the session is still active
    is_active: bool,
    
    pub fn init(id: u64, user_id: u64, title: []const u8) MemorySession {
        var title_array = [_]u8{0} ** 128;
        const copy_len = @min(title.len, 128);
        @memcpy(title_array[0..copy_len], title[0..copy_len]);
        
        const now: u64 = @intCast(std.time.timestamp());
        
        return MemorySession{
            .id = id,
            .user_id = user_id,
            .started_at = now,
            .last_active = now,
            .title = title_array,
            .context = [_]u8{0} ** 256,
            .interaction_count = 0,
            .is_active = true,
        };
    }
    
    pub fn getTitleAsString(self: *const MemorySession) []const u8 {
        var end: usize = 0;
        for (self.title) |byte| {
            if (byte == 0) break;
            end += 1;
        }
        return self.title[0..end];
    }
    
    pub fn getContextAsString(self: *const MemorySession) []const u8 {
        var end: usize = 0;
        for (self.context) |byte| {
            if (byte == 0) break;
            end += 1;
        }
        return self.context[0..end];
    }
};

/// Query parameters for memory retrieval
pub const MemoryQuery = struct {
    /// Text query for semantic search
    query_text: ?[]const u8,
    
    /// Memory types to filter by
    memory_types: ?[]const MemoryType,
    
    /// Minimum confidence level
    min_confidence: ?MemoryConfidence,
    
    /// Minimum importance level
    min_importance: ?MemoryImportance,
    
    /// Session ID to filter by
    session_id: ?u64,
    
    /// User ID to filter by
    user_id: ?u64,
    
    /// Time range for created_at
    created_after: ?u64,
    created_before: ?u64,
    
    /// Time range for last_accessed
    accessed_after: ?u64,
    accessed_before: ?u64,
    
    /// Maximum number of results
    limit: u32,
    
    /// Include related memories in results
    include_related: bool,
    
    /// Relationship types to follow when including related
    relation_types: ?[]const MemoryRelationType,
    
    /// Maximum depth for relationship traversal
    max_depth: u8,
    
    pub fn init() MemoryQuery {
        return MemoryQuery{
            .query_text = null,
            .memory_types = null,
            .min_confidence = null,
            .min_importance = null,
            .session_id = null,
            .user_id = null,
            .created_after = null,
            .created_before = null,
            .accessed_after = null,
            .accessed_before = null,
            .limit = 10,
            .include_related = false,
            .relation_types = null,
            .max_depth = 2,
        };
    }
};

/// Results from memory queries
pub const MemoryQueryResult = struct {
    /// Retrieved memories
    memories: std.ArrayList(Memory),
    
    /// Related memories (if requested)
    related_memories: std.ArrayList(Memory),
    
    /// Relationships between memories
    relationships: std.ArrayList(MemoryRelation),
    
    /// Similarity scores for vector-based queries
    similarity_scores: std.ArrayList(f32),
    
    /// Total number of matches (before limit applied)
    total_matches: u32,
    
    /// Query execution time in milliseconds
    execution_time_ms: u32,
    
    pub fn init(allocator: std.mem.Allocator) MemoryQueryResult {
        return MemoryQueryResult{
            .memories = std.ArrayList(Memory).init(allocator),
            .related_memories = std.ArrayList(Memory).init(allocator),
            .relationships = std.ArrayList(MemoryRelation).init(allocator),
            .similarity_scores = std.ArrayList(f32).init(allocator),
            .total_matches = 0,
            .execution_time_ms = 0,
        };
    }
    
    pub fn deinit(self: *MemoryQueryResult) void {
        self.memories.deinit();
        self.related_memories.deinit();
        self.relationships.deinit();
        self.similarity_scores.deinit();
    }
};

/// Statistics about memory usage for monitoring
pub const MemoryStatistics = struct {
    /// Total memories by type
    memory_counts_by_type: [std.enums.values(MemoryType).len]u64,
    
    /// Total memories by confidence level
    confidence_distribution: [std.enums.values(MemoryConfidence).len]u64,
    
    /// Total memories by importance level
    importance_distribution: [std.enums.values(MemoryImportance).len]u64,
    
    /// Active sessions count
    active_sessions: u32,
    
    /// Total users with memories
    total_users: u32,
    
    /// Average memories per user
    avg_memories_per_user: f32,
    
    /// Memory access patterns
    most_accessed_memory_id: u64,
    avg_access_count: f32,
    
    /// Relationship statistics
    total_relationships: u64,
    most_common_relation_type: MemoryRelationType,
    
    pub fn init() MemoryStatistics {
        return MemoryStatistics{
            .memory_counts_by_type = [_]u64{0} ** std.enums.values(MemoryType).len,
            .confidence_distribution = [_]u64{0} ** std.enums.values(MemoryConfidence).len,
            .importance_distribution = [_]u64{0} ** std.enums.values(MemoryImportance).len,
            .active_sessions = 0,
            .total_users = 0,
            .avg_memories_per_user = 0.0,
            .most_accessed_memory_id = 0,
            .avg_access_count = 0.0,
            .total_relationships = 0,
            .most_common_relation_type = MemoryRelationType.similar_to,
        };
    }
};

// Tests for memory types
test "Memory creation and conversion" {
    const memory = Memory.init(1, MemoryType.experience, "Test memory content");
    
    try std.testing.expect(memory.id == 1);
    try std.testing.expect(memory.memory_type == MemoryType.experience);
    try std.testing.expectEqualStrings("Test memory content", memory.getContentAsString());
    
    // Test conversion to/from Node
    const node = memory.toNode();
    try std.testing.expect(node.id == 1);
    
    const recovered_memory = Memory.fromNode(node, "Test memory content");
    try std.testing.expect(recovered_memory.id == 1);
    try std.testing.expect(recovered_memory.memory_type == MemoryType.experience);
}

test "MemoryRelation creation and conversion" {
    const relation = MemoryRelation.init(1, 2, MemoryRelationType.similar_to);
    
    try std.testing.expect(relation.from_memory == 1);
    try std.testing.expect(relation.to_memory == 2);
    try std.testing.expect(relation.relation_type == MemoryRelationType.similar_to);
    
    // Test conversion to/from Edge
    const edge = relation.toEdge();
    try std.testing.expect(edge.from == 1);
    try std.testing.expect(edge.to == 2);
    
    const recovered_relation = MemoryRelation.fromEdge(edge);
    try std.testing.expect(recovered_relation.from_memory == 1);
    try std.testing.expect(recovered_relation.to_memory == 2);
    try std.testing.expect(recovered_relation.relation_type == MemoryRelationType.similar_to);
}

test "MemoryQuery initialization" {
    const query = MemoryQuery.init();
    try std.testing.expect(query.limit == 10);
    try std.testing.expect(query.include_related == false);
    try std.testing.expect(query.max_depth == 2);
} 