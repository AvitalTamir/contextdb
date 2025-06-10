const std = @import("std");
const memora = @import("memora");
const config = memora.config;
const log = memora.log;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Memora Configuration System Demo\n");
    std.debug.print("====================================\n\n");

    // Demo 1: Default configuration
    std.debug.print("1. Default Configuration:\n");
    const default_config = config.Config{};
    std.debug.print("   log_initial_size: {} bytes ({} MB)\n", .{ default_config.log_initial_size, default_config.log_initial_size / (1024 * 1024) });
    std.debug.print("   log_max_size: {} bytes ({} GB)\n\n", .{ default_config.log_max_size, default_config.log_max_size / (1024 * 1024 * 1024) });

    // Demo 2: Custom configuration
    std.debug.print("2. Custom Configuration:\n");
    const custom_config = config.Config{
        .log_initial_size = 512 * 1024, // 512KB
        .log_max_size = 128 * 1024 * 1024, // 128MB
    };
    std.debug.print("   log_initial_size: {} bytes ({} KB)\n", .{ custom_config.log_initial_size, custom_config.log_initial_size / 1024 });
    std.debug.print("   log_max_size: {} bytes ({} MB)\n\n", .{ custom_config.log_max_size, custom_config.log_max_size / (1024 * 1024) });

    // Demo 3: Configuration from string
    std.debug.print("3. Configuration from String:\n");
    const config_str = 
        \\# Demo configuration
        \\log_initial_size = 2MB
        \\log_max_size = 512MB
    ;
    const parsed_config = try config.Config.parseFromString(config_str);
    std.debug.print("   Parsed from string:\n");
    std.debug.print("   log_initial_size: {} bytes ({} MB)\n", .{ parsed_config.log_initial_size, parsed_config.log_initial_size / (1024 * 1024) });
    std.debug.print("   log_max_size: {} bytes ({} MB)\n\n", .{ parsed_config.log_max_size, parsed_config.log_max_size / (1024 * 1024) });

    // Demo 4: AppendLog with different configs
    std.debug.print("4. AppendLog with Different Configurations:\n");
    
    // Create logs with different configs
    const log_path1 = "demo_log1.bin";
    const log_path2 = "demo_log2.bin";
    
    // Clean up any existing files
    std.fs.cwd().deleteFile(log_path1) catch {};
    std.fs.cwd().deleteFile(log_path2) catch {};
    defer std.fs.cwd().deleteFile(log_path1) catch {};
    defer std.fs.cwd().deleteFile(log_path2) catch {};

    // Log with default config
    var log1 = try log.AppendLog.init(allocator, log_path1, default_config);
    defer log1.deinit();
    std.debug.print("   Log1 (default): initial_size={} KB, max_size={} GB\n", .{
        log1.current_size / 1024,
        log1.max_size / (1024 * 1024 * 1024)
    });

    // Log with custom config
    var log2 = try log.AppendLog.init(allocator, log_path2, custom_config);
    defer log2.deinit();
    std.debug.print("   Log2 (custom): initial_size={} KB, max_size={} MB\n\n", .{
        log2.current_size / 1024,
        log2.max_size / (1024 * 1024)
    });

    // Demo 5: Configuration file operations
    std.debug.print("5. Configuration File Operations:\n");
    
    const demo_config_path = "demo_config.conf";
    defer std.fs.cwd().deleteFile(demo_config_path) catch {};
    
    // Create a config file
    try custom_config.toFile(demo_config_path);
    std.debug.print("   Created config file: {s}\n", .{demo_config_path});
    
    // Load from file
    const loaded_config = try config.Config.fromFile(allocator, demo_config_path);
    std.debug.print("   Loaded from file:\n");
    std.debug.print("   log_initial_size: {} KB\n", .{loaded_config.log_initial_size / 1024});
    std.debug.print("   log_max_size: {} MB\n\n", .{loaded_config.log_max_size / (1024 * 1024)});

    std.debug.print("Configuration system demo completed successfully!\n");
} 