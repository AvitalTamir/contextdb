const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const testing = std.testing;

/// Monitoring and Metrics System for Memora
/// Provides Prometheus-compatible metrics and comprehensive observability
/// Following TigerBeetle-style programming: deterministic, high-performance, zero dependencies

/// Monitoring configuration helper
pub const MonitoringConfig = struct {
    collection_interval_ms: u32,
    rate_tracker_window_size: u32,
    histogram_enable: bool,
    export_prometheus: bool,
    export_json: bool,
    health_check_interval_ms: u32,
    health_check_timeout_ms: u32,
    memory_stats_enable: bool,
    error_tracking_enable: bool,
    
    pub fn fromConfig(global_cfg: config.Config) MonitoringConfig {
        return MonitoringConfig{
            .collection_interval_ms = global_cfg.metrics_collection_interval_ms,
            .rate_tracker_window_size = global_cfg.metrics_rate_tracker_window_size,
            .histogram_enable = global_cfg.metrics_histogram_enable,
            .export_prometheus = global_cfg.metrics_export_prometheus,
            .export_json = global_cfg.metrics_export_json,
            .health_check_interval_ms = global_cfg.health_check_interval_ms,
            .health_check_timeout_ms = global_cfg.health_check_timeout_ms,
            .memory_stats_enable = global_cfg.memory_stats_enable,
            .error_tracking_enable = global_cfg.error_tracking_enable,
        };
    }
};

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

