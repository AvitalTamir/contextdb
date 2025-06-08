const std = @import("std");
const types = @import("types.zig");

/// Query Optimization Engine
/// Analyzes and optimizes query execution plans for maximum performance
/// Following TigerBeetle-style programming: deterministic, comprehensive, zero dependencies

/// Query execution statistics for optimization decisions
pub const QueryStats = struct {
    execution_time_ns: u64,
    nodes_examined: u32,
    edges_traversed: u32,
    vectors_compared: u32,
    cache_hits: u32,
    cache_misses: u32,
    memory_allocated: u64,
    
    pub fn init() QueryStats {
        return QueryStats{
            .execution_time_ns = 0,
            .nodes_examined = 0,
            .edges_traversed = 0,
            .vectors_compared = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .memory_allocated = 0,
        };
    }
    
    pub fn combine(self: QueryStats, other: QueryStats) QueryStats {
        return QueryStats{
            .execution_time_ns = self.execution_time_ns + other.execution_time_ns,
            .nodes_examined = self.nodes_examined + other.nodes_examined,
            .edges_traversed = self.edges_traversed + other.edges_traversed,
            .vectors_compared = self.vectors_compared + other.vectors_compared,
            .cache_hits = self.cache_hits + other.cache_hits,
            .cache_misses = self.cache_misses + other.cache_misses,
            .memory_allocated = self.memory_allocated + other.memory_allocated,
        };
    }
    
    pub fn getCacheHitRatio(self: QueryStats) f32 {
        const total_accesses = self.cache_hits + self.cache_misses;
        if (total_accesses == 0) return 0.0;
        return @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total_accesses));
    }
    
    pub fn getEfficiencyScore(self: QueryStats) f32 {
        // Lower scores are better (fewer resources used per operation)
        if (self.nodes_examined == 0) return 0.0;
        const avg_time_per_node = @as(f32, @floatFromInt(self.execution_time_ns)) / @as(f32, @floatFromInt(self.nodes_examined));
        const cache_penalty = 1.0 - self.getCacheHitRatio();
        return avg_time_per_node * (1.0 + cache_penalty);
    }
};

/// Query execution plan strategies
pub const QueryStrategy = enum {
    /// Linear scan - simple but inefficient for large datasets
    linear_scan,
    /// Index-based lookup - use available indexes
    index_lookup,
    /// Graph traversal - efficient for connected data
    graph_traversal,
    /// Vector similarity - optimized for vector queries
    vector_similarity,
    /// Hybrid approach - combine multiple strategies
    hybrid,
    /// Custom optimized plan
    custom,
};

/// Query execution plan
pub const QueryPlan = struct {
    strategy: QueryStrategy,
    estimated_cost: f32,
    expected_selectivity: f32, // Expected fraction of data to examine (0.0 to 1.0)
    use_cache: bool,
    use_parallel: bool,
    index_hints: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, strategy: QueryStrategy) QueryPlan {
        return QueryPlan{
            .strategy = strategy,
            .estimated_cost = 1.0,
            .expected_selectivity = 1.0,
            .use_cache = true,
            .use_parallel = false,
            .index_hints = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *QueryPlan) void {
        self.index_hints.deinit();
    }
    
    pub fn addIndexHint(self: *QueryPlan, index_name: []const u8) !void {
        try self.index_hints.append(index_name);
    }
    
    pub fn calculatePriority(self: QueryPlan) f32 {
        // Higher priority for lower cost and selectivity
        return 1.0 / (self.estimated_cost * self.expected_selectivity + 0.001);
    }
};

/// Query pattern recognition for optimization
pub const QueryPattern = struct {
    pattern_type: PatternType,
    frequency: u32,
    avg_execution_time: u64,
    optimal_strategy: QueryStrategy,
    
    pub const PatternType = enum {
        point_lookup,
        range_scan,
        similarity_search,
        graph_traversal,
        aggregation,
        join,
        complex_filter,
    };
    
    pub fn init(pattern_type: PatternType) QueryPattern {
        return QueryPattern{
            .pattern_type = pattern_type,
            .frequency = 0,
            .avg_execution_time = 0,
            .optimal_strategy = switch (pattern_type) {
                .point_lookup => .index_lookup,
                .range_scan => .index_lookup,
                .similarity_search => .vector_similarity,
                .graph_traversal => .graph_traversal,
                .aggregation => .linear_scan,
                .join => .hybrid,
                .complex_filter => .custom,
            },
        };
    }
    
    pub fn updateStats(self: *QueryPattern, execution_time: u64) void {
        // Update running average
        const new_frequency = self.frequency + 1;
        const total_time = @as(u64, @intCast(self.avg_execution_time)) * self.frequency + execution_time;
        self.avg_execution_time = total_time / new_frequency;
        self.frequency = new_frequency;
    }
};

