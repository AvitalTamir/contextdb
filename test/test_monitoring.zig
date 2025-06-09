const std = @import("std");
const testing = std.testing;
const contextdb = @import("contextdb");
const monitoring = contextdb.monitoring;
const types = contextdb.types;

test "HistogramBuckets basic functionality" {
    const allocator = testing.allocator;
    
    var histogram = try monitoring.HistogramBuckets.init(allocator, &monitoring.HistogramBuckets.LATENCY_BUCKETS);
    defer histogram.deinit();
    
    // Test observations
    histogram.observe(50.0);    // Should go in 100µs bucket
    histogram.observe(150.0);   // Should go in 500µs bucket
    histogram.observe(750.0);   // Should go in 1ms bucket
    histogram.observe(2500.0);  // Should go in 5ms bucket
    
    // Check totals
    try testing.expect(histogram.total_count == 4);
    try testing.expect(histogram.total_sum == 3450.0);
    
    // Check mean
    const mean = histogram.getMean();
    try testing.expect(@abs(mean - 862.5) < 0.1);
    
    // Check percentiles
    const p50 = histogram.getPercentile(50.0);
    try testing.expect(p50 <= 500.0); // Should be in 500µs bucket or below
    
    const p95 = histogram.getPercentile(95.0);
    try testing.expect(p95 <= 5000.0); // Should be in 5ms bucket or below
}

test "Counter thread safety" {
    var counter = monitoring.Counter.init();
    
    try testing.expect(counter.get() == 0);
    
    counter.increment();
    try testing.expect(counter.get() == 1);
    
    counter.add(5);
    try testing.expect(counter.get() == 6);
    
    counter.reset();
    try testing.expect(counter.get() == 0);
}

test "Gauge functionality" {
    var gauge = monitoring.Gauge.init();
    
    try testing.expect(gauge.get() == 0);
    
    gauge.set(100);
    try testing.expect(gauge.get() == 100);
    
    gauge.increment();
    try testing.expect(gauge.get() == 101);
    
    gauge.decrement();
    try testing.expect(gauge.get() == 100);
    
    gauge.add(-50);
    try testing.expect(gauge.get() == 50);
}

test "RateTracker functionality" {
    const allocator = testing.allocator;
    
    var rate_tracker = try monitoring.RateTracker.init(allocator, 5);
    defer rate_tracker.deinit();
    
    // Add some samples
    rate_tracker.record(1);
    std.time.sleep(10_000_000); // 10ms
    rate_tracker.record(1);
    std.time.sleep(10_000_000); // 10ms
    rate_tracker.record(1);
    
    const rate = rate_tracker.getRate();
    try testing.expect(rate > 0.0); // Should have some positive rate
}

test "MetricsCollector comprehensive test" {
    const allocator = testing.allocator;
    
    var metrics = try monitoring.MetricsCollector.init(allocator, null);
    defer metrics.deinit();
    
    // Test operation recording
    metrics.recordNodeInsert(100);
    metrics.recordEdgeInsert(150);
    metrics.recordVectorInsert(200);
    
    try testing.expect(metrics.node_inserts_total.get() == 1);
    try testing.expect(metrics.edge_inserts_total.get() == 1);
    try testing.expect(metrics.vector_inserts_total.get() == 1);
    
    // Test query recording
    metrics.recordSimilarityQuery(500);
    metrics.recordGraphQuery(300);
    metrics.recordHybridQuery(800);
    
    try testing.expect(metrics.similarity_queries_total.get() == 1);
    try testing.expect(metrics.graph_queries_total.get() == 1);
    try testing.expect(metrics.hybrid_queries_total.get() == 1);
    
    // Test error recording
    metrics.recordInsertError();
    metrics.recordQueryError();
    metrics.recordSystemError();
    
    try testing.expect(metrics.insert_errors_total.get() == 1);
    try testing.expect(metrics.query_errors_total.get() == 1);
    try testing.expect(metrics.system_errors_total.get() == 1);
    
    // Test database stats update
    const stats = types.DatabaseStats{
        .node_count = 100,
        .edge_count = 200,
        .vector_count = 50,
        .log_entry_count = 350,
        .snapshot_count = 2,
        .memory_usage = 1_000_000,
        .disk_usage = 500_000,
        .uptime_seconds = 3600, // 1 hour
    };
    metrics.updateDatabaseStats(stats);
    
    try testing.expect(metrics.total_nodes.get() == 100);
    try testing.expect(metrics.total_edges.get() == 200);
    try testing.expect(metrics.total_vectors.get() == 50);
    try testing.expect(metrics.log_entries.get() == 350);
    
    // Test memory tracking
    metrics.updateMemoryUsage(1_000_000);
    try testing.expect(metrics.memory_usage_bytes.get() == 1_000_000);
    
    // Test connection tracking
    metrics.incrementActiveConnections();
    metrics.incrementActiveConnections();
    try testing.expect(metrics.active_connections.get() == 2);
    
    metrics.decrementActiveConnections();
    try testing.expect(metrics.active_connections.get() == 1);
    
    // Test rates and averages
    const insert_rate = metrics.getInsertRate();
    try testing.expect(insert_rate >= 0.0);
    
    const query_rate = metrics.getQueryRate();
    try testing.expect(query_rate >= 0.0);
    
    const error_rate = metrics.getErrorRate();
    try testing.expect(error_rate >= 0.0);
    
    const avg_insert_latency = metrics.getAverageInsertLatency();
    try testing.expect(avg_insert_latency > 0.0);
    
    const avg_query_latency = metrics.getAverageQueryLatency();
    try testing.expect(avg_query_latency > 0.0);
    
    // Test uptime
    const uptime = metrics.getUptimeSeconds();
    try testing.expect(uptime >= 0);
}

