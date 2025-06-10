const std = @import("std");

/// Centralized configuration system for Memora
/// Uses simple key=value format for easy parsing without external dependencies
pub const Config = struct {
    // Log configuration
    log_initial_size: usize = 1024 * 1024, // 1MB default
    log_max_size: usize = 1024 * 1024 * 1024, // 1GB default
    
    // Cache configuration
    cache_stats_alpha: f32 = 0.1, // Exponential moving average smoothing factor
    cache_initial_capacity: u32 = 1000, // Initial cache capacity
    cache_load_factor_threshold: f32 = 0.75, // When to resize the cache
    
    // HTTP API configuration
    http_port: u16 = 8080, // Default HTTP API port
    http_request_buffer_size: u32 = 4096, // Request buffer size in bytes
    http_response_buffer_size: u32 = 8192, // Response buffer size in bytes
    http_bind_address: []const u8 = "127.0.0.1", // Bind address
    
    // Health check thresholds
    health_memory_warning_gb: f32 = 1.0, // Memory warning threshold in GB
    health_memory_critical_gb: f32 = 2.0, // Memory critical threshold in GB
    health_error_rate_warning: f32 = 1.0, // Error rate warning threshold (percentage)
    health_error_rate_critical: f32 = 5.0, // Error rate critical threshold (percentage)
    
    // Vector search configuration
    vector_dimensions: u32 = 128, // Dimensionality of vectors
    vector_similarity_threshold: f32 = 0.5, // Default similarity threshold for threshold queries
    
    // HNSW (Hierarchical Navigable Small World) configuration
    hnsw_max_connections: u16 = 16, // Max connections per node in higher layers
    hnsw_max_connections_layer0: u32 = 32, // Max connections per node in layer 0
    hnsw_ef_construction: u32 = 200, // Size of dynamic candidate list during construction
    hnsw_ml_factor: f32 = 0.693147, // Level generation factor (1/ln(2))
    hnsw_random_seed: u64 = 42, // Seed for deterministic HNSW behavior
    hnsw_max_layers: u8 = 16, // Maximum number of layers in HNSW
    
    // Vector clustering configuration
    clustering_max_iterations: u32 = 100, // Maximum iterations for k-means clustering
    
    // Graph traversal configuration
    graph_max_traversal_depth: u8 = 10, // Maximum depth for graph traversal queries
    graph_traversal_timeout_ms: u32 = 5000, // Timeout for graph traversal operations (milliseconds)
    graph_max_queue_size: u32 = 10000, // Maximum queue size for BFS/DFS traversal
    graph_max_neighbors_per_node: u32 = 1000, // Maximum neighbors to process per node
    graph_path_cache_size: u32 = 1000, // Cache size for shortest path queries
    graph_enable_bidirectional_search: bool = true, // Use bidirectional search for shortest paths
    
    // Monitoring and metrics configuration
    metrics_collection_interval_ms: u32 = 1000, // How often to collect system metrics (milliseconds)
    metrics_rate_tracker_window_size: u32 = 60, // Window size for rate calculations (samples)
    metrics_histogram_enable: bool = true, // Enable latency histogram collection
    metrics_export_prometheus: bool = true, // Enable Prometheus metrics export
    metrics_export_json: bool = true, // Enable JSON metrics export
    health_check_interval_ms: u32 = 5000, // Health check execution interval (milliseconds)
    health_check_timeout_ms: u32 = 1000, // Individual health check timeout (milliseconds)
    memory_stats_enable: bool = true, // Enable memory usage tracking
    error_tracking_enable: bool = true, // Enable error rate tracking
    
    // Persistent index configuration  
    persistent_index_enable: bool = true, // Enable persistent indexes for fast startup
    persistent_index_directory: []const u8 = "indexes", // Directory for index files
    persistent_index_sync_interval: u32 = 100, // Sync indexes to disk every N operations
    persistent_index_auto_rebuild: bool = true, // Automatically rebuild corrupted indexes from log
    persistent_index_memory_alignment: u32 = 16384, // Memory alignment for mmap operations (16KB)
    persistent_index_checksum_validation: bool = true, // Enable CRC32 checksum validation
    persistent_index_auto_cleanup: bool = true, // Automatically cleanup old index files
    persistent_index_max_file_size_mb: u32 = 1024, // Maximum size per index file (MB)
    persistent_index_compression_enable: bool = true, // Enable index compression
    persistent_index_sync_on_shutdown: bool = true, // Force sync indexes on database shutdown
    
    // Compression configuration
    compression_vector_quantization_scale: f32 = 255.0, // Vector quantization scale factor
    compression_vector_quantization_offset: f32 = 0.0, // Vector quantization offset
    compression_enable_delta_encoding: bool = true, // Enable delta encoding for IDs
    compression_rle_min_run_length: u8 = 3, // Minimum run length for RLE compression
    compression_enable_checksums: bool = true, // Enable compression checksums
    compression_parallel_enable: bool = false, // Enable parallel compression (future)
    compression_level: u8 = 1, // Compression level (1=fast, 9=best compression)
    compression_min_size_threshold: usize = 1024, // Minimum size to trigger compression (bytes)
    compression_min_ratio_threshold: f32 = 1.2, // Minimum compression ratio to use compression
    
    // Snapshot system configuration
    snapshot_auto_interval: u32 = 0, // Create snapshot every N operations (0 = disabled)
    snapshot_max_metadata_size_mb: u32 = 10, // Maximum size for snapshot metadata files (MB)
    snapshot_compression_enable: bool = true, // Enable snapshot compression
    snapshot_cleanup_keep_count: u32 = 10, // Keep this many snapshots during cleanup
    snapshot_cleanup_auto_enable: bool = true, // Automatically cleanup old snapshots
    snapshot_binary_format_enable: bool = true, // Use binary format for vector data (vs JSON)
    snapshot_concurrent_writes: bool = false, // Enable concurrent snapshot writes (future feature)
    snapshot_verify_checksums: bool = true, // Verify data integrity during snapshot load
    
    // S3 integration configuration
    s3_enable: bool = false, // Enable S3 integration
    s3_bucket: []const u8 = "", // S3 bucket name
    s3_region: []const u8 = "us-east-1", // AWS region
    s3_prefix: []const u8 = "memora/", // S3 prefix for all files
    s3_upload_timeout_ms: u32 = 300000, // Upload timeout in milliseconds (5 minutes)
    s3_download_timeout_ms: u32 = 180000, // Download timeout in milliseconds (3 minutes)
    s3_max_retries: u32 = 3, // Maximum retry attempts for S3 operations
    s3_cleanup_auto_enable: bool = true, // Automatically cleanup old S3 snapshots
    s3_verify_uploads: bool = true, // Verify S3 uploads by downloading and comparing checksums
    s3_multipart_threshold_mb: u32 = 100, // Use multipart upload for files larger than this (MB)
    
    // Raft consensus configuration
    raft_enable: bool = false, // Enable Raft consensus for distributed operation
    raft_node_id: u64 = 1, // Current node ID in the cluster
    raft_port: u16 = 8001, // Port for Raft consensus communication
    raft_election_timeout_min_ms: u32 = 150, // Minimum election timeout (milliseconds)
    raft_election_timeout_max_ms: u32 = 300, // Maximum election timeout (milliseconds) 
    raft_heartbeat_interval_ms: u32 = 50, // Heartbeat interval for leader (milliseconds)
    raft_network_timeout_ms: u32 = 30000, // Network operation timeout (30 seconds)
    raft_log_replication_batch_size: u32 = 100, // Batch size for log replication
    raft_snapshot_threshold: u32 = 10000, // Create snapshot after N log entries
    raft_max_append_entries: u32 = 50, // Maximum entries per AppendEntries RPC
    raft_leadership_transfer_timeout_ms: u32 = 5000, // Leadership transfer timeout
    raft_pre_vote_enable: bool = true, // Enable pre-vote extension to prevent disruptions
    raft_checksum_enable: bool = true, // Enable CRC32 checksums for network messages
    raft_compression_enable: bool = false, // Enable compression for large messages
    
    // Distributed cluster configuration
    cluster_replication_factor: u8 = 3, // How many copies of data to maintain
    cluster_read_quorum: u8 = 2, // Minimum nodes required for read operations
    cluster_write_quorum: u8 = 2, // Minimum nodes required for write operations
    cluster_auto_join: bool = true, // Automatically join cluster on startup
    cluster_bootstrap_expect: u8 = 3, // Expected cluster size for bootstrapping
    cluster_failure_detection_ms: u32 = 10000, // Time to detect node failures
    cluster_split_brain_protection: bool = true, // Prevent split-brain scenarios
    
    /// Parse configuration from a file
    pub fn fromFile(allocator: std.mem.Allocator, config_path: []const u8) !Config {
        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Return default config if file doesn't exist
                return Config{};
            },
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB config file
        defer allocator.free(content);

        return try parseFromString(content);
    }

    /// Parse configuration from a string
    pub fn parseFromString(content: []const u8) !Config {
        var config = Config{};
        
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            // Parse key=value pairs
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

                try config.setKeyValue(key, value);
            }
        }

        return config;
    }

    /// Set a configuration value by key-value pair
    fn setKeyValue(self: *Config, key: []const u8, value: []const u8) !void {
        // Log configuration
        if (std.mem.eql(u8, key, "log_initial_size")) {
            self.log_initial_size = try parseSize(value);
        } else if (std.mem.eql(u8, key, "log_max_size")) {
            self.log_max_size = try parseSize(value);
        }
        // Cache configuration
        else if (std.mem.eql(u8, key, "cache_stats_alpha")) {
            self.cache_stats_alpha = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "cache_initial_capacity")) {
            self.cache_initial_capacity = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "cache_load_factor_threshold")) {
            self.cache_load_factor_threshold = try parseFloat(value);
        }
        // HTTP API configuration
        else if (std.mem.eql(u8, key, "http_port")) {
            self.http_port = try parseInt(u16, value);
        } else if (std.mem.eql(u8, key, "http_request_buffer_size")) {
            self.http_request_buffer_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "http_response_buffer_size")) {
            self.http_response_buffer_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "http_bind_address")) {
            // For string values, we can't easily store them in the config struct
            // due to lifetime issues. For now, we ignore string configs.
            // In production, this would require allocator-managed strings.
        }
        // Health check configuration
        else if (std.mem.eql(u8, key, "health_memory_warning_gb")) {
            self.health_memory_warning_gb = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "health_memory_critical_gb")) {
            self.health_memory_critical_gb = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "health_error_rate_warning")) {
            self.health_error_rate_warning = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "health_error_rate_critical")) {
            self.health_error_rate_critical = try parseFloat(value);
        }
        // Vector search configuration
        else if (std.mem.eql(u8, key, "vector_dimensions")) {
            self.vector_dimensions = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "vector_similarity_threshold")) {
            self.vector_similarity_threshold = try parseFloat(value);
        }
        // HNSW configuration
        else if (std.mem.eql(u8, key, "hnsw_max_connections")) {
            self.hnsw_max_connections = try parseInt(u16, value);
        } else if (std.mem.eql(u8, key, "hnsw_max_connections_layer0")) {
            self.hnsw_max_connections_layer0 = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "hnsw_ef_construction")) {
            self.hnsw_ef_construction = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "hnsw_ml_factor")) {
            self.hnsw_ml_factor = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "hnsw_random_seed")) {
            self.hnsw_random_seed = try parseInt(u64, value);
        } else if (std.mem.eql(u8, key, "hnsw_max_layers")) {
            self.hnsw_max_layers = try parseInt(u8, value);
        }
        // Vector clustering configuration
        else if (std.mem.eql(u8, key, "clustering_max_iterations")) {
            self.clustering_max_iterations = try parseInt(u32, value);
        }
        // Graph traversal configuration
        else if (std.mem.eql(u8, key, "graph_max_traversal_depth")) {
            self.graph_max_traversal_depth = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "graph_traversal_timeout_ms")) {
            self.graph_traversal_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "graph_max_queue_size")) {
            self.graph_max_queue_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "graph_max_neighbors_per_node")) {
            self.graph_max_neighbors_per_node = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "graph_path_cache_size")) {
            self.graph_path_cache_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "graph_enable_bidirectional_search")) {
            self.graph_enable_bidirectional_search = try parseBool(value);
        }
        // Monitoring and metrics configuration
        else if (std.mem.eql(u8, key, "metrics_collection_interval_ms")) {
            self.metrics_collection_interval_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "metrics_rate_tracker_window_size")) {
            self.metrics_rate_tracker_window_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "metrics_histogram_enable")) {
            self.metrics_histogram_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "metrics_export_prometheus")) {
            self.metrics_export_prometheus = try parseBool(value);
        } else if (std.mem.eql(u8, key, "metrics_export_json")) {
            self.metrics_export_json = try parseBool(value);
        } else if (std.mem.eql(u8, key, "health_check_interval_ms")) {
            self.health_check_interval_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "health_check_timeout_ms")) {
            self.health_check_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "memory_stats_enable")) {
            self.memory_stats_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "error_tracking_enable")) {
            self.error_tracking_enable = try parseBool(value);
        }
        // Persistent index configuration  
        else if (std.mem.eql(u8, key, "persistent_index_enable")) {
            self.persistent_index_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "persistent_index_directory")) {
            self.persistent_index_directory = value;
        } else if (std.mem.eql(u8, key, "persistent_index_sync_interval")) {
            self.persistent_index_sync_interval = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "persistent_index_auto_rebuild")) {
            self.persistent_index_auto_rebuild = try parseBool(value);
        } else if (std.mem.eql(u8, key, "persistent_index_memory_alignment")) {
            self.persistent_index_memory_alignment = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "persistent_index_checksum_validation")) {
            self.persistent_index_checksum_validation = try parseBool(value);
        } else if (std.mem.eql(u8, key, "persistent_index_auto_cleanup")) {
            self.persistent_index_auto_cleanup = try parseBool(value);
        } else if (std.mem.eql(u8, key, "persistent_index_max_file_size_mb")) {
            self.persistent_index_max_file_size_mb = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "persistent_index_compression_enable")) {
            self.persistent_index_compression_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "persistent_index_sync_on_shutdown")) {
            self.persistent_index_sync_on_shutdown = try parseBool(value);
        }
        // Compression configuration
        else if (std.mem.eql(u8, key, "compression_vector_quantization_scale")) {
            self.compression_vector_quantization_scale = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "compression_vector_quantization_offset")) {
            self.compression_vector_quantization_offset = try parseFloat(value);
        } else if (std.mem.eql(u8, key, "compression_enable_delta_encoding")) {
            self.compression_enable_delta_encoding = try parseBool(value);
        } else if (std.mem.eql(u8, key, "compression_rle_min_run_length")) {
            self.compression_rle_min_run_length = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "compression_enable_checksums")) {
            self.compression_enable_checksums = try parseBool(value);
        } else if (std.mem.eql(u8, key, "compression_parallel_enable")) {
            self.compression_parallel_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "compression_level")) {
            self.compression_level = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "compression_min_size_threshold")) {
            self.compression_min_size_threshold = try parseInt(usize, value);
        } else if (std.mem.eql(u8, key, "compression_min_ratio_threshold")) {
            self.compression_min_ratio_threshold = try parseFloat(value);
        }
        // Snapshot system configuration
        else if (std.mem.eql(u8, key, "snapshot_auto_interval")) {
            self.snapshot_auto_interval = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "snapshot_max_metadata_size_mb")) {
            self.snapshot_max_metadata_size_mb = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "snapshot_compression_enable")) {
            self.snapshot_compression_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "snapshot_cleanup_keep_count")) {
            self.snapshot_cleanup_keep_count = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "snapshot_cleanup_auto_enable")) {
            self.snapshot_cleanup_auto_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "snapshot_binary_format_enable")) {
            self.snapshot_binary_format_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "snapshot_concurrent_writes")) {
            self.snapshot_concurrent_writes = try parseBool(value);
        } else if (std.mem.eql(u8, key, "snapshot_verify_checksums")) {
            self.snapshot_verify_checksums = try parseBool(value);
        }
        // S3 integration configuration
        else if (std.mem.eql(u8, key, "s3_enable")) {
            self.s3_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "s3_bucket")) {
            self.s3_bucket = value;
        } else if (std.mem.eql(u8, key, "s3_region")) {
            self.s3_region = value;
        } else if (std.mem.eql(u8, key, "s3_prefix")) {
            self.s3_prefix = value;
        } else if (std.mem.eql(u8, key, "s3_upload_timeout_ms")) {
            self.s3_upload_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "s3_download_timeout_ms")) {
            self.s3_download_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "s3_max_retries")) {
            self.s3_max_retries = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "s3_cleanup_auto_enable")) {
            self.s3_cleanup_auto_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "s3_verify_uploads")) {
            self.s3_verify_uploads = try parseBool(value);
        } else if (std.mem.eql(u8, key, "s3_multipart_threshold_mb")) {
            self.s3_multipart_threshold_mb = try parseInt(u32, value);
        }
        // Raft consensus configuration
        else if (std.mem.eql(u8, key, "raft_enable")) {
            self.raft_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "raft_node_id")) {
            self.raft_node_id = try parseInt(u64, value);
        } else if (std.mem.eql(u8, key, "raft_port")) {
            self.raft_port = try parseInt(u16, value);
        } else if (std.mem.eql(u8, key, "raft_election_timeout_min_ms")) {
            self.raft_election_timeout_min_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_election_timeout_max_ms")) {
            self.raft_election_timeout_max_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_heartbeat_interval_ms")) {
            self.raft_heartbeat_interval_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_network_timeout_ms")) {
            self.raft_network_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_log_replication_batch_size")) {
            self.raft_log_replication_batch_size = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_snapshot_threshold")) {
            self.raft_snapshot_threshold = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_max_append_entries")) {
            self.raft_max_append_entries = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_leadership_transfer_timeout_ms")) {
            self.raft_leadership_transfer_timeout_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "raft_pre_vote_enable")) {
            self.raft_pre_vote_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "raft_checksum_enable")) {
            self.raft_checksum_enable = try parseBool(value);
        } else if (std.mem.eql(u8, key, "raft_compression_enable")) {
            self.raft_compression_enable = try parseBool(value);
        }
        // Distributed cluster configuration
        else if (std.mem.eql(u8, key, "cluster_replication_factor")) {
            self.cluster_replication_factor = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "cluster_read_quorum")) {
            self.cluster_read_quorum = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "cluster_write_quorum")) {
            self.cluster_write_quorum = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "cluster_auto_join")) {
            self.cluster_auto_join = try parseBool(value);
        } else if (std.mem.eql(u8, key, "cluster_bootstrap_expect")) {
            self.cluster_bootstrap_expect = try parseInt(u8, value);
        } else if (std.mem.eql(u8, key, "cluster_failure_detection_ms")) {
            self.cluster_failure_detection_ms = try parseInt(u32, value);
        } else if (std.mem.eql(u8, key, "cluster_split_brain_protection")) {
            self.cluster_split_brain_protection = try parseBool(value);
        }
        // Future configuration keys will be added here
        // No error for unknown keys - allows forward compatibility
    }

    /// Parse size values with unit suffixes (e.g., "1MB", "2GB", "512KB")
    fn parseSize(value: []const u8) !usize {
        if (value.len == 0) return error.InvalidSize;

        // Check for unit suffixes
        if (std.mem.endsWith(u8, value, "GB") or std.mem.endsWith(u8, value, "gb")) {
            const num_str = value[0..value.len - 2];
            const num = try std.fmt.parseInt(usize, num_str, 10);
            return num * 1024 * 1024 * 1024;
        } else if (std.mem.endsWith(u8, value, "MB") or std.mem.endsWith(u8, value, "mb")) {
            const num_str = value[0..value.len - 2];
            const num = try std.fmt.parseInt(usize, num_str, 10);
            return num * 1024 * 1024;
        } else if (std.mem.endsWith(u8, value, "KB") or std.mem.endsWith(u8, value, "kb")) {
            const num_str = value[0..value.len - 2];
            const num = try std.fmt.parseInt(usize, num_str, 10);
            return num * 1024;
        } else {
            // No suffix, parse as raw bytes
            return try std.fmt.parseInt(usize, value, 10);
        }
    }

    /// Parse integer values
    fn parseInt(comptime T: type, value: []const u8) !T {
        if (value.len == 0) return error.InvalidInteger;
        return try std.fmt.parseInt(T, value, 10);
    }

    /// Parse float values
    fn parseFloat(value: []const u8) !f32 {
        if (value.len == 0) return error.InvalidFloat;

        const num = try std.fmt.parseFloat(f32, value);
        return num;
    }

    /// Parse boolean values
    fn parseBool(value: []const u8) !bool {
        if (value.len == 0) return error.InvalidBool;
        if (std.mem.eql(u8, value, "true")) {
            return true;
        } else if (std.mem.eql(u8, value, "false")) {
            return false;
        } else {
            return error.InvalidBool;
        }
    }

    /// Save configuration to a file
    pub fn toFile(self: Config, config_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(config_path, .{});
        defer file.close();

        const writer = file.writer();
        
        try writer.print("# Memora Configuration\n", .{});
        try writer.print("# Log settings\n", .{});
        try writer.print("log_initial_size = {}\n", .{self.log_initial_size});
        try writer.print("log_max_size = {}\n", .{self.log_max_size});
        try writer.print("\n", .{});
        try writer.print("# Cache settings\n", .{});
        try writer.print("cache_stats_alpha = {}\n", .{self.cache_stats_alpha});
        try writer.print("cache_initial_capacity = {}\n", .{self.cache_initial_capacity});
        try writer.print("cache_load_factor_threshold = {}\n", .{self.cache_load_factor_threshold});
        try writer.print("\n", .{});
        try writer.print("# HTTP API settings\n", .{});
        try writer.print("http_port = {}\n", .{self.http_port});
        try writer.print("http_request_buffer_size = {}\n", .{self.http_request_buffer_size});
        try writer.print("http_response_buffer_size = {}\n", .{self.http_response_buffer_size});
        try writer.print("http_bind_address = {s}\n", .{self.http_bind_address});
        try writer.print("\n", .{});
        try writer.print("# Health check thresholds\n", .{});
        try writer.print("health_memory_warning_gb = {}\n", .{self.health_memory_warning_gb});
        try writer.print("health_memory_critical_gb = {}\n", .{self.health_memory_critical_gb});
        try writer.print("health_error_rate_warning = {}\n", .{self.health_error_rate_warning});
        try writer.print("health_error_rate_critical = {}\n", .{self.health_error_rate_critical});
        try writer.print("\n", .{});
        try writer.print("# Vector search configuration\n", .{});
        try writer.print("vector_dimensions = {}\n", .{self.vector_dimensions});
        try writer.print("vector_similarity_threshold = {}\n", .{self.vector_similarity_threshold});
        try writer.print("\n", .{});
        try writer.print("# HNSW configuration\n", .{});
        try writer.print("hnsw_max_connections = {}\n", .{self.hnsw_max_connections});
        try writer.print("hnsw_max_connections_layer0 = {}\n", .{self.hnsw_max_connections_layer0});
        try writer.print("hnsw_ef_construction = {}\n", .{self.hnsw_ef_construction});
        try writer.print("hnsw_ml_factor = {}\n", .{self.hnsw_ml_factor});
        try writer.print("hnsw_random_seed = {}\n", .{self.hnsw_random_seed});
        try writer.print("hnsw_max_layers = {}\n", .{self.hnsw_max_layers});
        try writer.print("\n", .{});
        try writer.print("# Vector clustering configuration\n", .{});
        try writer.print("clustering_max_iterations = {}\n", .{self.clustering_max_iterations});
        try writer.print("\n", .{});
        try writer.print("# Graph traversal configuration\n", .{});
        try writer.print("graph_max_traversal_depth = {}\n", .{self.graph_max_traversal_depth});
        try writer.print("graph_traversal_timeout_ms = {}\n", .{self.graph_traversal_timeout_ms});
        try writer.print("graph_max_queue_size = {}\n", .{self.graph_max_queue_size});
        try writer.print("graph_max_neighbors_per_node = {}\n", .{self.graph_max_neighbors_per_node});
        try writer.print("graph_path_cache_size = {}\n", .{self.graph_path_cache_size});
        try writer.print("graph_enable_bidirectional_search = {}\n", .{self.graph_enable_bidirectional_search});
        try writer.print("\n", .{});
        try writer.print("# Monitoring and metrics configuration\n", .{});
        try writer.print("metrics_collection_interval_ms = {}\n", .{self.metrics_collection_interval_ms});
        try writer.print("metrics_rate_tracker_window_size = {}\n", .{self.metrics_rate_tracker_window_size});
        try writer.print("metrics_histogram_enable = {}\n", .{self.metrics_histogram_enable});
        try writer.print("metrics_export_prometheus = {}\n", .{self.metrics_export_prometheus});
        try writer.print("metrics_export_json = {}\n", .{self.metrics_export_json});
        try writer.print("health_check_interval_ms = {}\n", .{self.health_check_interval_ms});
        try writer.print("health_check_timeout_ms = {}\n", .{self.health_check_timeout_ms});
        try writer.print("memory_stats_enable = {}\n", .{self.memory_stats_enable});
        try writer.print("error_tracking_enable = {}\n", .{self.error_tracking_enable});
        try writer.print("\n", .{});
        try writer.print("# Persistent index configuration\n", .{});
        try writer.print("persistent_index_enable = {}\n", .{self.persistent_index_enable});
        try writer.print("persistent_index_directory = {s}\n", .{self.persistent_index_directory});
        try writer.print("persistent_index_sync_interval = {}\n", .{self.persistent_index_sync_interval});
        try writer.print("persistent_index_auto_rebuild = {}\n", .{self.persistent_index_auto_rebuild});
        try writer.print("persistent_index_memory_alignment = {}\n", .{self.persistent_index_memory_alignment});
        try writer.print("persistent_index_checksum_validation = {}\n", .{self.persistent_index_checksum_validation});
        try writer.print("persistent_index_auto_cleanup = {}\n", .{self.persistent_index_auto_cleanup});
        try writer.print("persistent_index_max_file_size_mb = {}\n", .{self.persistent_index_max_file_size_mb});
        try writer.print("persistent_index_compression_enable = {}\n", .{self.persistent_index_compression_enable});
        try writer.print("persistent_index_sync_on_shutdown = {}\n", .{self.persistent_index_sync_on_shutdown});
        try writer.print("\n", .{});
        try writer.print("# Compression configuration\n", .{});
        try writer.print("compression_vector_quantization_scale = {}\n", .{self.compression_vector_quantization_scale});
        try writer.print("compression_vector_quantization_offset = {}\n", .{self.compression_vector_quantization_offset});
        try writer.print("compression_enable_delta_encoding = {}\n", .{self.compression_enable_delta_encoding});
        try writer.print("compression_rle_min_run_length = {}\n", .{self.compression_rle_min_run_length});
        try writer.print("compression_enable_checksums = {}\n", .{self.compression_enable_checksums});
        try writer.print("compression_parallel_enable = {}\n", .{self.compression_parallel_enable});
        try writer.print("compression_level = {}\n", .{self.compression_level});
        try writer.print("compression_min_size_threshold = {}\n", .{self.compression_min_size_threshold});
        try writer.print("compression_min_ratio_threshold = {}\n", .{self.compression_min_ratio_threshold});
        try writer.print("\n", .{});
        try writer.print("# Snapshot system configuration\n", .{});
        try writer.print("snapshot_auto_interval = {}\n", .{self.snapshot_auto_interval});
        try writer.print("snapshot_max_metadata_size_mb = {}\n", .{self.snapshot_max_metadata_size_mb});
        try writer.print("snapshot_compression_enable = {}\n", .{self.snapshot_compression_enable});
        try writer.print("snapshot_cleanup_keep_count = {}\n", .{self.snapshot_cleanup_keep_count});
        try writer.print("snapshot_cleanup_auto_enable = {}\n", .{self.snapshot_cleanup_auto_enable});
        try writer.print("snapshot_binary_format_enable = {}\n", .{self.snapshot_binary_format_enable});
        try writer.print("snapshot_concurrent_writes = {}\n", .{self.snapshot_concurrent_writes});
        try writer.print("snapshot_verify_checksums = {}\n", .{self.snapshot_verify_checksums});
        try writer.print("\n", .{});
        try writer.print("# S3 integration configuration\n", .{});
        try writer.print("s3_enable = {}\n", .{self.s3_enable});
        try writer.print("s3_bucket = {s}\n", .{self.s3_bucket});
        try writer.print("s3_region = {s}\n", .{self.s3_region});
        try writer.print("s3_prefix = {s}\n", .{self.s3_prefix});
        try writer.print("s3_upload_timeout_ms = {}\n", .{self.s3_upload_timeout_ms});
        try writer.print("s3_download_timeout_ms = {}\n", .{self.s3_download_timeout_ms});
        try writer.print("s3_max_retries = {}\n", .{self.s3_max_retries});
        try writer.print("s3_cleanup_auto_enable = {}\n", .{self.s3_cleanup_auto_enable});
        try writer.print("s3_verify_uploads = {}\n", .{self.s3_verify_uploads});
        try writer.print("s3_multipart_threshold_mb = {}\n", .{self.s3_multipart_threshold_mb});
        try writer.print("\n", .{});
        try writer.print("# Raft consensus configuration\n", .{});
        try writer.print("raft_enable = {}\n", .{self.raft_enable});
        try writer.print("raft_node_id = {}\n", .{self.raft_node_id});
        try writer.print("raft_port = {}\n", .{self.raft_port});
        try writer.print("raft_election_timeout_min_ms = {}\n", .{self.raft_election_timeout_min_ms});
        try writer.print("raft_election_timeout_max_ms = {}\n", .{self.raft_election_timeout_max_ms});
        try writer.print("raft_heartbeat_interval_ms = {}\n", .{self.raft_heartbeat_interval_ms});
        try writer.print("raft_network_timeout_ms = {}\n", .{self.raft_network_timeout_ms});
        try writer.print("raft_log_replication_batch_size = {}\n", .{self.raft_log_replication_batch_size});
        try writer.print("raft_snapshot_threshold = {}\n", .{self.raft_snapshot_threshold});
        try writer.print("raft_max_append_entries = {}\n", .{self.raft_max_append_entries});
        try writer.print("raft_leadership_transfer_timeout_ms = {}\n", .{self.raft_leadership_transfer_timeout_ms});
        try writer.print("raft_pre_vote_enable = {}\n", .{self.raft_pre_vote_enable});
        try writer.print("raft_checksum_enable = {}\n", .{self.raft_checksum_enable});
        try writer.print("raft_compression_enable = {}\n", .{self.raft_compression_enable});
        try writer.print("\n", .{});
        try writer.print("# Distributed cluster configuration\n", .{});
        try writer.print("cluster_replication_factor = {}\n", .{self.cluster_replication_factor});
        try writer.print("cluster_read_quorum = {}\n", .{self.cluster_read_quorum});
        try writer.print("cluster_write_quorum = {}\n", .{self.cluster_write_quorum});
        try writer.print("cluster_auto_join = {}\n", .{self.cluster_auto_join});
        try writer.print("cluster_bootstrap_expect = {}\n", .{self.cluster_bootstrap_expect});
        try writer.print("cluster_failure_detection_ms = {}\n", .{self.cluster_failure_detection_ms});
        try writer.print("cluster_split_brain_protection = {}\n", .{self.cluster_split_brain_protection});
        try writer.print("\n", .{});
        try writer.print("# Future configuration sections will be added here\n", .{});
    }

    /// Create a default configuration file if it doesn't exist
    pub fn createDefaultIfMissing(config_path: []const u8) !void {
        // Check if file exists
        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Create default config
                const default_config = Config{};
                try default_config.toFile(config_path);
                return;
            },
            else => return err,
        };
        file.close(); // File exists, nothing to do
    }
};