/// Comprehensive metrics collection for Memora
pub const MetricsCollector = struct {
    allocator: std.mem.Allocator,
    config: MonitoringConfig,
    
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
    insert_duration_histogram: ?HistogramBuckets,
    query_duration_histogram: ?HistogramBuckets,
    
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
    
    pub fn init(allocator: std.mem.Allocator, monitoring_config: ?MonitoringConfig) !MetricsCollector {
        const cfg = monitoring_config orelse MonitoringConfig.fromConfig(config.Config{});
        
        // Initialize histograms only if enabled in config
        const insert_histogram = if (cfg.histogram_enable) 
            try HistogramBuckets.init(allocator, &HistogramBuckets.LATENCY_BUCKETS)
        else 
            null;
            
        const query_histogram = if (cfg.histogram_enable)
            try HistogramBuckets.init(allocator, &HistogramBuckets.LATENCY_BUCKETS)
        else
            null;
        
        return MetricsCollector{
            .allocator = allocator,
            .config = cfg,
            
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
            
            // Initialize histograms (optional based on config)
            .insert_duration_histogram = insert_histogram,
            .query_duration_histogram = query_histogram,
            
            // Initialize gauges
            .memory_usage_bytes = Gauge.init(),
            .heap_allocations = Gauge.init(),
            .active_connections = Gauge.init(),
            .total_nodes = Gauge.init(),
            .total_edges = Gauge.init(),
            .total_vectors = Gauge.init(),
            .log_entries = Gauge.init(),
            
            // Initialize rate trackers with configurable window size
            .insert_rate_tracker = try RateTracker.init(allocator, cfg.rate_tracker_window_size),
            .query_rate_tracker = try RateTracker.init(allocator, cfg.rate_tracker_window_size),
            
            // System metrics
            .startup_timestamp = std.time.timestamp(),
            .last_metrics_update = std.time.timestamp(),
        };
    }
    
    pub fn deinit(self: *MetricsCollector) void {
        if (self.insert_duration_histogram) |*histogram| {
            histogram.deinit();
        }
        if (self.query_duration_histogram) |*histogram| {
            histogram.deinit();
        }
        self.insert_rate_tracker.deinit();
        self.query_rate_tracker.deinit();
    }
    
    // Operation recording methods
    
    pub fn recordNodeInsert(self: *MetricsCollector, duration_us: u64) void {
        self.node_inserts_total.increment();
        if (self.insert_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordEdgeInsert(self: *MetricsCollector, duration_us: u64) void {
        self.edge_inserts_total.increment();
        if (self.insert_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordVectorInsert(self: *MetricsCollector, duration_us: u64) void {
        self.vector_inserts_total.increment();
        if (self.insert_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        self.insert_rate_tracker.record(1);
    }
    
    pub fn recordSimilarityQuery(self: *MetricsCollector, duration_us: u64) void {
        self.similarity_queries_total.increment();
        if (self.query_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        self.query_rate_tracker.record(1);
    }
    
    pub fn recordGraphQuery(self: *MetricsCollector, duration_us: u64) void {
        self.graph_queries_total.increment();
        if (self.query_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        self.query_rate_tracker.record(1);
    }
    
    pub fn recordHybridQuery(self: *MetricsCollector, duration_us: u64) void {
        self.hybrid_queries_total.increment();
        if (self.query_duration_histogram) |*histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
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
    
    pub fn recordLogCompaction(self: *MetricsCollector, duration_us: u64, entries_removed: u64) void {
        // Record the compaction operation
        if (self.insert_duration_histogram) |histogram| {
            histogram.observe(@floatFromInt(duration_us));
        }
        // Could add specific compaction metrics here in the future
        _ = entries_removed;
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
        if (self.insert_duration_histogram) |histogram| {
            return histogram.getMean();
        } else {
            return 0.0;
        }
    }
    
    pub fn getAverageQueryLatency(self: *const MetricsCollector) f64 {
        if (self.query_duration_histogram) |histogram| {
            return histogram.getMean();
        } else {
            return 0.0;
        }
    }
    
    pub fn getP95InsertLatency(self: *const MetricsCollector) f64 {
        if (self.insert_duration_histogram) |histogram| {
            return histogram.getPercentile(95.0);
        } else {
            return 0.0;
        }
    }
    
    pub fn getP95QueryLatency(self: *const MetricsCollector) f64 {
        if (self.query_duration_histogram) |histogram| {
            return histogram.getPercentile(95.0);
        } else {
            return 0.0;
        }
    }
    
    pub fn getP99InsertLatency(self: *const MetricsCollector) f64 {
        if (self.insert_duration_histogram) |histogram| {
            return histogram.getPercentile(99.0);
        } else {
            return 0.0;
        }
    }
    
    pub fn getP99QueryLatency(self: *const MetricsCollector) f64 {
        if (self.query_duration_histogram) |histogram| {
            return histogram.getPercentile(99.0);
        } else {
            return 0.0;
        }
    }
    
    /// Generate Prometheus-compatible metrics output
    pub fn exportPrometheusMetrics(self: *const MetricsCollector, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();
        
        // Help and type annotations
        try writer.print("# HELP memora_node_inserts_total Total number of node insert operations\n", .{});
        try writer.print("# TYPE memora_node_inserts_total counter\n", .{});
        try writer.print("memora_node_inserts_total {}\n", .{self.node_inserts_total.get()});
        
        try writer.print("# HELP memora_edge_inserts_total Total number of edge insert operations\n", .{});
        try writer.print("# TYPE memora_edge_inserts_total counter\n", .{});
        try writer.print("memora_edge_inserts_total {}\n", .{self.edge_inserts_total.get()});
        
        try writer.print("# HELP memora_vector_inserts_total Total number of vector insert operations\n", .{});
        try writer.print("# TYPE memora_vector_inserts_total counter\n", .{});
        try writer.print("memora_vector_inserts_total {}\n", .{self.vector_inserts_total.get()});
        
        try writer.print("# HELP memora_similarity_queries_total Total number of similarity query operations\n", .{});
        try writer.print("# TYPE memora_similarity_queries_total counter\n", .{});
        try writer.print("memora_similarity_queries_total {}\n", .{self.similarity_queries_total.get()});
        
        try writer.print("# HELP memora_graph_queries_total Total number of graph query operations\n", .{});
        try writer.print("# TYPE memora_graph_queries_total counter\n", .{});
        try writer.print("memora_graph_queries_total {}\n", .{self.graph_queries_total.get()});
        
        try writer.print("# HELP memora_hybrid_queries_total Total number of hybrid query operations\n", .{});
        try writer.print("# TYPE memora_hybrid_queries_total counter\n", .{});
        try writer.print("memora_hybrid_queries_total {}\n", .{self.hybrid_queries_total.get()});
        
        // Error metrics
        try writer.print("# HELP memora_insert_errors_total Total number of insert errors\n", .{});
        try writer.print("# TYPE memora_insert_errors_total counter\n", .{});
        try writer.print("memora_insert_errors_total {}\n", .{self.insert_errors_total.get()});
        
        try writer.print("# HELP memora_query_errors_total Total number of query errors\n", .{});
        try writer.print("# TYPE memora_query_errors_total counter\n", .{});
        try writer.print("memora_query_errors_total {}\n", .{self.query_errors_total.get()});
        
        try writer.print("# HELP memora_system_errors_total Total number of system errors\n", .{});
        try writer.print("# TYPE memora_system_errors_total counter\n", .{});
        try writer.print("memora_system_errors_total {}\n", .{self.system_errors_total.get()});
        
        // Histogram metrics
        if (self.insert_duration_histogram) |histogram| {
            try writer.print("# HELP memora_insert_duration_histogram_us Insert operation duration in microseconds\n", .{});
            try writer.print("# TYPE memora_insert_duration_histogram_us histogram\n", .{});
            for (histogram.buckets, 0..) |bucket, i| {
                const le_value = if (std.math.isInf(bucket)) "+Inf" else try std.fmt.allocPrint(allocator, "{d}", .{bucket});
                defer if (!std.math.isInf(bucket)) allocator.free(le_value);
                try writer.print("memora_insert_duration_histogram_us_bucket{{le=\"{s}\"}} {}\n", .{ le_value, histogram.counts[i] });
            }
            try writer.print("memora_insert_duration_histogram_us_count {}\n", .{histogram.total_count});
            try writer.print("memora_insert_duration_histogram_us_sum {d}\n", .{histogram.total_sum});
        }
        
        if (self.query_duration_histogram) |histogram| {
            try writer.print("# HELP memora_query_duration_histogram_us Query operation duration in microseconds\n", .{});
            try writer.print("# TYPE memora_query_duration_histogram_us histogram\n", .{});
            for (histogram.buckets, 0..) |bucket, i| {
                const le_value = if (std.math.isInf(bucket)) "+Inf" else try std.fmt.allocPrint(allocator, "{d}", .{bucket});
                defer if (!std.math.isInf(bucket)) allocator.free(le_value);
                try writer.print("memora_query_duration_histogram_us_bucket{{le=\"{s}\"}} {}\n", .{ le_value, histogram.counts[i] });
            }
            try writer.print("memora_query_duration_histogram_us_count {}\n", .{histogram.total_count});
            try writer.print("memora_query_duration_histogram_us_sum {d}\n", .{histogram.total_sum});
        }
        
        // Gauge metrics
        try writer.print("# HELP memora_memory_usage_bytes Current memory usage in bytes\n", .{});
        try writer.print("# TYPE memora_memory_usage_bytes gauge\n", .{});
        try writer.print("memora_memory_usage_bytes {}\n", .{self.memory_usage_bytes.get()});
        
        try writer.print("# HELP memora_heap_allocations Current number of heap allocations\n", .{});
        try writer.print("# TYPE memora_heap_allocations gauge\n", .{});
        try writer.print("memora_heap_allocations {}\n", .{self.heap_allocations.get()});
        
        try writer.print("# HELP memora_active_connections Current number of active connections\n", .{});
        try writer.print("# TYPE memora_active_connections gauge\n", .{});
        try writer.print("memora_active_connections {}\n", .{self.active_connections.get()});
        
        try writer.print("# HELP memora_total_nodes Current number of nodes in database\n", .{});
        try writer.print("# TYPE memora_total_nodes gauge\n", .{});
        try writer.print("memora_total_nodes {}\n", .{self.total_nodes.get()});
        
        try writer.print("# HELP memora_total_edges Current number of edges in database\n", .{});
        try writer.print("# TYPE memora_total_edges gauge\n", .{});
        try writer.print("memora_total_edges {}\n", .{self.total_edges.get()});
        
        try writer.print("# HELP memora_total_vectors Current number of vectors in database\n", .{});
        try writer.print("# TYPE memora_total_vectors gauge\n", .{});
        try writer.print("memora_total_vectors {}\n", .{self.total_vectors.get()});
        
        try writer.print("# HELP memora_log_entries Current number of log entries\n", .{});
        try writer.print("# TYPE memora_log_entries gauge\n", .{});
        try writer.print("memora_log_entries {}\n", .{self.log_entries.get()});
        
        // System metrics
        try writer.print("# HELP memora_uptime_seconds Uptime in seconds since startup\n", .{});
        try writer.print("# TYPE memora_uptime_seconds gauge\n", .{});
        try writer.print("memora_uptime_seconds {}\n", .{self.getUptimeSeconds()});
        
        try writer.print("# HELP memora_insert_rate_per_second Current insert operations per second\n", .{});
        try writer.print("# TYPE memora_insert_rate_per_second gauge\n", .{});
        try writer.print("memora_insert_rate_per_second {d:.2}\n", .{self.getInsertRate()});
        
        try writer.print("# HELP memora_query_rate_per_second Current query operations per second\n", .{});
        try writer.print("# TYPE memora_query_rate_per_second gauge\n", .{});
        try writer.print("memora_query_rate_per_second {d:.2}\n", .{self.getQueryRate()});
        
        try writer.print("# HELP memora_error_rate_percent Current error rate as percentage\n", .{});
        try writer.print("# TYPE memora_error_rate_percent gauge\n", .{});
        try writer.print("memora_error_rate_percent {d:.2}\n", .{self.getErrorRate()});
        
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
        if (self.insert_duration_histogram) |*histogram| {
            histogram.reset();
        }
        if (self.query_duration_histogram) |*histogram| {
            histogram.reset();
        }
        
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

test "MonitoringConfig from global config" {
    const global_config = config.Config{
        .metrics_collection_interval_ms = 2000,
        .metrics_rate_tracker_window_size = 120,
        .metrics_histogram_enable = false,
        .metrics_export_prometheus = true,
        .metrics_export_json = false,
        .health_check_interval_ms = 10000,
        .health_check_timeout_ms = 2000,
        .memory_stats_enable = false,
        .error_tracking_enable = true,
    };
    
    const monitoring_config = MonitoringConfig.fromConfig(global_config);
    
    try testing.expect(monitoring_config.collection_interval_ms == 2000);
    try testing.expect(monitoring_config.rate_tracker_window_size == 120);
    try testing.expect(monitoring_config.histogram_enable == false);
    try testing.expect(monitoring_config.export_prometheus == true);
    try testing.expect(monitoring_config.export_json == false);
    try testing.expect(monitoring_config.health_check_interval_ms == 10000);
    try testing.expect(monitoring_config.health_check_timeout_ms == 2000);
    try testing.expect(monitoring_config.memory_stats_enable == false);
    try testing.expect(monitoring_config.error_tracking_enable == true);
}

test "MetricsCollector with custom configuration" {
    const allocator = testing.allocator;
    
    const monitoring_config = MonitoringConfig{
        .collection_interval_ms = 3000,
        .rate_tracker_window_size = 30,
        .histogram_enable = false, // Disable histograms
        .export_prometheus = true,
        .export_json = true,
        .health_check_interval_ms = 15000,
        .health_check_timeout_ms = 3000,
        .memory_stats_enable = true,
        .error_tracking_enable = false,
    };
    
    var metrics = try MetricsCollector.init(allocator, monitoring_config);
    defer metrics.deinit();
    
    // Verify configuration is applied
    try testing.expect(metrics.config.collection_interval_ms == 3000);
    try testing.expect(metrics.config.rate_tracker_window_size == 30);
    try testing.expect(metrics.config.histogram_enable == false);
    
    // Verify histograms are disabled
    try testing.expect(metrics.insert_duration_histogram == null);
    try testing.expect(metrics.query_duration_histogram == null);
    
    // Test that recording operations work without histograms
    metrics.recordNodeInsert(100);
    metrics.recordSimilarityQuery(500);
    
    try testing.expect(metrics.node_inserts_total.get() == 1);
    try testing.expect(metrics.similarity_queries_total.get() == 1);
    
    // Latency methods should return 0.0 when histograms disabled
    try testing.expect(metrics.getAverageInsertLatency() == 0.0);
    try testing.expect(metrics.getAverageQueryLatency() == 0.0);
    try testing.expect(metrics.getP95InsertLatency() == 0.0);
    try testing.expect(metrics.getP99QueryLatency() == 0.0);
}

test "MetricsCollector with default configuration" {
    const allocator = testing.allocator;
    
    var metrics = try MetricsCollector.init(allocator, null);
    defer metrics.deinit();
    
    // Verify default values are applied
    try testing.expect(metrics.config.collection_interval_ms == 1000);
    try testing.expect(metrics.config.rate_tracker_window_size == 60);
    try testing.expect(metrics.config.histogram_enable == true);
    try testing.expect(metrics.config.export_prometheus == true);
    try testing.expect(metrics.config.export_json == true);
    
    // Verify histograms are enabled by default
    try testing.expect(metrics.insert_duration_histogram != null);
    try testing.expect(metrics.query_duration_histogram != null);
    
    // Test histogram functionality
    metrics.recordNodeInsert(100);
    
    try testing.expect(metrics.getAverageInsertLatency() > 0.0);
}

test "Monitoring configuration integration with global config" {
    const allocator = testing.allocator;
    
    // Create a comprehensive global config
    const global_config = config.Config{
        .metrics_collection_interval_ms = 1500,
        .metrics_rate_tracker_window_size = 90,
        .metrics_histogram_enable = true,
        .metrics_export_prometheus = false,
        .metrics_export_json = true,
        .health_check_interval_ms = 3000,
        .health_check_timeout_ms = 500,
        .memory_stats_enable = false,
        .error_tracking_enable = true,
    };
    
    // Test MonitoringConfig.fromConfig
    const monitoring_cfg = MonitoringConfig.fromConfig(global_config);
    try testing.expect(monitoring_cfg.collection_interval_ms == 1500);
    try testing.expect(monitoring_cfg.rate_tracker_window_size == 90);
    try testing.expect(monitoring_cfg.histogram_enable == true);
    try testing.expect(monitoring_cfg.export_prometheus == false);
    try testing.expect(monitoring_cfg.export_json == true);
    try testing.expect(monitoring_cfg.health_check_interval_ms == 3000);
    try testing.expect(monitoring_cfg.health_check_timeout_ms == 500);
    try testing.expect(monitoring_cfg.memory_stats_enable == false);
    try testing.expect(monitoring_cfg.error_tracking_enable == true);
    
    // Test MetricsCollector with the config
    var metrics = try MetricsCollector.init(allocator, monitoring_cfg);
    defer metrics.deinit();
    
    // Verify integration works end-to-end
    try testing.expect(metrics.config.collection_interval_ms == 1500);
    try testing.expect(metrics.config.rate_tracker_window_size == 90);
    try testing.expect(metrics.insert_duration_histogram != null); // Histograms enabled
    try testing.expect(metrics.query_duration_histogram != null);
    
    // Test functionality with real monitoring operations
    metrics.recordNodeInsert(150);
    metrics.recordGraphQuery(300);
    
    try testing.expect(metrics.node_inserts_total.get() == 1);
    try testing.expect(metrics.graph_queries_total.get() == 1);
    try testing.expect(metrics.getAverageInsertLatency() > 0.0);
    try testing.expect(metrics.getAverageQueryLatency() > 0.0);
} 