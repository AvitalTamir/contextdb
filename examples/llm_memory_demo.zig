const std = @import("std");
const memora = @import("memora");

const Memora = memora.Memora;
const MemoryManager = memora.memory_manager.MemoryManager;
const Memory = memora.memory_types.Memory;
const MemoryType = memora.memory_types.MemoryType;
const MemoryRelationType = memora.memory_types.MemoryRelationType;
const MemoryConfidence = memora.memory_types.MemoryConfidence;
const MemoryImportance = memora.memory_types.MemoryImportance;
const MemorySource = memora.memory_types.MemorySource;
const MemoryQuery = memora.memory_types.MemoryQuery;

/// LLM Memory Demo - Shows how LLMs can store and retrieve semantic memories
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Memora database
    const config = memora.MemoraConfig{
        .data_path = "llm_memory_demo_data",
        .enable_persistent_indexes = false, // Faster for demo
    };

    var db = try Memora.init(allocator, config, null);
    defer db.deinit();

    // Initialize Memory Manager
    var memory_manager = MemoryManager.init(allocator, &db);
    defer memory_manager.deinit();

    std.debug.print("🧠 LLM Memory System Demo\n", .{});
    std.debug.print("========================\n\n", .{});

    // Simulate LLM conversation scenario
    try simulateLLMConversation(&memory_manager);
    
    // Show memory statistics
    try showMemoryStatistics(&memory_manager);
}

/// Simulate an LLM storing memories during a conversation
fn simulateLLMConversation(memory_manager: *MemoryManager) !void {
    std.debug.print("📝 Simulating LLM Conversation Memory Storage\n", .{});
    std.debug.print("----------------------------------------------\n", .{});

    // Create a conversation session
    const session_id = try memory_manager.createSession(1, "Programming Help Session", "User learning Zig");
    std.debug.print("Created session: {}\n", .{session_id});

    // Store different types of memories as the conversation progresses
    std.debug.print("\n🔹 Storing user preference...\n", .{});
    const pref_id = try memory_manager.storeMemory(
        MemoryType.preference,
        "User prefers concise code examples with explanations",
        .{
            .confidence = MemoryConfidence.high,
            .importance = MemoryImportance.high,
            .source = MemorySource.user_input,
            .session_id = session_id,
            .user_id = 1,
        }
    );
    std.debug.print("Stored user preference (ID: {})\n", .{pref_id});

    std.debug.print("\n🔹 Storing contextual information...\n", .{});
    const context_id = try memory_manager.storeMemory(
        MemoryType.context,
        "User is working on a Zig memory management project",
        .{
            .confidence = MemoryConfidence.high,
            .importance = MemoryImportance.medium,
            .source = MemorySource.llm_inference,
            .session_id = session_id,
            .user_id = 1,
        }
    );
    std.debug.print("Stored context (ID: {})\n", .{context_id});

    std.debug.print("\n🔹 Storing learned fact...\n", .{});
    const fact_id = try memory_manager.storeMemory(
        MemoryType.fact,
        "User's skill level: intermediate in general programming, beginner in Zig",
        .{
            .confidence = MemoryConfidence.medium,
            .importance = MemoryImportance.high,
            .source = MemorySource.llm_inference,
            .session_id = session_id,
            .user_id = 1,
        }
    );
    std.debug.print("Stored skill assessment (ID: {})\n", .{fact_id});

    std.debug.print("\n🔹 Storing successful experience...\n", .{});
    const exp_id = try memory_manager.storeMemory(
        MemoryType.experience,
        "Successfully helped user understand Zig allocators using simple examples",
        .{
            .confidence = MemoryConfidence.high,
            .importance = MemoryImportance.high,
            .source = MemorySource.system_observation,
            .session_id = session_id,
            .user_id = 1,
        }
    );
    std.debug.print("Stored successful experience (ID: {})\n", .{exp_id});

    std.debug.print("\n🔹 Storing decision pattern...\n", .{});
    const decision_id = try memory_manager.storeMemory(
        MemoryType.decision,
        "When user asks complex questions, start with simple examples then add detail",
        .{
            .confidence = MemoryConfidence.medium,
            .importance = MemoryImportance.high,
            .source = MemorySource.llm_inference,
            .session_id = session_id,
            .user_id = 1,
        }
    );
    std.debug.print("Stored decision pattern (ID: {})\n", .{decision_id});

    // Create relationships between memories
    std.debug.print("\n🔗 Creating memory relationships...\n", .{});
    
    // User preference supports the decision pattern
    try memory_manager.createRelationship(pref_id, decision_id, MemoryRelationType.supports, .{});
    std.debug.print("Linked preference to decision pattern (supports)\n", .{});

    // Context and skill level co-occurred in the same session
    try memory_manager.createRelationship(context_id, fact_id, MemoryRelationType.co_occurred, .{});
    std.debug.print("Linked context to skill assessment (co-occurred)\n", .{});

    // Successful experience validates the decision pattern
    try memory_manager.createRelationship(exp_id, decision_id, MemoryRelationType.supports, .{});
    std.debug.print("Linked experience to decision pattern (supports)\n", .{});

    // Preference and experience are related through user satisfaction
    try memory_manager.createRelationship(pref_id, exp_id, MemoryRelationType.caused_by, .{});
    std.debug.print("Linked preference to experience (caused by)\n", .{});

    std.debug.print("\n✅ Memory storage simulation complete!\n\n", .{});

    // Demonstrate memory retrieval
    try demonstrateMemoryRetrieval(memory_manager, session_id);
}