// Tests
test "Config default values" {
    const config = Config{};
    try std.testing.expect(config.log_initial_size == 1024 * 1024); // 1MB
    try std.testing.expect(config.log_max_size == 1024 * 1024 * 1024); // 1GB
}

test "Config parseFromString basic" {
    const config_str = 
        \\# Test configuration
        \\log_initial_size = 2097152
        \\log_max_size = 2147483648
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.log_initial_size == 2097152); // 2MB
    try std.testing.expect(config.log_max_size == 2147483648); // 2GB
}

test "Config parseFromString with units" {
    const config_str = 
        \\log_initial_size = 2MB
        \\log_max_size = 2GB
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.log_initial_size == 2 * 1024 * 1024); // 2MB
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024); // 2GB
}

test "Config parseFromString with comments and whitespace" {
    const config_str = 
        \\# This is a comment
        \\
        \\  log_initial_size   =   4MB   
        \\
        \\# Another comment
        \\  log_max_size = 8GB  
        \\
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024); // 4MB
    try std.testing.expect(config.log_max_size == 8 * 1024 * 1024 * 1024); // 8GB
}

test "Config parseSize function" {
    try std.testing.expect(try Config.parseSize("1024") == 1024);
    try std.testing.expect(try Config.parseSize("1KB") == 1024);
    try std.testing.expect(try Config.parseSize("1MB") == 1024 * 1024);
    try std.testing.expect(try Config.parseSize("1GB") == 1024 * 1024 * 1024);
    try std.testing.expect(try Config.parseSize("2mb") == 2 * 1024 * 1024);
    try std.testing.expect(try Config.parseSize("3gb") == 3 * 1024 * 1024 * 1024);
}

