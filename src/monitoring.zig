const std = @import("std");
const types = @import("types.zig");

/// Monitoring and Metrics System for ContextDB
/// Provides Prometheus-compatible metrics and comprehensive observability
/// Following TigerBeetle-style programming: deterministic, high-performance, zero dependencies

/// Histogram bucket configuration for latency measurements
pub const HistogramBuckets = struct {
    buckets: []const f64,
    counts: []u64,
    total_count: u64,
    total_sum: f64,
    allocator: std.mem.Allocator,
    
    /// Standard latency buckets (in microseconds): 100µs, 500µs, 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s, 5s, 10s, +Inf
    pub const LATENCY_BUCKETS = [_]f64{ 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000, 5000000, 10000000, std.math.inf(f64) };
    
    pub fn init(allocator: std.mem.Allocator, buckets: []const f64) !HistogramBuckets {
        const counts = try allocator.alloc(u64, buckets.len);
        @memset(counts, 0);
        
        return HistogramBuckets{
            .buckets = buckets,
            .counts = counts,
            .total_count = 0,
            .total_sum = 0.0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HistogramBuckets) void {
        self.allocator.free(self.counts);
    }
    
    pub fn observe(self: *HistogramBuckets, value: f64) void {
        self.total_count += 1;
        self.total_sum += value;
        
        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                self.counts[i] += 1;
            }
        }
    }
    
    pub fn getPercentile(self: *const HistogramBuckets, percentile: f64) f64 {
        if (self.total_count == 0) return 0.0;
        
        const target_count = @as(f64, @floatFromInt(self.total_count)) * percentile / 100.0;
        var cumulative_count: u64 = 0;
        
        for (self.buckets, 0..) |bucket, i| {
            cumulative_count += self.counts[i];
            if (@as(f64, @floatFromInt(cumulative_count)) >= target_count) {
                return bucket;
            }
        }
        
        return self.buckets[self.buckets.len - 1];
    }
    
    pub fn getMean(self: *const HistogramBuckets) f64 {
        if (self.total_count == 0) return 0.0;
        return self.total_sum / @as(f64, @floatFromInt(self.total_count));
    }
    
    pub fn reset(self: *HistogramBuckets) void {
        @memset(self.counts, 0);
        self.total_count = 0;
        self.total_sum = 0.0;
    }
};