/// Demonstrate how an LLM would query memories
fn demonstrateMemoryRetrieval(memory_manager: *MemoryManager, session_id: u64) !void {
    std.debug.print("🔍 Demonstrating Memory Retrieval\n", .{});
    std.debug.print("----------------------------------\n", .{});

    // Query 1: Get all memories for this user session
    std.debug.print("🔹 Query: All memories for current session\n", .{});
    var session_query = MemoryQuery.init();
    session_query.session_id = session_id;
    session_query.include_related = true;
    session_query.limit = 10;

    var session_results = try memory_manager.queryMemories(session_query);
    defer session_results.deinit();

    std.debug.print("Found {} memories in session:\n", .{session_results.memories.items.len});
    for (session_results.memories.items, 0..) |memory, i| {
        std.debug.print("  {}. {} (Type: {s}, Confidence: {s}): \"{s}\"\n", 
            .{ i + 1, memory.id, @tagName(memory.memory_type), @tagName(memory.confidence), memory.getContentAsString() });
    }

    if (session_results.related_memories.items.len > 0) {
        std.debug.print("Related memories: {}\n", .{session_results.related_memories.items.len});
    }
    if (session_results.relationships.items.len > 0) {
        std.debug.print("Relationships found: {}\n", .{session_results.relationships.items.len});
    }

    // Query 2: Get high-importance memories only
    std.debug.print("\n🔹 Query: High-importance memories only\n", .{});
    var importance_query = MemoryQuery.init();
    importance_query.min_importance = MemoryImportance.high;
    importance_query.session_id = session_id;
    importance_query.limit = 5;

    var importance_results = try memory_manager.queryMemories(importance_query);
    defer importance_results.deinit();

    std.debug.print("Found {} high-importance memories:\n", .{importance_results.memories.items.len});
    for (importance_results.memories.items, 0..) |memory, i| {
        std.debug.print("  {}. {}: \"{s}\"\n", 
            .{ i + 1, memory.id, memory.getContentAsString() });
    }

    // Query 3: Get only user preferences
    std.debug.print("\n🔹 Query: User preferences only\n", .{});
    var pref_query = MemoryQuery.init();
    const pref_types = [_]MemoryType{MemoryType.preference};
    pref_query.memory_types = &pref_types;
    pref_query.session_id = session_id;
    pref_query.limit = 5;

    var pref_results = try memory_manager.queryMemories(pref_query);
    defer pref_results.deinit();

    std.debug.print("Found {} user preferences:\n", .{pref_results.memories.items.len});
    for (pref_results.memories.items, 0..) |memory, i| {
        std.debug.print("  {}. {}: \"{s}\"\n", 
            .{ i + 1, memory.id, memory.getContentAsString() });
    }

    std.debug.print("\n✅ Memory retrieval demonstration complete!\n\n", .{});
}

/// Show comprehensive memory statistics
fn showMemoryStatistics(memory_manager: *MemoryManager) !void {
    std.debug.print("📊 Memory System Statistics\n", .{});
    std.debug.print("---------------------------\n", .{});

    const stats = try memory_manager.getStatistics();

    std.debug.print("Memory Distribution by Type:\n", .{});
    const type_names = [_][]const u8{
        "Experience", "Concept", "Fact", "Decision", "Observation",
        "Preference", "Context", "Skill", "Intention", "Emotion"
    };
    
    for (stats.memory_counts_by_type, 0..) |count, i| {
        if (count > 0 and i < type_names.len) {
            std.debug.print("  {s}: {} memories\n", .{ type_names[i], count });
        }
    }

    std.debug.print("\nConfidence Distribution:\n", .{});
    const conf_names = [_][]const u8{ "Very Low", "Low", "Medium", "High", "Very High" };
    for (stats.confidence_distribution, 0..) |count, i| {
        if (count > 0 and i < conf_names.len) {
            std.debug.print("  {s}: {} memories\n", .{ conf_names[i], count });
        }
    }

    std.debug.print("\nImportance Distribution:\n", .{});
    const imp_names = [_][]const u8{ "Trivial", "Low", "Medium", "High", "Critical" };
    for (stats.importance_distribution, 0..) |count, i| {
        if (count > 0 and i < imp_names.len) {
            std.debug.print("  {s}: {} memories\n", .{ imp_names[i], count });
        }
    }

    std.debug.print("\nSession & Relationship Statistics:\n", .{});
    std.debug.print("  Active sessions: {}\n", .{stats.active_sessions});
    std.debug.print("  Total relationships: {}\n", .{stats.total_relationships});
    std.debug.print("  Most common relation: {s}\n", .{@tagName(stats.most_common_relation_type)});

    std.debug.print("\n🎯 Memory system is ready for LLM operations!\n", .{});
} 