test "Config unknown keys are ignored" {
    const config_str = 
        \\log_initial_size = 1MB
        \\unknown_key = some_value
        \\log_max_size = 2GB
        \\another_unknown = 123
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.log_initial_size == 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
}

test "Config file operations" {
    const allocator = std.testing.allocator;
    const test_config_path = "test_config.conf";
    
    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_config_path) catch {};
    defer std.fs.cwd().deleteFile(test_config_path) catch {};
    
    // Create default config
    try Config.createDefaultIfMissing(test_config_path);
    
    // Load config from file
    const config = try Config.fromFile(allocator, test_config_path);
    try std.testing.expect(config.log_initial_size == 1024 * 1024);
    try std.testing.expect(config.log_max_size == 1024 * 1024 * 1024);
}

test "Config cache configuration" {
    const config_str = 
        \\# Cache configuration test
        \\cache_stats_alpha = 0.2
        \\cache_initial_capacity = 2000
        \\cache_load_factor_threshold = 0.8
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.cache_stats_alpha == 0.2);
    try std.testing.expect(config.cache_initial_capacity == 2000);
    try std.testing.expect(config.cache_load_factor_threshold == 0.8);
}

test "Config parseFloat function" {
    try std.testing.expect(try Config.parseFloat("0.1") == 0.1);
    try std.testing.expect(try Config.parseFloat("0.75") == 0.75);
    try std.testing.expect(try Config.parseFloat("1.0") == 1.0);
    try std.testing.expect(try Config.parseFloat("0.0") == 0.0);
}