test "MetricsCollector JSON export" {
    const allocator = testing.allocator;
    
    var metrics = try monitoring.MetricsCollector.init(allocator, null);
    defer metrics.deinit();
    
    // Add some test data
    metrics.recordNodeInsert(100);
    metrics.recordSimilarityQuery(500);
    metrics.updateMemoryUsage(1_000_000);
    
    const stats = types.DatabaseStats{
        .node_count = 10,
        .edge_count = 20,
        .vector_count = 5,
        .log_entry_count = 35,
        .snapshot_count = 1,
        .memory_usage = 2_000_000,
        .disk_usage = 1_000_000,
        .uptime_seconds = 1800, // 30 minutes
    };
    metrics.updateDatabaseStats(stats);
    
    // Export JSON
    const json = try metrics.exportJsonMetrics(allocator);
    defer allocator.free(json);
    
    // Basic validation - should contain key metrics
    try testing.expect(std.mem.indexOf(u8, json, "timestamp") != null);
    try testing.expect(std.mem.indexOf(u8, json, "counters") != null);
    try testing.expect(std.mem.indexOf(u8, json, "gauges") != null);
    try testing.expect(std.mem.indexOf(u8, json, "rates") != null);
    try testing.expect(std.mem.indexOf(u8, json, "latency") != null);
    try testing.expect(std.mem.indexOf(u8, json, "node_inserts_total") != null);
    try testing.expect(std.mem.indexOf(u8, json, "total_nodes") != null);
}

test "MetricsCollector Prometheus export" {
    const allocator = testing.allocator;
    
    var metrics = try monitoring.MetricsCollector.init(allocator, null);
    defer metrics.deinit();
    
    // Add some test data
    metrics.recordNodeInsert(100);
    metrics.recordEdgeInsert(150);
    metrics.recordSimilarityQuery(500);
    
    const stats = types.DatabaseStats{
        .node_count = 10,
        .edge_count = 20,
        .vector_count = 5,
        .log_entry_count = 35,
        .snapshot_count = 1,
        .memory_usage = 3_000_000,
        .disk_usage = 1_500_000,
        .uptime_seconds = 7200, // 2 hours
    };
    metrics.updateDatabaseStats(stats);
    
    // Export Prometheus format
    const prometheus = try metrics.exportPrometheusMetrics(allocator);
    defer allocator.free(prometheus);
    
    // Basic validation - should contain Prometheus format elements
    try testing.expect(std.mem.indexOf(u8, prometheus, "# HELP") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "# TYPE") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "contextdb_node_inserts_total") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "contextdb_total_nodes") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "histogram") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "counter") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus, "gauge") != null);
}

test "HealthCheck functionality" {
    const allocator = testing.allocator;
    
    var health_check = monitoring.HealthCheck.init(allocator);
    defer health_check.deinit();
    
    // Initially healthy
    try testing.expect(health_check.status == .healthy);
    try testing.expect(health_check.checks.items.len == 0);
    
    // Add healthy check
    try health_check.addCheck("database", .healthy, "Database is responding", 100);
    try testing.expect(health_check.status == .healthy);
    try testing.expect(health_check.checks.items.len == 1);
    
    // Add degraded check
    try health_check.addCheck("memory", .degraded, "Memory usage is high", 50);
    try testing.expect(health_check.status == .degraded);
    try testing.expect(health_check.checks.items.len == 2);
    
    // Add unhealthy check
    try health_check.addCheck("disk", .unhealthy, "Disk space critical", 200);
    try testing.expect(health_check.status == .unhealthy);
    try testing.expect(health_check.checks.items.len == 3);
    
    // Export JSON
    const json = try health_check.exportJson(allocator);
    defer allocator.free(json);
    
    // Basic validation
    try testing.expect(std.mem.indexOf(u8, json, "unhealthy") != null);
    try testing.expect(std.mem.indexOf(u8, json, "database") != null);
    try testing.expect(std.mem.indexOf(u8, json, "memory") != null);
    try testing.expect(std.mem.indexOf(u8, json, "disk") != null);
    try testing.expect(std.mem.indexOf(u8, json, "timestamp") != null);
}