/// Counter for tracking incrementing values
pub const Counter = struct {
    value: std.atomic.Value(u64),
    
    pub fn init() Counter {
        return Counter{
            .value = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn increment(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn add(self: *Counter, amount: u64) void {
        _ = self.value.fetchAdd(amount, .monotonic);
    }
    
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
    
    pub fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }
};

/// Gauge for tracking instantaneous values
pub const Gauge = struct {
    value: std.atomic.Value(i64),
    
    pub fn init() Gauge {
        return Gauge{
            .value = std.atomic.Value(i64).init(0),
        };
    }
    
    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }
    
    pub fn increment(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn decrement(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }
    
    pub fn add(self: *Gauge, amount: i64) void {
        _ = self.value.fetchAdd(amount, .monotonic);
    }
    
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

/// Rate tracker for calculating rates over time windows
pub const RateTracker = struct {
    samples: []u64,
    timestamps: []i64,
    index: usize,
    full: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, window_size: usize) !RateTracker {
        const samples = try allocator.alloc(u64, window_size);
        const timestamps = try allocator.alloc(i64, window_size);
        @memset(samples, 0);
        @memset(timestamps, 0);
        
        return RateTracker{
            .samples = samples,
            .timestamps = timestamps,
            .index = 0,
            .full = false,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RateTracker) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.timestamps);
    }
    
    pub fn record(self: *RateTracker, value: u64) void {
        self.samples[self.index] = value;
        self.timestamps[self.index] = std.time.milliTimestamp();
        
        self.index = (self.index + 1) % self.samples.len;
        if (self.index == 0) {
            self.full = true;
        }
    }
    
    pub fn getRate(self: *const RateTracker) f64 {
        if (!self.full and self.index < 2) return 0.0;
        
        const effective_size = if (self.full) self.samples.len else self.index;
        if (effective_size < 2) return 0.0;
        
        const oldest_idx = if (self.full) self.index else 0;
        const newest_idx = if (self.full) ((self.index + self.samples.len - 1) % self.samples.len) else (self.index - 1);
        
        const time_diff = self.timestamps[newest_idx] - self.timestamps[oldest_idx];
        if (time_diff <= 0) return 0.0;
        
        var total_value: u64 = 0;
        for (0..effective_size) |i| {
            total_value += self.samples[i];
        }
        
        // Rate per second
        return (@as(f64, @floatFromInt(total_value)) / @as(f64, @floatFromInt(time_diff))) * 1000.0;
    }
};

/// Comprehensive metrics collection for ContextDB
pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    
    // Operation counters
    node_inserts_total: Counter,
    edge_inserts_total: Counter,
    vector_inserts_total: Counter,
    
    // Query counters
    similarity_queries_total: Counter,
    graph_queries_total: Counter,
    hybrid_queries_total: Counter,
    
    // Error counters
    insert_errors_total: Counter,
    query_errors_total: Counter,
    system_errors_total: Counter,
    
    // Latency histograms
    insert_duration_histogram: HistogramBuckets,
    query_duration_histogram: HistogramBuckets,
    
    // Memory gauges
    memory_usage_bytes: Gauge,
    heap_allocations: Gauge,
    active_connections: Gauge,
    
    // Database gauges
    total_nodes: Gauge,
    total_edges: Gauge,
    total_vectors: Gauge,
    log_entries: Gauge,
    
    // Rate trackers
    insert_rate_tracker: RateTracker,
    query_rate_tracker: RateTracker,
    
    // System metrics
    startup_timestamp: i64,
    last_metrics_update: i64,
    
    pub fn init(allocator: std.mem.Allocator) !MetricsCollector {
        return MetricsCollector{
            .allocator = allocator,
            
            // Initialize counters
            .node_inserts_total = Counter.init(),
            .edge_inserts_total = Counter.init(),
            .vector_inserts_total = Counter.init(),
            .similarity_queries_total = Counter.init(),
            .graph_queries_total = Counter.init(),
            .hybrid_queries_total = Counter.init(),
            .insert_errors_total = Counter.init(),
            .query_errors_total = Counter.init(),
            .system_errors_total = Counter.init(),
            
            // Initialize histograms
            .insert_duration_histogram = try HistogramBuckets.init(allocator, &HistogramBuckets.LATENCY_BUCKETS),
            .query_duration_histogram = try HistogramBuckets.init(allocator, &HistogramBuckets.LATENCY_BUCKETS),
            
            // Initialize gauges
            .memory_usage_bytes = Gauge.init(),
            .heap_allocations = Gauge.init(),
            .active_connections = Gauge.init(),
            .total_nodes = Gauge.init(),
            .total_edges = Gauge.init(),
            .total_vectors = Gauge.init(),
            .log_entries = Gauge.init(),
            
            // Initialize rate trackers (60 samples for 1-minute windows)
            .insert_rate_tracker = try RateTracker.init(allocator, 60),
            .query_rate_tracker = try RateTracker.init(allocator, 60),
            
            // System metrics
            .startup_timestamp = std.time.timestamp(),
            .last_metrics_update = std.time.timestamp(),
        };
    }
    
    pub fn deinit(self: *MetricsCollector) void {
        self.insert_duration_histogram.deinit();
        self.query_duration_histogram.deinit();
        self.insert_rate_tracker.deinit();
        self.query_rate_tracker.deinit();
    }
    
    // Operation recording methods
    
    pub fn recordNodeInsert(self: *MetricsCollector, duration_us: u64) void {
        self.node_inserts_total.increment();
        self.insert_duration_histogram.observe(@floatFromInt(duration_us));
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordEdgeInsert(self: *MetricsCollector, duration_us: u64) void {
        self.edge_inserts_total.increment();
        self.insert_duration_histogram.observe(@floatFromInt(duration_us));
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordVectorInsert(self: *MetricsCollector, duration_us: u64) void {
        self.vector_inserts_total.increment();
        self.insert_duration_histogram.observe(@floatFromInt(duration_us));
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordSimilarityQuery(self: *MetricsCollector, duration_us: u64) void {
        self.similarity_queries_total.increment();
        self.query_duration_histogram.observe(@floatFromInt(duration_us));
        self.query_rate_tracker.record(1);
    }
    
    pub fn recordGraphQuery(self: *MetricsCollector, duration_us: u64) void {
        self.graph_queries_total.increment();
        self.query_duration_histogram.observe(@floatFromInt(duration_us));
        self.query_rate_tracker.record(1);
    }
    
    pub fn recordHybridQuery(self: *MetricsCollector, duration_us: u64) void {
        self.hybrid_queries_total.increment();
        self.query_duration_histogram.observe(@floatFromInt(duration_us));
        self.query_rate_tracker.record(1);
    }
    
    pub fn recordInsertError(self: *MetricsCollector) void {
        self.insert_errors_total.increment();
    }
    
    pub fn recordQueryError(self: *MetricsCollector) void {
        self.query_errors_total.increment();
    }
    
    pub fn recordSystemError(self: *MetricsCollector) void {
        self.system_errors_total.increment();
    }
    
    // Gauge updates
    
    pub fn updateDatabaseStats(self: *MetricsCollector, stats: types.DatabaseStats) void {
        self.total_nodes.set(@intCast(stats.node_count));
        self.total_edges.set(@intCast(stats.edge_count));
        self.total_vectors.set(@intCast(stats.vector_count));
        self.log_entries.set(@intCast(stats.log_entry_count));
        self.last_metrics_update = std.time.timestamp();
    }
    
    pub fn updateMemoryUsage(self: *MetricsCollector, bytes: i64) void {
        self.memory_usage_bytes.set(bytes);
    }
    
    pub fn updateHeapAllocations(self: *MetricsCollector, count: i64) void {
        self.heap_allocations.set(count);
    }
    
    pub fn incrementActiveConnections(self: *MetricsCollector) void {
        self.active_connections.increment();
    }
    
    pub fn decrementActiveConnections(self: *MetricsCollector) void {
        self.active_connections.decrement();
    }
    
    // Summary statistics
    
    pub fn getUptimeSeconds(self: *const MetricsCollector) i64 {
        return std.time.timestamp() - self.startup_timestamp;
    }
    
    pub fn getInsertRate(self: *const MetricsCollector) f64 {
        return self.insert_rate_tracker.getRate();
    }
    
    pub fn getQueryRate(self: *const MetricsCollector) f64 {
        return self.query_rate_tracker.getRate();
    }
    
    pub fn getErrorRate(self: *const MetricsCollector) f64 {
        const total_errors = self.insert_errors_total.get() + self.query_errors_total.get() + self.system_errors_total.get();
        const total_operations = self.node_inserts_total.get() + self.edge_inserts_total.get() + 
                               self.vector_inserts_total.get() + self.similarity_queries_total.get() + 
                               self.graph_queries_total.get() + self.hybrid_queries_total.get();
        
        if (total_operations == 0) return 0.0;
        return (@as(f64, @floatFromInt(total_errors)) / @as(f64, @floatFromInt(total_operations))) * 100.0;
    }
    
    pub fn getAverageInsertLatency(self: *const MetricsCollector) f64 {
        return self.insert_duration_histogram.getMean();
    }
    
    pub fn getAverageQueryLatency(self: *const MetricsCollector) f64 {
        return self.query_duration_histogram.getMean();
    }
    
    pub fn getP95InsertLatency(self: *const MetricsCollector) f64 {
        return self.insert_duration_histogram.getPercentile(95.0);
    }
    
    pub fn getP95QueryLatency(self: *const MetricsCollector) f64 {
        return self.query_duration_histogram.getPercentile(95.0);
    }
    
    pub fn getP99InsertLatency(self: *const MetricsCollector) f64 {
        return self.insert_duration_histogram.getPercentile(99.0);
    }
    
    pub fn getP99QueryLatency(self: *const MetricsCollector) f64 {
        return self.query_duration_histogram.getPercentile(99.0);
    }
    
    /// Generate Prometheus-compatible metrics output
    pub fn exportPrometheusMetrics(self: *const MetricsCollector, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();
        
        // Help and type annotations
        try writer.print("# HELP contextdb_node_inserts_total Total number of node insert operations\n", .{});
        try writer.print("# TYPE contextdb_node_inserts_total counter\n", .{});
        try writer.print("contextdb_node_inserts_total {}\n", .{self.node_inserts_total.get()});
        
        try writer.print("# HELP contextdb_edge_inserts_total Total number of edge insert operations\n", .{});
        try writer.print("# TYPE contextdb_edge_inserts_total counter\n", .{});
        try writer.print("contextdb_edge_inserts_total {}\n", .{self.edge_inserts_total.get()});
        
        try writer.print("# HELP contextdb_vector_inserts_total Total number of vector insert operations\n", .{});
        try writer.print("# TYPE contextdb_vector_inserts_total counter\n", .{});
        try writer.print("contextdb_vector_inserts_total {}\n", .{self.vector_inserts_total.get()});
        
        try writer.print("# HELP contextdb_similarity_queries_total Total number of similarity query operations\n", .{});
        try writer.print("# TYPE contextdb_similarity_queries_total counter\n", .{});
        try writer.print("contextdb_similarity_queries_total {}\n", .{self.similarity_queries_total.get()});
        
        try writer.print("# HELP contextdb_graph_queries_total Total number of graph query operations\n", .{});
        try writer.print("# TYPE contextdb_graph_queries_total counter\n", .{});
        try writer.print("contextdb_graph_queries_total {}\n", .{self.graph_queries_total.get()});
        
        try writer.print("# HELP contextdb_hybrid_queries_total Total number of hybrid query operations\n", .{});
        try writer.print("# TYPE contextdb_hybrid_queries_total counter\n", .{});
        try writer.print("contextdb_hybrid_queries_total {}\n", .{self.hybrid_queries_total.get()});
        
        // Error metrics
        try writer.print("# HELP contextdb_insert_errors_total Total number of insert errors\n", .{});
        try writer.print("# TYPE contextdb_insert_errors_total counter\n", .{});
        try writer.print("contextdb_insert_errors_total {}\n", .{self.insert_errors_total.get()});
        
        try writer.print("# HELP contextdb_query_errors_total Total number of query errors\n", .{});
        try writer.print("# TYPE contextdb_query_errors_total counter\n", .{});
        try writer.print("contextdb_query_errors_total {}\n", .{self.query_errors_total.get()});
        
        try writer.print("# HELP contextdb_system_errors_total Total number of system errors\n", .{});
        try writer.print("# TYPE contextdb_system_errors_total counter\n", .{});
        try writer.print("contextdb_system_errors_total {}\n", .{self.system_errors_total.get()});
        
        // Histogram metrics
        try writer.print("# HELP contextdb_insert_duration_histogram_us Insert operation duration in microseconds\n", .{});
        try writer.print("# TYPE contextdb_insert_duration_histogram_us histogram\n", .{});
        for (self.insert_duration_histogram.buckets, 0..) |bucket, i| {
            const le_value = if (std.math.isInf(bucket)) "+Inf" else try std.fmt.allocPrint(allocator, "{d}", .{bucket});
            defer if (!std.math.isInf(bucket)) allocator.free(le_value);
            try writer.print("contextdb_insert_duration_histogram_us_bucket{{le=\"{s}\"}} {}\n", .{ le_value, self.insert_duration_histogram.counts[i] });
        }
        try writer.print("contextdb_insert_duration_histogram_us_count {}\n", .{self.insert_duration_histogram.total_count});
        try writer.print("contextdb_insert_duration_histogram_us_sum {d}\n", .{self.insert_duration_histogram.total_sum});
        
        try writer.print("# HELP contextdb_query_duration_histogram_us Query operation duration in microseconds\n", .{});
        try writer.print("# TYPE contextdb_query_duration_histogram_us histogram\n", .{});
        for (self.query_duration_histogram.buckets, 0..) |bucket, i| {
            const le_value = if (std.math.isInf(bucket)) "+Inf" else try std.fmt.allocPrint(allocator, "{d}", .{bucket});
            defer if (!std.math.isInf(bucket)) allocator.free(le_value);
            try writer.print("contextdb_query_duration_histogram_us_bucket{{le=\"{s}\"}} {}\n", .{ le_value, self.query_duration_histogram.counts[i] });
        }
        try writer.print("contextdb_query_duration_histogram_us_count {}\n", .{self.query_duration_histogram.total_count});
        try writer.print("contextdb_query_duration_histogram_us_sum {d}\n", .{self.query_duration_histogram.total_sum});
        
        // Gauge metrics
        try writer.print("# HELP contextdb_memory_usage_bytes Current memory usage in bytes\n", .{});
        try writer.print("# TYPE contextdb_memory_usage_bytes gauge\n", .{});
        try writer.print("contextdb_memory_usage_bytes {}\n", .{self.memory_usage_bytes.get()});
        
        try writer.print("# HELP contextdb_heap_allocations Current number of heap allocations\n", .{});
        try writer.print("# TYPE contextdb_heap_allocations gauge\n", .{});
        try writer.print("contextdb_heap_allocations {}\n", .{self.heap_allocations.get()});
        
        try writer.print("# HELP contextdb_active_connections Current number of active connections\n", .{});
        try writer.print("# TYPE contextdb_active_connections gauge\n", .{});
        try writer.print("contextdb_active_connections {}\n", .{self.active_connections.get()});
        
        try writer.print("# HELP contextdb_total_nodes Current number of nodes in database\n", .{});
        try writer.print("# TYPE contextdb_total_nodes gauge\n", .{});
        try writer.print("contextdb_total_nodes {}\n", .{self.total_nodes.get()});
        
        try writer.print("# HELP contextdb_total_edges Current number of edges in database\n", .{});
        try writer.print("# TYPE contextdb_total_edges gauge\n", .{});
        try writer.print("contextdb_total_edges {}\n", .{self.total_edges.get()});
        
        try writer.print("# HELP contextdb_total_vectors Current number of vectors in database\n", .{});
        try writer.print("# TYPE contextdb_total_vectors gauge\n", .{});
        try writer.print("contextdb_total_vectors {}\n", .{self.total_vectors.get()});
        
        try writer.print("# HELP contextdb_log_entries Current number of log entries\n", .{});
        try writer.print("# TYPE contextdb_log_entries gauge\n", .{});
        try writer.print("contextdb_log_entries {}\n", .{self.log_entries.get()});
        
        // System metrics
        try writer.print("# HELP contextdb_uptime_seconds Uptime in seconds since startup\n", .{});
        try writer.print("# TYPE contextdb_uptime_seconds gauge\n", .{});
        try writer.print("contextdb_uptime_seconds {}\n", .{self.getUptimeSeconds()});
        
        try writer.print("# HELP contextdb_insert_rate_per_second Current insert operations per second\n", .{});
        try writer.print("# TYPE contextdb_insert_rate_per_second gauge\n", .{});
        try writer.print("contextdb_insert_rate_per_second {d:.2}\n", .{self.getInsertRate()});
        
        try writer.print("# HELP contextdb_query_rate_per_second Current query operations per second\n", .{});
        try writer.print("# TYPE contextdb_query_rate_per_second gauge\n", .{});
        try writer.print("contextdb_query_rate_per_second {d:.2}\n", .{self.getQueryRate()});
        
        try writer.print("# HELP contextdb_error_rate_percent Current error rate as percentage\n", .{});
        try writer.print("# TYPE contextdb_error_rate_percent gauge\n", .{});
        try writer.print("contextdb_error_rate_percent {d:.2}\n", .{self.getErrorRate()});
        
        return try output.toOwnedSlice();
    }
    
    /// Generate JSON metrics output for HTTP API
    pub fn exportJsonMetrics(self: *const MetricsCollector, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();
        
        try writer.print("{{", .{});
        try writer.print("\"timestamp\":{},", .{std.time.timestamp()});
        try writer.print("\"uptime_seconds\":{},", .{self.getUptimeSeconds()});
        
        // Counters
        try writer.print("\"counters\":{{", .{});
        try writer.print("\"node_inserts_total\":{},", .{self.node_inserts_total.get()});
        try writer.print("\"edge_inserts_total\":{},", .{self.edge_inserts_total.get()});
        try writer.print("\"vector_inserts_total\":{},", .{self.vector_inserts_total.get()});
        try writer.print("\"similarity_queries_total\":{},", .{self.similarity_queries_total.get()});
        try writer.print("\"graph_queries_total\":{},", .{self.graph_queries_total.get()});
        try writer.print("\"hybrid_queries_total\":{},", .{self.hybrid_queries_total.get()});
        try writer.print("\"insert_errors_total\":{},", .{self.insert_errors_total.get()});
        try writer.print("\"query_errors_total\":{},", .{self.query_errors_total.get()});
        try writer.print("\"system_errors_total\":{}", .{self.system_errors_total.get()});
        try writer.print("}},", .{});
        
        // Gauges
        try writer.print("\"gauges\":{{", .{});
        try writer.print("\"memory_usage_bytes\":{},", .{self.memory_usage_bytes.get()});
        try writer.print("\"heap_allocations\":{},", .{self.heap_allocations.get()});
        try writer.print("\"active_connections\":{},", .{self.active_connections.get()});
        try writer.print("\"total_nodes\":{},", .{self.total_nodes.get()});
        try writer.print("\"total_edges\":{},", .{self.total_edges.get()});
        try writer.print("\"total_vectors\":{},", .{self.total_vectors.get()});
        try writer.print("\"log_entries\":{}", .{self.log_entries.get()});
        try writer.print("}},", .{});
        
        // Rates
        try writer.print("\"rates\":{{", .{});
        try writer.print("\"insert_rate_per_second\":{d:.2},", .{self.getInsertRate()});
        try writer.print("\"query_rate_per_second\":{d:.2},", .{self.getQueryRate()});
        try writer.print("\"error_rate_percent\":{d:.2}", .{self.getErrorRate()});
        try writer.print("}},", .{});
        
        // Latency statistics
        try writer.print("\"latency\":{{", .{});
        try writer.print("\"insert_avg_us\":{d:.2},", .{self.getAverageInsertLatency()});
        try writer.print("\"insert_p95_us\":{d:.2},", .{self.getP95InsertLatency()});
        try writer.print("\"insert_p99_us\":{d:.2},", .{self.getP99InsertLatency()});
        try writer.print("\"query_avg_us\":{d:.2},", .{self.getAverageQueryLatency()});
        try writer.print("\"query_p95_us\":{d:.2},", .{self.getP95QueryLatency()});
        try writer.print("\"query_p99_us\":{d:.2}", .{self.getP99QueryLatency()});
        try writer.print("}}", .{});
        
        try writer.print("}}", .{});
        
        return try output.toOwnedSlice();
    }
    
    /// Reset all metrics (useful for testing)
    pub fn reset(self: *MetricsCollector) void {
        // Reset counters
        self.node_inserts_total.reset();
        self.edge_inserts_total.reset();
        self.vector_inserts_total.reset();
        self.similarity_queries_total.reset();
        self.graph_queries_total.reset();
        self.hybrid_queries_total.reset();
        self.insert_errors_total.reset();
        self.query_errors_total.reset();
        self.system_errors_total.reset();
        
        // Reset histograms
        self.insert_duration_histogram.reset();
        self.query_duration_histogram.reset();
        
        // Reset system metrics
        self.startup_timestamp = std.time.timestamp();
        self.last_metrics_update = std.time.timestamp();
    }
};

/// Health status levels
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
    
    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
};

/// Health check result
pub const HealthCheck = struct {
    status: HealthStatus,
    checks: std.ArrayList(HealthCheckItem),
    allocator: std.mem.Allocator,
    
    pub const HealthCheckItem = struct {
        name: []const u8,
        status: HealthStatus,
        message: []const u8,
        response_time_us: u64,
    };
    
    pub fn init(allocator: std.mem.Allocator) HealthCheck {
        return HealthCheck{
            .status = .healthy,
            .checks = std.ArrayList(HealthCheckItem).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HealthCheck) void {
        for (self.checks.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.message);
        }
        self.checks.deinit();
    }
    
    pub fn addCheck(self: *HealthCheck, name: []const u8, status: HealthStatus, message: []const u8, response_time_us: u64) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_message = try self.allocator.dupe(u8, message);
        
        try self.checks.append(HealthCheckItem{
            .name = owned_name,
            .status = status,
            .message = owned_message,
            .response_time_us = response_time_us,
        });
        
        // Update overall status
        if (status == .unhealthy) {
            self.status = .unhealthy;
        } else if (status == .degraded and self.status == .healthy) {
            self.status = .degraded;
        }
    }
    
    pub fn exportJson(self: *const HealthCheck, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();
        
        try writer.print("{{", .{});
        try writer.print("\"status\":\"{s}\",", .{self.status.toString()});
        try writer.print("\"timestamp\":{},", .{std.time.timestamp()});
        try writer.print("\"checks\":[", .{});
        
        for (self.checks.items, 0..) |item, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("{{", .{});
            try writer.print("\"name\":\"{s}\",", .{item.name});
            try writer.print("\"status\":\"{s}\",", .{item.status.toString()});
            try writer.print("\"message\":\"{s}\",", .{item.message});
            try writer.print("\"response_time_us\":{}", .{item.response_time_us});
            try writer.print("}}", .{});
        }
        
        try writer.print("]", .{});
        try writer.print("}}", .{});
        
        return try output.toOwnedSlice();
    }
}; 