test "Config parseInt function" {
    try std.testing.expect(try Config.parseInt(u32, "1000") == 1000);
    try std.testing.expect(try Config.parseInt(u32, "0") == 0);
    try std.testing.expect(try Config.parseInt(u32, "65535") == 65535);
    try std.testing.expect(try Config.parseInt(u16, "1000") == 1000);
}

test "Config mixed log and cache configuration" {
    const config_str = 
        \\# Mixed configuration
        \\log_initial_size = 2MB
        \\cache_stats_alpha = 0.15
        \\log_max_size = 512MB
        \\cache_initial_capacity = 5000
        \\cache_load_factor_threshold = 0.9
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 2 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 512 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.15);
    try std.testing.expect(config.cache_initial_capacity == 5000);
    try std.testing.expect(config.cache_load_factor_threshold == 0.9);
}

test "Config HTTP API configuration" {
    const config_str = 
        \\# HTTP API configuration test
        \\http_port = 9090
        \\http_request_buffer_size = 8192
        \\http_response_buffer_size = 16384
        \\http_bind_address = 0.0.0.0
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.http_port == 9090);
    try std.testing.expect(config.http_request_buffer_size == 8192);
    try std.testing.expect(config.http_response_buffer_size == 16384);
    // Note: http_bind_address is ignored in current implementation
}

