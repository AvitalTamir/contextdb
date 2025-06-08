const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the ContextDB module
    const contextdb_module = b.addModule("contextdb", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "contextdb",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Main integration tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("test/test_query.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the tests
    unit_tests.root_module.addImport("contextdb", contextdb_module);

    // HNSW tests
    const hnsw_tests = b.addTest(.{
        .root_source_file = b.path("test/test_hnsw.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the HNSW tests
    hnsw_tests.root_module.addImport("contextdb", contextdb_module);

    // Basic HNSW tests (without memory leaks)
    const hnsw_basic_tests = b.addTest(.{
        .root_source_file = b.path("test/test_hnsw_basic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the basic HNSW tests
    hnsw_basic_tests.root_module.addImport("contextdb", contextdb_module);

    // Query Optimizer tests
    const query_optimizer_tests = b.addTest(.{
        .root_source_file = b.path("test/test_query_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the query optimizer tests
    query_optimizer_tests.root_module.addImport("contextdb", contextdb_module);

    // Cache tests
    const cache_tests = b.addTest(.{
        .root_source_file = b.path("test/test_cache.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the cache tests
    cache_tests.root_module.addImport("contextdb", contextdb_module);

    // Parallel processing tests
    const parallel_tests = b.addTest(.{
        .root_source_file = b.path("test/test_parallel.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the parallel tests
    parallel_tests.root_module.addImport("contextdb", contextdb_module);

    // Persistent index tests
    const persistent_index_tests = b.addTest(.{
        .root_source_file = b.path("test/test_persistent_index.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the ContextDB module as a dependency for the persistent index tests
    persistent_index_tests.root_module.addImport("contextdb", contextdb_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_hnsw_tests = b.addRunArtifact(hnsw_tests);
    const run_hnsw_basic_tests = b.addRunArtifact(hnsw_basic_tests);
    const run_query_optimizer_tests = b.addRunArtifact(query_optimizer_tests);
    const run_cache_tests = b.addRunArtifact(cache_tests);
    const run_parallel_tests = b.addRunArtifact(parallel_tests);
    const run_persistent_index_tests = b.addRunArtifact(persistent_index_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    
    const test_hnsw_step = b.step("test-hnsw", "Run HNSW tests");
    test_hnsw_step.dependOn(&run_hnsw_tests.step);
    
    const test_hnsw_basic_step = b.step("test-hnsw-basic", "Run basic HNSW tests");
    test_hnsw_basic_step.dependOn(&run_hnsw_basic_tests.step);
    
    const test_query_optimizer_step = b.step("test-query-optimizer", "Run query optimizer tests");
    test_query_optimizer_step.dependOn(&run_query_optimizer_tests.step);
    
    const test_cache_step = b.step("test-cache", "Run cache tests");
    test_cache_step.dependOn(&run_cache_tests.step);
    
    const test_parallel_step = b.step("test-parallel", "Run parallel processing tests");
    test_parallel_step.dependOn(&run_parallel_tests.step);
    
    const test_persistent_index_step = b.step("test-persistent-index", "Run persistent index tests");
    test_persistent_index_step.dependOn(&run_persistent_index_tests.step);
    
    const test_raft_step = b.step("test-raft", "Run Raft consensus tests");
    const test_raft_exe = b.addTest(.{
        .root_source_file = b.path("test/test_raft.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_raft_exe.root_module.addImport("contextdb", contextdb_module);
    const test_raft_run = b.addRunArtifact(test_raft_exe);
    test_raft_step.dependOn(&test_raft_run.step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_hnsw_basic_tests.step);
    test_all_step.dependOn(&run_query_optimizer_tests.step);
    test_all_step.dependOn(&run_cache_tests.step);
    test_all_step.dependOn(&run_parallel_tests.step);
    test_all_step.dependOn(&run_persistent_index_tests.step);
    test_all_step.dependOn(&test_raft_run.step);

    // Add distributed demo
    const distributed_demo_step = b.step("demo-distributed", "Run distributed ContextDB demo");
    const distributed_demo_exe = b.addExecutable(.{
        .name = "distributed_demo",
        .root_source_file = b.path("examples/distributed_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    distributed_demo_exe.root_module.addImport("contextdb", contextdb_module);
    const distributed_demo_run = b.addRunArtifact(distributed_demo_exe);
    distributed_demo_step.dependOn(&distributed_demo_run.step);
} 