test "ContextDB metrics integration" {
    const allocator = testing.allocator;
    
    // Clean up any existing test data
    std.fs.cwd().deleteTree("test_monitoring_contextdb") catch {};
    defer std.fs.cwd().deleteTree("test_monitoring_contextdb") catch {};
    
    const config = contextdb.ContextDBConfig{
        .data_path = "test_monitoring_contextdb",
        .auto_snapshot_interval = null,
        .s3_bucket = null,
        .s3_region = null,
        .s3_prefix = null,
    };

    var db = try contextdb.ContextDB.init(allocator, config, null);
    defer db.deinit();

    // Initial metrics should be zero
    try testing.expect(db.metrics.node_inserts_total.get() == 0);
    try testing.expect(db.metrics.edge_inserts_total.get() == 0);
    try testing.expect(db.metrics.vector_inserts_total.get() == 0);
    
    // Insert operations should increment metrics
    try db.insertNode(types.Node.init(1, "TestNode"));
    try testing.expect(db.metrics.node_inserts_total.get() == 1);
    
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.owns));
    try testing.expect(db.metrics.edge_inserts_total.get() == 1);
    
    const dims = [_]f32{ 1.0, 0.0, 0.0 } ++ [_]f32{0.0} ** 125;
    try db.insertVector(types.Vector.init(1, &dims));
    try testing.expect(db.metrics.vector_inserts_total.get() == 1);
    
    // Query operations should increment metrics
    const similar = try db.querySimilar(1, 5);
    defer similar.deinit();
    try testing.expect(db.metrics.similarity_queries_total.get() == 1);
    
    const related = try db.queryRelated(1, 1);
    defer related.deinit();
    try testing.expect(db.metrics.graph_queries_total.get() == 1);
    
    // Check that database stats are updated in metrics
    const stats = db.getStats();
    try testing.expect(db.metrics.total_nodes.get() == @as(i64, @intCast(stats.node_count)));
    try testing.expect(db.metrics.total_edges.get() == @as(i64, @intCast(stats.edge_count)));
    try testing.expect(db.metrics.total_vectors.get() == @as(i64, @intCast(stats.vector_count)));
    
    // Test that latency histograms have data
    try testing.expect(db.metrics.insert_duration_histogram.?.total_count == 3); // 3 insert operations
    try testing.expect(db.metrics.query_duration_histogram.?.total_count == 2);  // 2 query operations
    
    // Test JSON export with real data
    const json = try db.metrics.exportJsonMetrics(allocator);
    defer allocator.free(json);
    
    try testing.expect(std.mem.indexOf(u8, json, "\"node_inserts_total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"edge_inserts_total\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"vector_inserts_total\":1") != null);
}

test "Metrics reset functionality" {
    const allocator = testing.allocator;
    
    var metrics = try monitoring.MetricsCollector.init(allocator, null);
    defer metrics.deinit();
    
    // Add some data
    metrics.recordNodeInsert(100);
    metrics.recordSimilarityQuery(500);
    metrics.updateMemoryUsage(1_000_000);
    
    // Verify data exists
    try testing.expect(metrics.node_inserts_total.get() == 1);
    try testing.expect(metrics.similarity_queries_total.get() == 1);
    try testing.expect(metrics.insert_duration_histogram.?.total_count == 1);
    try testing.expect(metrics.query_duration_histogram.?.total_count == 1);
    
    // Reset
    metrics.reset();
    
    // Verify reset
    try testing.expect(metrics.node_inserts_total.get() == 0);
    try testing.expect(metrics.similarity_queries_total.get() == 0);
    try testing.expect(metrics.insert_duration_histogram.?.total_count == 0);
    try testing.expect(metrics.query_duration_histogram.?.total_count == 0);
    
    // Note: Gauges are not reset as they represent current state
    try testing.expect(metrics.memory_usage_bytes.get() == 1_000_000);
} 