test "Config health check thresholds" {
    const config_str = 
        \\# Health check configuration test
        \\health_memory_warning_gb = 0.5
        \\health_memory_critical_gb = 1.5
        \\health_error_rate_warning = 2.5
        \\health_error_rate_critical = 10.0
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.health_memory_warning_gb == 0.5);
    try std.testing.expect(config.health_memory_critical_gb == 1.5);
    try std.testing.expect(config.health_error_rate_warning == 2.5);
    try std.testing.expect(config.health_error_rate_critical == 10.0);
}

test "Config default HTTP values" {
    const config = Config{};
    try std.testing.expect(config.http_port == 8080);
    try std.testing.expect(config.http_request_buffer_size == 4096);
    try std.testing.expect(config.http_response_buffer_size == 8192);
    try std.testing.expect(config.health_memory_warning_gb == 1.0);
    try std.testing.expect(config.health_memory_critical_gb == 2.0);
    try std.testing.expect(config.health_error_rate_warning == 1.0);
    try std.testing.expect(config.health_error_rate_critical == 5.0);
}

test "Config comprehensive mixed configuration" {
    const config_str = 
        \\# Comprehensive configuration test
        \\# Log settings
        \\log_initial_size = 4MB
        \\log_max_size = 2GB
        \\
        \\# Cache settings  
        \\cache_stats_alpha = 0.25
        \\cache_initial_capacity = 2500
        \\cache_load_factor_threshold = 0.85
        \\
        \\# HTTP API settings
        \\http_port = 3000
        \\http_request_buffer_size = 2048
        \\http_response_buffer_size = 4096
        \\
        \\# Health check settings
        \\health_memory_warning_gb = 0.8
        \\health_memory_critical_gb = 1.6
        \\health_error_rate_warning = 3.0
        \\health_error_rate_critical = 8.0
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.25);
    try std.testing.expect(config.cache_initial_capacity == 2500);
    try std.testing.expect(config.cache_load_factor_threshold == 0.85);
    
    // HTTP API settings
    try std.testing.expect(config.http_port == 3000);
    try std.testing.expect(config.http_request_buffer_size == 2048);
    try std.testing.expect(config.http_response_buffer_size == 4096);
    
    // Health check settings
    try std.testing.expect(config.health_memory_warning_gb == 0.8);
    try std.testing.expect(config.health_memory_critical_gb == 1.6);
    try std.testing.expect(config.health_error_rate_warning == 3.0);
    try std.testing.expect(config.health_error_rate_critical == 8.0);
}

test "Config vector search configuration" {
    const config_str = 
        \\# Vector search configuration test
        \\vector_dimensions = 256
        \\vector_similarity_threshold = 0.8
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.vector_dimensions == 256);
    try std.testing.expect(config.vector_similarity_threshold == 0.8);
}

test "Config HNSW configuration" {
    const config_str = 
        \\# HNSW configuration test
        \\hnsw_max_connections = 24
        \\hnsw_max_connections_layer0 = 48
        \\hnsw_ef_construction = 400
        \\hnsw_ml_factor = 0.5
        \\hnsw_random_seed = 123456
        \\hnsw_max_layers = 20
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.hnsw_max_connections == 24);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 48);
    try std.testing.expect(config.hnsw_ef_construction == 400);
    try std.testing.expect(config.hnsw_ml_factor == 0.5);
    try std.testing.expect(config.hnsw_random_seed == 123456);
    try std.testing.expect(config.hnsw_max_layers == 20);
}

test "Config vector clustering configuration" {
    const config_str = 
        \\# Vector clustering configuration test
        \\clustering_max_iterations = 150
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.clustering_max_iterations == 150);
}

test "Config default vector values" {
    const config = Config{};
    try std.testing.expect(config.vector_dimensions == 128);
    try std.testing.expect(config.vector_similarity_threshold == 0.5);
    try std.testing.expect(config.hnsw_max_connections == 16);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 32);
    try std.testing.expect(config.hnsw_ef_construction == 200);
    try std.testing.expect(config.hnsw_ml_factor == 0.693147);
    try std.testing.expect(config.hnsw_random_seed == 42);
    try std.testing.expect(config.hnsw_max_layers == 16);
    try std.testing.expect(config.clustering_max_iterations == 100);
}

test "Config comprehensive vector configuration" {
    const config_str = 
        \\# Comprehensive vector configuration test
        \\# Vector settings
        \\vector_dimensions = 512
        \\vector_similarity_threshold = 0.7
        \\
        \\# HNSW settings
        \\hnsw_max_connections = 20
        \\hnsw_max_connections_layer0 = 40
        \\hnsw_ef_construction = 300
        \\hnsw_ml_factor = 0.8
        \\hnsw_random_seed = 987654
        \\hnsw_max_layers = 12
        \\
        \\# Clustering settings
        \\clustering_max_iterations = 200
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Vector settings
    try std.testing.expect(config.vector_dimensions == 512);
    try std.testing.expect(config.vector_similarity_threshold == 0.7);
    
    // HNSW settings
    try std.testing.expect(config.hnsw_max_connections == 20);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 40);
    try std.testing.expect(config.hnsw_ef_construction == 300);
    try std.testing.expect(config.hnsw_ml_factor == 0.8);
    try std.testing.expect(config.hnsw_random_seed == 987654);
    try std.testing.expect(config.hnsw_max_layers == 12);
    
    // Clustering settings
    try std.testing.expect(config.clustering_max_iterations == 200);
}

test "Config graph traversal configuration" {
    const config_str = 
        \\# Graph traversal configuration test
        \\graph_max_traversal_depth = 15
        \\graph_traversal_timeout_ms = 10000
        \\graph_max_queue_size = 50000
        \\graph_max_neighbors_per_node = 2000
        \\graph_path_cache_size = 5000
        \\graph_enable_bidirectional_search = false
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.graph_max_traversal_depth == 15);
    try std.testing.expect(config.graph_traversal_timeout_ms == 10000);
    try std.testing.expect(config.graph_max_queue_size == 50000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 2000);
    try std.testing.expect(config.graph_path_cache_size == 5000);
    try std.testing.expect(config.graph_enable_bidirectional_search == false);
}

test "Config parseBool function" {
    try std.testing.expect(try Config.parseBool("true") == true);
    try std.testing.expect(try Config.parseBool("false") == false);
    
    // Test invalid values
    const result1 = Config.parseBool("maybe");
    try std.testing.expect(result1 == error.InvalidBool);
    
    const result2 = Config.parseBool("");
    try std.testing.expect(result2 == error.InvalidBool);
}

test "Config default graph values" {
    const config = Config{};
    try std.testing.expect(config.graph_max_traversal_depth == 10);
    try std.testing.expect(config.graph_traversal_timeout_ms == 5000);
    try std.testing.expect(config.graph_max_queue_size == 10000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 1000);
    try std.testing.expect(config.graph_path_cache_size == 1000);
    try std.testing.expect(config.graph_enable_bidirectional_search == true);
}

