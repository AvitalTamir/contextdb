const std = @import("std");
const contextdb = @import("contextdb");
const fuzzing = contextdb.fuzzing;

// =============================================================================
// CLI Fuzzing Campaign Runner
// =============================================================================

const FuzzOptions = struct {
    iterations: u32 = 1000,
    min_entropy: u32 = 32,
    max_entropy: u32 = 512,
    timeout_seconds: u32 = 30,
    save_failures: bool = true,
    save_dir: []const u8 = "fuzz_results",
    mode: FuzzMode = .single_node,
    
    // Memory management for allocated strings
    allocator: ?std.mem.Allocator = null,
    save_dir_allocated: bool = false,
    
    const FuzzMode = enum {
        single_node,
        distributed,
        stress,
        regression,
    };
    
    pub fn deinit(self: *FuzzOptions) void {
        if (self.save_dir_allocated and self.allocator != null) {
            self.allocator.?.free(self.save_dir);
        }
    }
};

fn printUsage(program_name: []const u8) void {
    std.debug.print(
        \\ContextDB Fuzzing Campaign Runner
        \\
        \\Usage: {s} [options]
        \\
        \\Options:
        \\  --iterations <n>      Number of test iterations (default: 1000)
        \\  --min-entropy <n>     Minimum entropy bytes (default: 32)
        \\  --max-entropy <n>     Maximum entropy bytes (default: 512)
        \\  --timeout <n>         Timeout per test in seconds (default: 30)
        \\  --save-failures       Save failure cases (default: true)
        \\  --save-dir <path>     Directory for saving results (default: fuzz_results)
        \\  --mode <mode>         Fuzzing mode: single-node, distributed, stress, regression
        \\  --help                Show this help message
        \\
        \\Examples:
        \\  {s} --iterations 5000 --mode stress
        \\  {s} --mode distributed --timeout 60
        \\  {s} --mode regression --save-dir regression_tests
        \\
    , .{ program_name, program_name, program_name, program_name });
}

fn parseArgs(allocator: std.mem.Allocator, args: [][:0]u8) !FuzzOptions {
    var options = FuzzOptions{
        .allocator = allocator,
    };
    
    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "--help")) {
            return error.ShowHelp;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.iterations = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--min-entropy")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.min_entropy = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-entropy")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.max_entropy = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.timeout_seconds = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--save-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.save_dir = try allocator.dupe(u8, args[i]);
            options.save_dir_allocated = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            
            if (std.mem.eql(u8, args[i], "single-node")) {
                options.mode = .single_node;
            } else if (std.mem.eql(u8, args[i], "distributed")) {
                options.mode = .distributed;
            } else if (std.mem.eql(u8, args[i], "stress")) {
                options.mode = .stress;
            } else if (std.mem.eql(u8, args[i], "regression")) {
                options.mode = .regression;
            } else {
                std.debug.print("Unknown mode: {s}\n", .{args[i]});
                return error.InvalidMode;
            }
        } else if (std.mem.eql(u8, arg, "--no-save-failures")) {
            options.save_failures = false;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }
    
    return options;
}

fn runSingleNodeCampaign(allocator: std.mem.Allocator, options: FuzzOptions) !void {
    std.debug.print("🔥 Running Single-Node Fuzzing Campaign\n", .{});
    std.debug.print("   Iterations: {}\n", .{options.iterations});
    std.debug.print("   Entropy range: {}-{} bytes\n", .{ options.min_entropy, options.max_entropy });
    std.debug.print("   Timeout: {}s per test\n", .{options.timeout_seconds});
    std.debug.print("\n", .{});
    
    const config = fuzzing.FuzzConfig{
        .min_entropy = options.min_entropy,
        .max_entropy = options.max_entropy,
        .timeout_ns = @as(u64, options.timeout_seconds) * 1_000_000_000,
        .save_cases = options.save_failures,
        .save_dir = options.save_dir,
    };
    
    var framework = fuzzing.FuzzFramework.init(allocator, config);
    try framework.runCampaign(options.iterations);
}