/// Cost model for query optimization
pub const CostModel = struct {
    // Base costs for different operations (in nanoseconds)
    node_scan_cost: f32 = 100.0,
    edge_traversal_cost: f32 = 150.0,
    vector_comparison_cost: f32 = 500.0,
    index_lookup_cost: f32 = 50.0,
    cache_hit_cost: f32 = 10.0,
    cache_miss_penalty: f32 = 1000.0,
    
    // Scaling factors
    parallel_speedup_factor: f32 = 0.7, // 30% overhead for parallelization
    selectivity_threshold: f32 = 0.1, // When to prefer index over scan
    
    pub fn estimateLinearScanCost(self: CostModel, num_items: u32, selectivity: f32) f32 {
        return @as(f32, @floatFromInt(num_items)) * self.node_scan_cost * selectivity;
    }
    
    pub fn estimateIndexLookupCost(self: CostModel, num_items: u32, selectivity: f32) f32 {
        const index_access = @log(@as(f32, @floatFromInt(num_items))) * self.index_lookup_cost;
        const result_scan = @as(f32, @floatFromInt(num_items)) * selectivity * self.node_scan_cost * 0.1;
        return index_access + result_scan;
    }
    
    pub fn estimateVectorSimilarityCost(self: CostModel, num_vectors: u32, dimensions: u32) f32 {
        const comparison_cost = self.vector_comparison_cost * @as(f32, @floatFromInt(dimensions)) / 128.0;
        return @as(f32, @floatFromInt(num_vectors)) * comparison_cost;
    }
    
    pub fn estimateGraphTraversalCost(self: CostModel, avg_degree: f32, depth: u32) f32 {
        const nodes_visited = std.math.pow(f32, avg_degree, @as(f32, @floatFromInt(depth)));
        return nodes_visited * self.edge_traversal_cost;
    }
    
    pub fn shouldUseIndex(self: CostModel, num_items: u32, selectivity: f32) bool {
        const scan_cost = self.estimateLinearScanCost(num_items, selectivity);
        const index_cost = self.estimateIndexLookupCost(num_items, selectivity);
        return index_cost < scan_cost;
    }
};