test "Config comprehensive mixed with graph configuration" {
    const config_str = 
        \\# Comprehensive mixed configuration test
        \\# Log settings
        \\log_initial_size = 4MB
        \\log_max_size = 2GB
        \\
        \\# Cache settings  
        \\cache_stats_alpha = 0.25
        \\cache_initial_capacity = 2500
        \\cache_load_factor_threshold = 0.85
        \\
        \\# HTTP API settings
        \\http_port = 3000
        \\http_request_buffer_size = 2048
        \\http_response_buffer_size = 4096
        \\
        \\# Health check settings
        \\health_memory_warning_gb = 0.8
        \\health_memory_critical_gb = 1.6
        \\health_error_rate_warning = 3.0
        \\health_error_rate_critical = 8.0
        \\
        \\# Vector settings
        \\vector_dimensions = 256
        \\vector_similarity_threshold = 0.8
        \\hnsw_max_connections = 24
        \\hnsw_max_connections_layer0 = 48
        \\clustering_max_iterations = 150
        \\
        \\# Graph settings
        \\graph_max_traversal_depth = 12
        \\graph_traversal_timeout_ms = 8000
        \\graph_max_queue_size = 20000
        \\graph_max_neighbors_per_node = 1500
        \\graph_path_cache_size = 2000
        \\graph_enable_bidirectional_search = true
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.25);
    try std.testing.expect(config.cache_initial_capacity == 2500);
    try std.testing.expect(config.cache_load_factor_threshold == 0.85);
    
    // HTTP API settings
    try std.testing.expect(config.http_port == 3000);
    try std.testing.expect(config.http_request_buffer_size == 2048);
    try std.testing.expect(config.http_response_buffer_size == 4096);
    
    // Health check settings
    try std.testing.expect(config.health_memory_warning_gb == 0.8);
    try std.testing.expect(config.health_memory_critical_gb == 1.6);
    try std.testing.expect(config.health_error_rate_warning == 3.0);
    try std.testing.expect(config.health_error_rate_critical == 8.0);
    
    // Vector settings
    try std.testing.expect(config.vector_dimensions == 256);
    try std.testing.expect(config.vector_similarity_threshold == 0.8);
    try std.testing.expect(config.hnsw_max_connections == 24);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 48);
    try std.testing.expect(config.clustering_max_iterations == 150);
    
    // Graph settings
    try std.testing.expect(config.graph_max_traversal_depth == 12);
    try std.testing.expect(config.graph_traversal_timeout_ms == 8000);
    try std.testing.expect(config.graph_max_queue_size == 20000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 1500);
    try std.testing.expect(config.graph_path_cache_size == 2000);
    try std.testing.expect(config.graph_enable_bidirectional_search == true);
}

test "Config monitoring configuration" {
    const config_str = 
        \\# Monitoring configuration test
        \\metrics_collection_interval_ms = 2000
        \\metrics_rate_tracker_window_size = 120
        \\metrics_histogram_enable = false
        \\metrics_export_prometheus = true
        \\metrics_export_json = false
        \\health_check_interval_ms = 10000
        \\health_check_timeout_ms = 2000
        \\memory_stats_enable = true
        \\error_tracking_enable = false
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.metrics_collection_interval_ms == 2000);
    try std.testing.expect(config.metrics_rate_tracker_window_size == 120);
    try std.testing.expect(config.metrics_histogram_enable == false);
    try std.testing.expect(config.metrics_export_prometheus == true);
    try std.testing.expect(config.metrics_export_json == false);
    try std.testing.expect(config.health_check_interval_ms == 10000);
    try std.testing.expect(config.health_check_timeout_ms == 2000);
    try std.testing.expect(config.memory_stats_enable == true);
    try std.testing.expect(config.error_tracking_enable == false);
}

test "Config monitoring default values" {
    const config = Config{};
    try std.testing.expect(config.metrics_collection_interval_ms == 1000);
    try std.testing.expect(config.metrics_rate_tracker_window_size == 60);
    try std.testing.expect(config.metrics_histogram_enable == true);
    try std.testing.expect(config.metrics_export_prometheus == true);
    try std.testing.expect(config.metrics_export_json == true);
    try std.testing.expect(config.health_check_interval_ms == 5000);
    try std.testing.expect(config.health_check_timeout_ms == 1000);
    try std.testing.expect(config.memory_stats_enable == true);
    try std.testing.expect(config.error_tracking_enable == true);
}

test "Config comprehensive mixed with monitoring configuration" {
    const config_str = 
        \\# Comprehensive configuration test with monitoring
        \\# Log settings
        \\log_initial_size = 4MB
        \\log_max_size = 2GB
        \\
        \\# Cache settings  
        \\cache_stats_alpha = 0.25
        \\cache_initial_capacity = 2500
        \\cache_load_factor_threshold = 0.85
        \\
        \\# HTTP API settings
        \\http_port = 3000
        \\http_request_buffer_size = 2048
        \\http_response_buffer_size = 4096
        \\
        \\# Health check settings
        \\health_memory_warning_gb = 0.8
        \\health_memory_critical_gb = 1.6
        \\health_error_rate_warning = 3.0
        \\health_error_rate_critical = 8.0
        \\
        \\# Vector settings
        \\vector_dimensions = 256
        \\vector_similarity_threshold = 0.8
        \\hnsw_max_connections = 24
        \\hnsw_max_connections_layer0 = 48
        \\clustering_max_iterations = 150
        \\
        \\# Graph settings
        \\graph_max_traversal_depth = 12
        \\graph_traversal_timeout_ms = 8000
        \\graph_max_queue_size = 20000
        \\graph_max_neighbors_per_node = 1500
        \\graph_path_cache_size = 2000
        \\graph_enable_bidirectional_search = true
        \\
        \\# Monitoring settings
        \\metrics_collection_interval_ms = 1500
        \\metrics_rate_tracker_window_size = 90
        \\metrics_histogram_enable = true
        \\metrics_export_prometheus = false
        \\metrics_export_json = true
        \\health_check_interval_ms = 3000
        \\health_check_timeout_ms = 500
        \\memory_stats_enable = false
        \\error_tracking_enable = true
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.25);
    try std.testing.expect(config.cache_initial_capacity == 2500);
    try std.testing.expect(config.cache_load_factor_threshold == 0.85);
    
    // HTTP API settings
    try std.testing.expect(config.http_port == 3000);
    try std.testing.expect(config.http_request_buffer_size == 2048);
    try std.testing.expect(config.http_response_buffer_size == 4096);
    
    // Health check settings
    try std.testing.expect(config.health_memory_warning_gb == 0.8);
    try std.testing.expect(config.health_memory_critical_gb == 1.6);
    try std.testing.expect(config.health_error_rate_warning == 3.0);
    try std.testing.expect(config.health_error_rate_critical == 8.0);
    
    // Vector settings
    try std.testing.expect(config.vector_dimensions == 256);
    try std.testing.expect(config.vector_similarity_threshold == 0.8);
    try std.testing.expect(config.hnsw_max_connections == 24);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 48);
    try std.testing.expect(config.clustering_max_iterations == 150);
    
    // Graph settings
    try std.testing.expect(config.graph_max_traversal_depth == 12);
    try std.testing.expect(config.graph_traversal_timeout_ms == 8000);
    try std.testing.expect(config.graph_max_queue_size == 20000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 1500);
    try std.testing.expect(config.graph_path_cache_size == 2000);
    try std.testing.expect(config.graph_enable_bidirectional_search == true);
    
    // Monitoring settings
    try std.testing.expect(config.metrics_collection_interval_ms == 1500);
    try std.testing.expect(config.metrics_rate_tracker_window_size == 90);
    try std.testing.expect(config.metrics_histogram_enable == true);
    try std.testing.expect(config.metrics_export_prometheus == false);
    try std.testing.expect(config.metrics_export_json == true);
    try std.testing.expect(config.health_check_interval_ms == 3000);
    try std.testing.expect(config.health_check_timeout_ms == 500);
    try std.testing.expect(config.memory_stats_enable == false);
    try std.testing.expect(config.error_tracking_enable == true);
}

test "Config persistent index configuration" {
    const config_str = 
        \\# Persistent index configuration test
        \\persistent_index_enable = true
        \\persistent_index_directory = indexes
        \\persistent_index_sync_interval = 300
        \\persistent_index_auto_rebuild = false
        \\persistent_index_memory_alignment = 32768
        \\persistent_index_checksum_validation = false
        \\persistent_index_auto_cleanup = true
        \\persistent_index_max_file_size_mb = 2048
        \\persistent_index_compression_enable = true
        \\persistent_index_sync_on_shutdown = false
    ;
    
    const config = try Config.parseFromString(config_str);
    try std.testing.expect(config.persistent_index_enable == true);
    try std.testing.expect(std.mem.eql(u8, config.persistent_index_directory, "indexes"));
    try std.testing.expect(config.persistent_index_sync_interval == 300);
    try std.testing.expect(config.persistent_index_auto_rebuild == false);
    try std.testing.expect(config.persistent_index_memory_alignment == 32768);
    try std.testing.expect(config.persistent_index_checksum_validation == false);
    try std.testing.expect(config.persistent_index_auto_cleanup == true);
    try std.testing.expect(config.persistent_index_max_file_size_mb == 2048);
    try std.testing.expect(config.persistent_index_compression_enable == true);
    try std.testing.expect(config.persistent_index_sync_on_shutdown == false);
}