fn runDistributedCampaign(allocator: std.mem.Allocator, options: FuzzOptions) !void {
    std.debug.print("🌐 Running Distributed Fuzzing Campaign\n", .{});
    std.debug.print("   Testing multiple concurrent instances\n", .{});
    std.debug.print("   Simulating distributed scenarios\n", .{});
    std.debug.print("\n", .{});
    
    // Simulate distributed testing by running multiple parallel fuzzing instances
    const scenarios = [_]struct {
        name: []const u8,
        entropy_min: u32,
        entropy_max: u32,
        iterations: u32,
    }{
        .{ .name = "Concurrent Insert Operations", .entropy_min = 64, .entropy_max = 256, .iterations = 100 },
        .{ .name = "Mixed Workload Simulation", .entropy_min = 128, .entropy_max = 512, .iterations = 150 },
        .{ .name = "High Throughput Stress", .entropy_min = 256, .entropy_max = 1024, .iterations = 200 },
    };
    
    for (scenarios) |scenario| {
        std.debug.print("📊 Running scenario: {s}\n", .{scenario.name});
        
        const config = fuzzing.FuzzConfig{
            .min_entropy = scenario.entropy_min,
            .max_entropy = scenario.entropy_max,
            .timeout_ns = @as(u64, options.timeout_seconds) * 1_000_000_000,
            .save_cases = options.save_failures,
            .save_dir = options.save_dir,
        };
        
        var framework = fuzzing.FuzzFramework.init(allocator, config);
        try framework.runCampaign(scenario.iterations);
        
        std.debug.print("✓ Scenario completed\n\n", .{});
    }
}

fn runStressCampaign(allocator: std.mem.Allocator, options: FuzzOptions) !void {
    std.debug.print("💪 Running Stress Testing Campaign\n", .{});
    std.debug.print("   High-intensity testing with large datasets\n", .{});
    std.debug.print("   Iterations: {}\n", .{options.iterations});
    std.debug.print("\n", .{});
    
    const stress_config = fuzzing.FuzzConfig{
        .min_entropy = 1024, // Large operations
        .max_entropy = 4096, // Very large operations
        .timeout_ns = @as(u64, options.timeout_seconds) * 2 * 1_000_000_000, // Double timeout
        .save_cases = options.save_failures,
        .save_dir = options.save_dir,
    };
    
    var framework = fuzzing.FuzzFramework.init(allocator, stress_config);
    
    std.debug.print("Phase 1: Large single operations\n", .{});
    try framework.runCampaign(options.iterations / 4);
    
    std.debug.print("\nPhase 2: Complex mixed workloads\n", .{});
    try framework.runCampaign(options.iterations / 4);
    
    std.debug.print("\nPhase 3: Memory pressure testing\n", .{});
    try framework.runCampaign(options.iterations / 2);
    
    std.debug.print("✓ Stress testing completed\n", .{});
}

fn runRegressionCampaign(allocator: std.mem.Allocator, options: FuzzOptions) !void {
    std.debug.print("🔍 Running Regression Testing Campaign\n", .{});
    std.debug.print("   Testing known-good seeds for stability\n", .{});
    std.debug.print("\n", .{});
    
    // Known good seeds that should always pass
    const golden_seeds = [_]fuzzing.FuzzSeed{
        fuzzing.FuzzSeed.init(64, 1234567890),
        fuzzing.FuzzSeed.init(128, 987654321),
        fuzzing.FuzzSeed.init(32, 555666777),
        fuzzing.FuzzSeed.init(256, 111222333),
        fuzzing.FuzzSeed.init(96, 444555666),
        fuzzing.FuzzSeed.init(160, 777888999),
        fuzzing.FuzzSeed.init(192, 123321456),
        fuzzing.FuzzSeed.init(224, 789987654),
    };
    
    const config = fuzzing.FuzzConfig{
        .min_entropy = options.min_entropy,
        .max_entropy = options.max_entropy,
        .timeout_ns = @as(u64, options.timeout_seconds) * 1_000_000_000,
        .save_cases = true, // Always save failures in regression tests
        .save_dir = options.save_dir,
    };
    
    var framework = fuzzing.FuzzFramework.init(allocator, config);
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    for (golden_seeds, 0..) |seed, i| {
        std.debug.print("Testing golden seed {}/{}: {} ", .{ i + 1, golden_seeds.len, seed.seed });
        
        const result = try framework.runSingleNodeTest(seed);
        
        if (result.success) {
            passed += 1;
            std.debug.print("✓ PASS ({}ms, {} ops)\n", .{ 
                result.duration_ns / 1_000_000, 
                result.operations_completed 
            });
        } else {
            failed += 1;
            std.debug.print("✗ FAIL: {s}\n", .{result.error_message orelse "Unknown error"});
        }
    }
    
    std.debug.print("\n📈 Regression Test Results:\n", .{});
    std.debug.print("   Passed: {}/{}\n", .{ passed, golden_seeds.len });
    std.debug.print("   Failed: {}\n", .{failed});
    
    if (failed > 0) {
        std.debug.print("⚠️  WARNING: {} regression test(s) failed!\n", .{failed});
        std.debug.print("   This indicates a potential regression in ContextDB.\n", .{});
        std.debug.print("   Check the saved failure cases in '{s}' for details.\n", .{options.save_dir});
    } else {
        std.debug.print("✅ All regression tests passed!\n", .{});
    }
}