/// Query Optimizer - main optimization engine
pub const QueryOptimizer = struct {
    allocator: std.mem.Allocator,
    cost_model: CostModel,
    query_patterns: std.AutoHashMap(u64, QueryPattern), // Hash of query -> pattern
    query_history: std.ArrayList(QueryStats),
    cache_enabled: bool,
    parallel_enabled: bool,
    
    pub fn init(allocator: std.mem.Allocator) QueryOptimizer {
        return QueryOptimizer{
            .allocator = allocator,
            .cost_model = CostModel{},
            .query_patterns = std.AutoHashMap(u64, QueryPattern).init(allocator),
            .query_history = std.ArrayList(QueryStats).init(allocator),
            .cache_enabled = true,
            .parallel_enabled = false, // Conservative default
        };
    }
    
    pub fn deinit(self: *QueryOptimizer) void {
        self.query_patterns.deinit();
        self.query_history.deinit();
    }
    
    /// Analyze a query and create an optimized execution plan
    pub fn optimizeQuery(self: *QueryOptimizer, query_type: QueryPattern.PatternType, 
                        dataset_size: u32, selectivity: f32) !QueryPlan {
        
        // Create initial plan based on query type
        var plan = QueryPlan.init(self.allocator, .linear_scan);
        
        // Determine optimal strategy based on query characteristics
        plan.strategy = self.selectOptimalStrategy(query_type, dataset_size, selectivity);
        plan.expected_selectivity = selectivity;
        plan.use_cache = self.cache_enabled;
        plan.use_parallel = self.parallel_enabled and dataset_size > 1000;
        
        // Calculate estimated cost
        plan.estimated_cost = self.calculateCost(plan.strategy, dataset_size, selectivity);
        
        // Add index hints based on query type
        try self.addIndexHints(&plan, query_type);
        
        return plan;
    }
    
    fn selectOptimalStrategy(self: *QueryOptimizer, query_type: QueryPattern.PatternType, 
                            dataset_size: u32, selectivity: f32) QueryStrategy {
        
        switch (query_type) {
            .point_lookup => {
                if (self.cost_model.shouldUseIndex(dataset_size, selectivity)) {
                    return .index_lookup;
                }
                return .linear_scan;
            },
            .range_scan => {
                if (selectivity < self.cost_model.selectivity_threshold) {
                    return .index_lookup;
                }
                return .linear_scan;
            },
            .similarity_search => {
                return .vector_similarity;
            },
            .graph_traversal => {
                return .graph_traversal;
            },
            .aggregation => {
                if (dataset_size > 10000 and self.parallel_enabled) {
                    return .hybrid;
                }
                return .linear_scan;
            },
            .join => {
                return .hybrid;
            },
            .complex_filter => {
                if (selectivity < 0.01) { // Very selective
                    return .index_lookup;
                } else if (dataset_size > 5000) {
                    return .hybrid;
                }
                return .linear_scan;
            },
        }
    }
    
    fn calculateCost(self: *QueryOptimizer, strategy: QueryStrategy, dataset_size: u32, selectivity: f32) f32 {
        switch (strategy) {
            .linear_scan => return self.cost_model.estimateLinearScanCost(dataset_size, selectivity),
            .index_lookup => return self.cost_model.estimateIndexLookupCost(dataset_size, selectivity),
            .vector_similarity => return self.cost_model.estimateVectorSimilarityCost(dataset_size, 128),
            .graph_traversal => return self.cost_model.estimateGraphTraversalCost(4.0, 3), // Assume avg degree 4, depth 3
            .hybrid => {
                const base_cost = self.cost_model.estimateLinearScanCost(dataset_size, selectivity);
                return base_cost * 1.2; // 20% overhead for coordination
            },
            .custom => {
                const base_cost = self.cost_model.estimateLinearScanCost(dataset_size, selectivity);
                return base_cost * 0.8; // Assume 20% optimization
            },
        }
    }
    
    fn addIndexHints(self: *QueryOptimizer, plan: *QueryPlan, query_type: QueryPattern.PatternType) !void {
        _ = self; // unused
        
        switch (query_type) {
            .point_lookup, .range_scan => {
                try plan.addIndexHint("primary_index");
            },
            .similarity_search => {
                try plan.addIndexHint("vector_index");
                try plan.addIndexHint("hnsw_index");
            },
            .graph_traversal => {
                try plan.addIndexHint("adjacency_index");
            },
            .join => {
                try plan.addIndexHint("join_index");
            },
            else => {
                // No specific hints for other query types
            },
        }
    }
    
    /// Record query execution statistics for future optimization
    pub fn recordQueryExecution(self: *QueryOptimizer, query_hash: u64, pattern: QueryPattern.PatternType, stats: QueryStats) !void {
        // Update query history
        try self.query_history.append(stats);
        
        // Update pattern statistics
        var pattern_entry = self.query_patterns.get(query_hash) orelse QueryPattern.init(pattern);
        pattern_entry.updateStats(stats.execution_time_ns);
        try self.query_patterns.put(query_hash, pattern_entry);
        
        // Adapt cost model based on actual performance
        self.adaptCostModel(stats);
    }
    
    fn adaptCostModel(self: *QueryOptimizer, stats: QueryStats) void {
        // Simple adaptive mechanism - adjust costs based on actual performance
        if (stats.nodes_examined > 0) {
            const actual_node_cost = @as(f32, @floatFromInt(stats.execution_time_ns)) / @as(f32, @floatFromInt(stats.nodes_examined));
            // Exponential moving average with alpha = 0.1
            self.cost_model.node_scan_cost = self.cost_model.node_scan_cost * 0.9 + actual_node_cost * 0.1;
        }
        
        if (stats.edges_traversed > 0) {
            const actual_edge_cost = @as(f32, @floatFromInt(stats.execution_time_ns)) / @as(f32, @floatFromInt(stats.edges_traversed));
            self.cost_model.edge_traversal_cost = self.cost_model.edge_traversal_cost * 0.9 + actual_edge_cost * 0.1;
        }
        
        if (stats.vectors_compared > 0) {
            const actual_vector_cost = @as(f32, @floatFromInt(stats.execution_time_ns)) / @as(f32, @floatFromInt(stats.vectors_compared));
            self.cost_model.vector_comparison_cost = self.cost_model.vector_comparison_cost * 0.9 + actual_vector_cost * 0.1;
        }
    }
    
    /// Get optimization recommendations based on query history
    pub fn getOptimizationRecommendations(self: *QueryOptimizer) !std.ArrayList([]const u8) {
        var recommendations = std.ArrayList([]const u8).init(self.allocator);
        
        // Analyze query patterns
        var pattern_iter = self.query_patterns.iterator();
        var slow_patterns: u32 = 0;
        var cache_miss_ratio: f32 = 0.0;
        var total_queries: u32 = 0;
        
        while (pattern_iter.next()) |entry| {
            total_queries += entry.value_ptr.frequency;
            if (entry.value_ptr.avg_execution_time > 1_000_000) { // > 1ms
                slow_patterns += 1;
            }
        }
        
        // Calculate overall cache miss ratio
        if (self.query_history.items.len > 0) {
            var total_cache_accesses: u32 = 0;
            var total_cache_misses: u32 = 0;
            
            for (self.query_history.items) |stats| {
                total_cache_accesses += stats.cache_hits + stats.cache_misses;
                total_cache_misses += stats.cache_misses;
            }
            
            if (total_cache_accesses > 0) {
                cache_miss_ratio = @as(f32, @floatFromInt(total_cache_misses)) / @as(f32, @floatFromInt(total_cache_accesses));
            }
        }
        
        // Generate recommendations
        if (slow_patterns > 0) {
            try recommendations.append("Consider adding indexes for frequently slow queries");
        }
        
        if (cache_miss_ratio > 0.3) {
            try recommendations.append("Cache hit ratio is low - consider increasing cache size");
        }
        
        if (total_queries > 1000 and !self.parallel_enabled) {
            try recommendations.append("High query volume detected - consider enabling parallel processing");
        }
        
        if (self.query_history.items.len > 100) {
            const recent_stats = self.query_history.items[self.query_history.items.len - 10..];
            var avg_memory: u64 = 0;
            for (recent_stats) |stats| {
                avg_memory += stats.memory_allocated;
            }
            avg_memory /= recent_stats.len;
            
            if (avg_memory > 100_000_000) { // > 100MB
                try recommendations.append("High memory usage detected - consider query result streaming");
            }
        }
        
        return recommendations;
    }
    
    /// Get current optimizer statistics
    pub fn getOptimizerStats(self: *QueryOptimizer) OptimizerStats {
        var total_execution_time: u64 = 0;
        var total_cache_hits: u32 = 0;
        var total_cache_misses: u32 = 0;
        
        for (self.query_history.items) |stats| {
            total_execution_time += stats.execution_time_ns;
            total_cache_hits += stats.cache_hits;
            total_cache_misses += stats.cache_misses;
        }
        
        return OptimizerStats{
            .total_queries_optimized = @intCast(self.query_history.items.len),
            .total_patterns_learned = @intCast(self.query_patterns.count()),
            .avg_optimization_time = if (self.query_history.items.len > 0) 
                total_execution_time / @as(u64, @intCast(self.query_history.items.len)) 
            else 0,
            .cache_hit_ratio = if (total_cache_hits + total_cache_misses > 0)
                @as(f32, @floatFromInt(total_cache_hits)) / @as(f32, @floatFromInt(total_cache_hits + total_cache_misses))
            else 0.0,
            .parallel_enabled = self.parallel_enabled,
            .cache_enabled = self.cache_enabled,
        };
    }
    
    /// Reset optimizer state for testing
    pub fn reset(self: *QueryOptimizer) void {
        self.query_patterns.clearRetainingCapacity();
        self.query_history.clearRetainingCapacity();
        self.cost_model = CostModel{};
    }
};

pub const OptimizerStats = struct {
    total_queries_optimized: u32,
    total_patterns_learned: u32,
    avg_optimization_time: u64,
    cache_hit_ratio: f32,
    parallel_enabled: bool,
    cache_enabled: bool,
};

/// Hash function for query fingerprinting
pub fn hashQuery(query_type: QueryPattern.PatternType, selectivity: f32, dataset_size: u32) u64 {
    // Simple but deterministic hash for query characteristics
    const type_hash = @intFromEnum(query_type);
    const selectivity_hash = @as(u32, @intFromFloat(selectivity * 1000.0));
    const size_hash = dataset_size;
    
    // Combine hashes using FNV-1a style
    var hash: u64 = 14695981039346656037; // FNV offset basis
    hash ^= type_hash;
    hash *%= 1099511628211; // FNV prime
    hash ^= selectivity_hash;
    hash *%= 1099511628211;
    hash ^= size_hash;
    hash *%= 1099511628211;
    
    return hash;
} 