test "Config persistent index default values" {
    const config = Config{};
    try std.testing.expect(config.persistent_index_enable == true);
    try std.testing.expect(config.persistent_index_sync_interval == 100);
    try std.testing.expect(config.persistent_index_auto_rebuild == true);
    try std.testing.expect(config.persistent_index_memory_alignment == 16384);
    try std.testing.expect(config.persistent_index_checksum_validation == true);
    try std.testing.expect(config.persistent_index_auto_cleanup == true);
    try std.testing.expect(config.persistent_index_max_file_size_mb == 1024);
    try std.testing.expect(config.persistent_index_compression_enable == true); // Updated: compression now enabled by default
    try std.testing.expect(config.persistent_index_sync_on_shutdown == true);
}

test "Config comprehensive configuration with persistent indexes" {
    const config_str = 
        \\# Comprehensive configuration test with persistent indexes
        \\# Log settings
        \\log_initial_size = 4MB
        \\log_max_size = 2GB
        \\
        \\# Cache settings  
        \\cache_stats_alpha = 0.25
        \\cache_initial_capacity = 2500
        \\cache_load_factor_threshold = 0.85
        \\
        \\# HTTP API settings
        \\http_port = 3000
        \\http_request_buffer_size = 2048
        \\http_response_buffer_size = 4096
        \\
        \\# Health check settings
        \\health_memory_warning_gb = 0.8
        \\health_memory_critical_gb = 1.6
        \\health_error_rate_warning = 3.0
        \\health_error_rate_critical = 8.0
        \\
        \\# Vector settings
        \\vector_dimensions = 256
        \\vector_similarity_threshold = 0.8
        \\hnsw_max_connections = 24
        \\hnsw_max_connections_layer0 = 48
        \\clustering_max_iterations = 150
        \\
        \\# Graph settings
        \\graph_max_traversal_depth = 12
        \\graph_traversal_timeout_ms = 8000
        \\graph_max_queue_size = 20000
        \\graph_max_neighbors_per_node = 1500
        \\graph_path_cache_size = 2000
        \\graph_enable_bidirectional_search = true
        \\
        \\# Monitoring settings
        \\metrics_collection_interval_ms = 1500
        \\metrics_rate_tracker_window_size = 90
        \\metrics_histogram_enable = true
        \\metrics_export_prometheus = false
        \\metrics_export_json = true
        \\health_check_interval_ms = 3000
        \\health_check_timeout_ms = 500
        \\memory_stats_enable = false
        \\error_tracking_enable = true
        \\
        \\# Persistent index settings
        \\persistent_index_enable = true
        \\persistent_index_directory = indexes
        \\persistent_index_sync_interval = 600
        \\persistent_index_auto_rebuild = false
        \\persistent_index_memory_alignment = 65536
        \\persistent_index_checksum_validation = true
        \\persistent_index_auto_cleanup = false
        \\persistent_index_max_file_size_mb = 512
        \\persistent_index_compression_enable = false
        \\persistent_index_sync_on_shutdown = true
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.25);
    try std.testing.expect(config.cache_initial_capacity == 2500);
    try std.testing.expect(config.cache_load_factor_threshold == 0.85);
    
    // HTTP API settings
    try std.testing.expect(config.http_port == 3000);
    try std.testing.expect(config.http_request_buffer_size == 2048);
    try std.testing.expect(config.http_response_buffer_size == 4096);
    
    // Health check settings
    try std.testing.expect(config.health_memory_warning_gb == 0.8);
    try std.testing.expect(config.health_memory_critical_gb == 1.6);
    try std.testing.expect(config.health_error_rate_warning == 3.0);
    try std.testing.expect(config.health_error_rate_critical == 8.0);
    
    // Vector settings
    try std.testing.expect(config.vector_dimensions == 256);
    try std.testing.expect(config.vector_similarity_threshold == 0.8);
    try std.testing.expect(config.hnsw_max_connections == 24);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 48);
    try std.testing.expect(config.clustering_max_iterations == 150);
    
    // Graph settings
    try std.testing.expect(config.graph_max_traversal_depth == 12);
    try std.testing.expect(config.graph_traversal_timeout_ms == 8000);
    try std.testing.expect(config.graph_max_queue_size == 20000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 1500);
    try std.testing.expect(config.graph_path_cache_size == 2000);
    try std.testing.expect(config.graph_enable_bidirectional_search == true);
    
    // Monitoring settings
    try std.testing.expect(config.metrics_collection_interval_ms == 1500);
    try std.testing.expect(config.metrics_rate_tracker_window_size == 90);
    try std.testing.expect(config.metrics_histogram_enable == true);
    try std.testing.expect(config.metrics_export_prometheus == false);
    try std.testing.expect(config.metrics_export_json == true);
    try std.testing.expect(config.health_check_interval_ms == 3000);
    try std.testing.expect(config.health_check_timeout_ms == 500);
    try std.testing.expect(config.memory_stats_enable == false);
    try std.testing.expect(config.error_tracking_enable == true);
    
    // Persistent index settings
    try std.testing.expect(config.persistent_index_enable == true);
    try std.testing.expect(std.mem.eql(u8, config.persistent_index_directory, "indexes"));
    try std.testing.expect(config.persistent_index_sync_interval == 600);
    try std.testing.expect(config.persistent_index_auto_rebuild == false);
    try std.testing.expect(config.persistent_index_memory_alignment == 65536);
    try std.testing.expect(config.persistent_index_checksum_validation == true);
    try std.testing.expect(config.persistent_index_auto_cleanup == false);
    try std.testing.expect(config.persistent_index_max_file_size_mb == 512);
    try std.testing.expect(config.persistent_index_compression_enable == false);
    try std.testing.expect(config.persistent_index_sync_on_shutdown == true);
}

test "Config comprehensive mixed with persistent index configuration" {
    const config_str = 
        \\# Comprehensive mixed configuration test with persistent index
        \\# Log settings
        \\log_initial_size = 4MB
        \\log_max_size = 2GB
        \\
        \\# Cache settings  
        \\cache_stats_alpha = 0.25
        \\cache_initial_capacity = 2500
        \\cache_load_factor_threshold = 0.85
        \\
        \\# HTTP API settings
        \\http_port = 3000
        \\http_request_buffer_size = 2048
        \\http_response_buffer_size = 4096
        \\
        \\# Health check settings
        \\health_memory_warning_gb = 0.8
        \\health_memory_critical_gb = 1.6
        \\health_error_rate_warning = 3.0
        \\health_error_rate_critical = 8.0
        \\
        \\# Vector settings
        \\vector_dimensions = 256
        \\vector_similarity_threshold = 0.8
        \\hnsw_max_connections = 24
        \\hnsw_max_connections_layer0 = 48
        \\clustering_max_iterations = 150
        \\
        \\# Graph settings
        \\graph_max_traversal_depth = 12
        \\graph_traversal_timeout_ms = 8000
        \\graph_max_queue_size = 20000
        \\graph_max_neighbors_per_node = 1500
        \\graph_path_cache_size = 2000
        \\graph_enable_bidirectional_search = true
        \\
        \\# Persistent index settings
        \\persistent_index_enable = true
        \\persistent_index_directory = indexes
        \\persistent_index_sync_interval = 600
        \\persistent_index_auto_rebuild = false
        \\persistent_index_memory_alignment = 65536
        \\persistent_index_checksum_validation = true
        \\persistent_index_auto_cleanup = false
        \\persistent_index_max_file_size_mb = 512
        \\persistent_index_compression_enable = false
        \\persistent_index_sync_on_shutdown = true
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Log settings
    try std.testing.expect(config.log_initial_size == 4 * 1024 * 1024);
    try std.testing.expect(config.log_max_size == 2 * 1024 * 1024 * 1024);
    
    // Cache settings
    try std.testing.expect(config.cache_stats_alpha == 0.25);
    try std.testing.expect(config.cache_initial_capacity == 2500);
    try std.testing.expect(config.cache_load_factor_threshold == 0.85);
    
    // HTTP API settings
    try std.testing.expect(config.http_port == 3000);
    try std.testing.expect(config.http_request_buffer_size == 2048);
    try std.testing.expect(config.http_response_buffer_size == 4096);
    
    // Health check settings
    try std.testing.expect(config.health_memory_warning_gb == 0.8);
    try std.testing.expect(config.health_memory_critical_gb == 1.6);
    try std.testing.expect(config.health_error_rate_warning == 3.0);
    try std.testing.expect(config.health_error_rate_critical == 8.0);
    
    // Vector settings
    try std.testing.expect(config.vector_dimensions == 256);
    try std.testing.expect(config.vector_similarity_threshold == 0.8);
    try std.testing.expect(config.hnsw_max_connections == 24);
    try std.testing.expect(config.hnsw_max_connections_layer0 == 48);
    try std.testing.expect(config.clustering_max_iterations == 150);
    
    // Graph settings
    try std.testing.expect(config.graph_max_traversal_depth == 12);
    try std.testing.expect(config.graph_traversal_timeout_ms == 8000);
    try std.testing.expect(config.graph_max_queue_size == 20000);
    try std.testing.expect(config.graph_max_neighbors_per_node == 1500);
    try std.testing.expect(config.graph_path_cache_size == 2000);
    try std.testing.expect(config.graph_enable_bidirectional_search == true);
    
    // Persistent index settings
    try std.testing.expect(config.persistent_index_enable == true);
    try std.testing.expect(std.mem.eql(u8, config.persistent_index_directory, "indexes"));
    try std.testing.expect(config.persistent_index_sync_interval == 600);
    try std.testing.expect(config.persistent_index_auto_rebuild == false);
    try std.testing.expect(config.persistent_index_memory_alignment == 65536);
    try std.testing.expect(config.persistent_index_checksum_validation == true);
    try std.testing.expect(config.persistent_index_auto_cleanup == false);
    try std.testing.expect(config.persistent_index_max_file_size_mb == 512);
    try std.testing.expect(config.persistent_index_compression_enable == false);
    try std.testing.expect(config.persistent_index_sync_on_shutdown == true);
}