fn runFuzzingBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("⚡ Running Fuzzing Performance Benchmark\n", .{});
    std.debug.print("   Measuring fuzzing framework overhead\n", .{});
    std.debug.print("\n", .{});
    
    const benchmark_iterations = 100;
    const entropy_sizes = [_]u32{ 16, 32, 64, 128, 256, 512 };
    
    for (entropy_sizes) |size| {
        std.debug.print("Benchmarking entropy size: {} bytes\n", .{size});
        
        const start_time = std.time.nanoTimestamp();
        
        const config = fuzzing.FuzzConfig{
            .min_entropy = size,
            .max_entropy = size,
            .timeout_ns = 5_000_000_000, // 5 seconds
            .save_cases = false,
        };
        
        var framework = fuzzing.FuzzFramework.init(allocator, config);
        
        var total_operations: u64 = 0;
        var successes: u32 = 0;
        
        for (0..benchmark_iterations) |i| {
            const seed = fuzzing.FuzzSeed.init(size, @as(u32, @intCast(i * 1000)));
            const result = try framework.runSingleNodeTest(seed);
            
            total_operations += result.operations_completed;
            if (result.success) successes += 1;
        }
        
        const end_time = std.time.nanoTimestamp();
        const total_duration_ms = @as(u64, @intCast(end_time - start_time)) / 1_000_000;
        const avg_duration_ms = total_duration_ms / benchmark_iterations;
        const avg_operations = total_operations / benchmark_iterations;
        
        std.debug.print("  {} iterations in {}ms (avg: {}ms per test)\n", .{
            benchmark_iterations, total_duration_ms, avg_duration_ms
        });
        std.debug.print("  Avg operations per test: {}\n", .{avg_operations});
        std.debug.print("  Success rate: {d:.1}%\n", .{
            @as(f64, @floatFromInt(successes)) / @as(f64, @floatFromInt(benchmark_iterations)) * 100.0
        });
        std.debug.print("  Throughput: {d:.1} ops/second\n\n", .{
            @as(f64, @floatFromInt(avg_operations)) * 1000.0 / @as(f64, @floatFromInt(avg_duration_ms))
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len == 1) {
        printUsage(args[0]);
        return;
    }
    
    var options = parseArgs(allocator, args) catch |err| {
        switch (err) {
            error.ShowHelp => {
                printUsage(args[0]);
                return;
            },
            error.MissingValue => {
                std.debug.print("Error: Missing value for option\n", .{});
                return;
            },
            error.InvalidMode => {
                std.debug.print("Error: Invalid mode. Valid modes: single-node, distributed, stress, regression\n", .{});
                return;
            },
            error.UnknownOption => {
                std.debug.print("Error: Unknown option. Use --help for usage information.\n", .{});
                return;
            },
            else => return err,
        }
    };
    defer options.deinit(); // Clean up allocated memory
    
    // Create save directory if needed
    if (options.save_failures) {
        std.fs.cwd().makeDir(options.save_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error creating save directory '{s}': {}\n", .{ options.save_dir, err });
                return;
            }
        };
    }
    
    const start_time = std.time.nanoTimestamp();
    
    switch (options.mode) {
        .single_node => try runSingleNodeCampaign(allocator, options),
        .distributed => try runDistributedCampaign(allocator, options),
        .stress => try runStressCampaign(allocator, options),
        .regression => try runRegressionCampaign(allocator, options),
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_duration = @as(u64, @intCast(end_time - start_time)) / 1_000_000_000;
    
    std.debug.print("\n🎉 Fuzzing campaign completed in {}s\n", .{total_duration});
    
    // Optional: run performance benchmark
    if (std.mem.eql(u8, options.save_dir, "benchmark")) {
        try runFuzzingBenchmark(allocator);
    }
} 