const std = @import("std");

/// Centralized configuration system for ContextDB
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
        
        try writer.print("# ContextDB Configuration\n", .{});
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