test "Config default snapshot and S3 values" {
    const config = Config{};
    
    // Snapshot defaults
    try std.testing.expect(config.snapshot_auto_interval == 0);
    try std.testing.expect(config.snapshot_max_metadata_size_mb == 10);
    try std.testing.expect(config.snapshot_compression_enable == true); // Updated: compression now enabled by default
    try std.testing.expect(config.snapshot_cleanup_keep_count == 10);
    try std.testing.expect(config.snapshot_cleanup_auto_enable == true);
    try std.testing.expect(config.snapshot_binary_format_enable == true);
    try std.testing.expect(config.snapshot_concurrent_writes == false);
    try std.testing.expect(config.snapshot_verify_checksums == true);
    
    // S3 defaults
    try std.testing.expect(config.s3_enable == false);
    try std.testing.expect(std.mem.eql(u8, config.s3_bucket, ""));
    try std.testing.expect(std.mem.eql(u8, config.s3_region, "us-east-1"));
    try std.testing.expect(std.mem.eql(u8, config.s3_prefix, "memora/"));
    try std.testing.expect(config.s3_upload_timeout_ms == 300000);
    try std.testing.expect(config.s3_download_timeout_ms == 180000);
    try std.testing.expect(config.s3_max_retries == 3);
    try std.testing.expect(config.s3_cleanup_auto_enable == true);
    try std.testing.expect(config.s3_verify_uploads == true);
    try std.testing.expect(config.s3_multipart_threshold_mb == 100);
}

test "Config snapshot and S3 configuration parsing" {
    const config_str = 
        \\# Snapshot configuration test
        \\snapshot_auto_interval = 500
        \\snapshot_max_metadata_size_mb = 25
        \\snapshot_compression_enable = true
        \\snapshot_cleanup_keep_count = 5
        \\snapshot_cleanup_auto_enable = false
        \\snapshot_binary_format_enable = false
        \\snapshot_concurrent_writes = true
        \\snapshot_verify_checksums = false
        \\
        \\# S3 configuration test
        \\s3_enable = true
        \\s3_bucket = my-production-bucket
        \\s3_region = eu-west-1
        \\s3_prefix = production/db/
        \\s3_upload_timeout_ms = 600000
        \\s3_download_timeout_ms = 360000
        \\s3_max_retries = 5
        \\s3_cleanup_auto_enable = false
        \\s3_verify_uploads = false
        \\s3_multipart_threshold_mb = 500
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Snapshot settings
    try std.testing.expect(config.snapshot_auto_interval == 500);
    try std.testing.expect(config.snapshot_max_metadata_size_mb == 25);
    try std.testing.expect(config.snapshot_compression_enable == true);
    try std.testing.expect(config.snapshot_cleanup_keep_count == 5);
    try std.testing.expect(config.snapshot_cleanup_auto_enable == false);
    try std.testing.expect(config.snapshot_binary_format_enable == false);
    try std.testing.expect(config.snapshot_concurrent_writes == true);
    try std.testing.expect(config.snapshot_verify_checksums == false);
    
    // S3 settings
    try std.testing.expect(config.s3_enable == true);
    try std.testing.expect(std.mem.eql(u8, config.s3_bucket, "my-production-bucket"));
    try std.testing.expect(std.mem.eql(u8, config.s3_region, "eu-west-1"));
    try std.testing.expect(std.mem.eql(u8, config.s3_prefix, "production/db/"));
    try std.testing.expect(config.s3_upload_timeout_ms == 600000);
    try std.testing.expect(config.s3_download_timeout_ms == 360000);
    try std.testing.expect(config.s3_max_retries == 5);
    try std.testing.expect(config.s3_cleanup_auto_enable == false);
    try std.testing.expect(config.s3_verify_uploads == false);
    try std.testing.expect(config.s3_multipart_threshold_mb == 500);
}

test "Config default Raft consensus and cluster values" {
    const config = Config{};
    
    // Raft consensus defaults
    try std.testing.expect(config.raft_enable == false);
    try std.testing.expect(config.raft_node_id == 1);
    try std.testing.expect(config.raft_port == 8001);
    try std.testing.expect(config.raft_election_timeout_min_ms == 150);
    try std.testing.expect(config.raft_election_timeout_max_ms == 300);
    try std.testing.expect(config.raft_heartbeat_interval_ms == 50);
    try std.testing.expect(config.raft_network_timeout_ms == 30000);
    try std.testing.expect(config.raft_log_replication_batch_size == 100);
    try std.testing.expect(config.raft_snapshot_threshold == 10000);
    try std.testing.expect(config.raft_max_append_entries == 50);
    try std.testing.expect(config.raft_leadership_transfer_timeout_ms == 5000);
    try std.testing.expect(config.raft_pre_vote_enable == true);
    try std.testing.expect(config.raft_checksum_enable == true);
    try std.testing.expect(config.raft_compression_enable == false);
    
    // Cluster defaults
    try std.testing.expect(config.cluster_replication_factor == 3);
    try std.testing.expect(config.cluster_read_quorum == 2);
    try std.testing.expect(config.cluster_write_quorum == 2);
    try std.testing.expect(config.cluster_auto_join == true);
    try std.testing.expect(config.cluster_bootstrap_expect == 3);
    try std.testing.expect(config.cluster_failure_detection_ms == 10000);
    try std.testing.expect(config.cluster_split_brain_protection == true);
}

test "Config Raft consensus and cluster configuration parsing" {
    const config_str = 
        \\# Raft consensus configuration test
        \\raft_enable = true
        \\raft_node_id = 2
        \\raft_port = 8002
        \\raft_election_timeout_min_ms = 200
        \\raft_election_timeout_max_ms = 400
        \\raft_heartbeat_interval_ms = 75
        \\raft_network_timeout_ms = 45000
        \\raft_log_replication_batch_size = 200
        \\raft_snapshot_threshold = 20000
        \\raft_max_append_entries = 100
        \\raft_leadership_transfer_timeout_ms = 8000
        \\raft_pre_vote_enable = false
        \\raft_checksum_enable = false
        \\raft_compression_enable = true
        \\
        \\# Cluster configuration test
        \\cluster_replication_factor = 5
        \\cluster_read_quorum = 3
        \\cluster_write_quorum = 3
        \\cluster_auto_join = false
        \\cluster_bootstrap_expect = 5
        \\cluster_failure_detection_ms = 15000
        \\cluster_split_brain_protection = false
    ;
    
    const config = try Config.parseFromString(config_str);
    
    // Raft consensus settings
    try std.testing.expect(config.raft_enable == true);
    try std.testing.expect(config.raft_node_id == 2);
    try std.testing.expect(config.raft_port == 8002);
    try std.testing.expect(config.raft_election_timeout_min_ms == 200);
    try std.testing.expect(config.raft_election_timeout_max_ms == 400);
    try std.testing.expect(config.raft_heartbeat_interval_ms == 75);
    try std.testing.expect(config.raft_network_timeout_ms == 45000);
    try std.testing.expect(config.raft_log_replication_batch_size == 200);
    try std.testing.expect(config.raft_snapshot_threshold == 20000);
    try std.testing.expect(config.raft_max_append_entries == 100);
    try std.testing.expect(config.raft_leadership_transfer_timeout_ms == 8000);
    try std.testing.expect(config.raft_pre_vote_enable == false);
    try std.testing.expect(config.raft_checksum_enable == false);
    try std.testing.expect(config.raft_compression_enable == true);
    
    // Cluster settings
    try std.testing.expect(config.cluster_replication_factor == 5);
    try std.testing.expect(config.cluster_read_quorum == 3);
    try std.testing.expect(config.cluster_write_quorum == 3);
    try std.testing.expect(config.cluster_auto_join == false);
    try std.testing.expect(config.cluster_bootstrap_expect == 5);
    try std.testing.expect(config.cluster_failure_detection_ms == 15000);
    try std.testing.expect(config.cluster_split_brain_protection == false);
} 