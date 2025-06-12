const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the Memora module
    const memora_module = b.addModule("memora", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "memora",
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

    // Add the Memora module as a dependency for the tests
    unit_tests.root_module.addImport("memora", memora_module);

    // HNSW tests
    const hnsw_tests = b.addTest(.{
        .root_source_file = b.path("test/test_hnsw.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the HNSW tests
    hnsw_tests.root_module.addImport("memora", memora_module);

    // Basic HNSW tests (without memory leaks)
    const hnsw_basic_tests = b.addTest(.{
        .root_source_file = b.path("test/test_hnsw_basic.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the basic HNSW tests
    hnsw_basic_tests.root_module.addImport("memora", memora_module);

    // Query Optimizer tests
    const query_optimizer_tests = b.addTest(.{
        .root_source_file = b.path("test/test_query_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the query optimizer tests
    query_optimizer_tests.root_module.addImport("memora", memora_module);

    // Cache tests
    const cache_tests = b.addTest(.{
        .root_source_file = b.path("test/test_cache.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the cache tests
    cache_tests.root_module.addImport("memora", memora_module);

    // Parallel processing tests
    const parallel_tests = b.addTest(.{
        .root_source_file = b.path("test/test_parallel.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the parallel tests
    parallel_tests.root_module.addImport("memora", memora_module);

    // Persistent index tests
    const persistent_index_tests = b.addTest(.{
        .root_source_file = b.path("test/test_persistent_index.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the persistent index tests
    persistent_index_tests.root_module.addImport("memora", memora_module);

    // Monitoring tests
    const monitoring_tests = b.addTest(.{
        .root_source_file = b.path("test/test_monitoring.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the Memora module as a dependency for the monitoring tests
    monitoring_tests.root_module.addImport("memora", memora_module);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_hnsw_tests = b.addRunArtifact(hnsw_tests);
    const run_hnsw_basic_tests = b.addRunArtifact(hnsw_basic_tests);
    const run_query_optimizer_tests = b.addRunArtifact(query_optimizer_tests);
    const run_cache_tests = b.addRunArtifact(cache_tests);
    const run_parallel_tests = b.addRunArtifact(parallel_tests);
    const run_persistent_index_tests = b.addRunArtifact(persistent_index_tests);
    const run_monitoring_tests = b.addRunArtifact(monitoring_tests);

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
    
    const test_monitoring_step = b.step("test-monitoring", "Run monitoring tests");
    test_monitoring_step.dependOn(&run_monitoring_tests.step);
    
    const test_raft_step = b.step("test-raft", "Run Raft consensus tests");
    const test_raft_exe = b.addTest(.{
        .root_source_file = b.path("test/test_raft.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_raft_exe.root_module.addImport("memora", memora_module);
    const test_raft_run = b.addRunArtifact(test_raft_exe);
    test_raft_step.dependOn(&test_raft_run.step);

    // HTTP API tests
    const test_http_api_step = b.step("test-http-api", "Run HTTP API tests");
    const test_http_api_exe = b.addTest(.{
        .root_source_file = b.path("test/test_http_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_http_api_exe.root_module.addImport("memora", memora_module);
    const test_http_api_run = b.addRunArtifact(test_http_api_exe);
    test_http_api_step.dependOn(&test_http_api_run.step);

    // Fuzzing framework tests
    const test_fuzzing_step = b.step("test-fuzzing", "Run fuzzing framework tests");
    const test_fuzzing_exe = b.addTest(.{
        .root_source_file = b.path("test/test_fuzzing.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_fuzzing_exe.root_module.addImport("memora", memora_module);
    const test_fuzzing_run = b.addRunArtifact(test_fuzzing_exe);
    test_fuzzing_step.dependOn(&test_fuzzing_run.step);

    // Distributed fuzzing tests
    const test_distributed_fuzzing_step = b.step("test-distributed-fuzzing", "Run distributed fuzzing tests");
    const test_distributed_fuzzing_exe = b.addTest(.{
        .root_source_file = b.path("test/test_distributed_fuzzing.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_distributed_fuzzing_exe.root_module.addImport("memora", memora_module);
    const test_distributed_fuzzing_run = b.addRunArtifact(test_distributed_fuzzing_exe);
    test_distributed_fuzzing_step.dependOn(&test_distributed_fuzzing_run.step);

    // MCP server tests
    const test_mcp_step = b.step("test-mcp", "Run MCP server tests");
    const test_mcp_exe = b.addTest(.{
        .root_source_file = b.path("test/test_mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mcp_exe.root_module.addImport("memora", memora_module);
    const test_mcp_run = b.addRunArtifact(test_mcp_exe);
    test_mcp_step.dependOn(&test_mcp_run.step);

    // Data partitioning tests
    const test_partitioning_step = b.step("test-partitioning", "Run data partitioning tests");
    const test_partitioning_exe = b.addTest(.{
        .root_source_file = b.path("test/test_partitioning.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_partitioning_exe.root_module.addImport("memora", memora_module);
    const test_partitioning_run = b.addRunArtifact(test_partitioning_exe);
    test_partitioning_step.dependOn(&test_partitioning_run.step);

    // Exit snapshot test
    const test_exit_snapshot_step = b.step("test-exit-snapshot", "Run exit snapshot test");
    const test_exit_snapshot_exe = b.addExecutable(.{
        .name = "test_exit_snapshot",
        .root_source_file = b.path("test/test_exit_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_exit_snapshot_exe.root_module.addImport("memora", memora_module);
    const test_exit_snapshot_run = b.addRunArtifact(test_exit_snapshot_exe);
    test_exit_snapshot_step.dependOn(&test_exit_snapshot_run.step);

    // Snapshot compression test
    const test_compression_step = b.step("test-compression", "Run snapshot compression test");
    const test_compression_exe = b.addExecutable(.{
        .name = "test_snapshot_compression",
        .root_source_file = b.path("test/test_snapshot_compression.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_compression_exe.root_module.addImport("memora", memora_module);
    const test_compression_run = b.addRunArtifact(test_compression_exe);
    test_compression_step.dependOn(&test_compression_run.step);

    // Fuzzing campaign runner
    const fuzz_runner_step = b.step("fuzz", "Run Memora fuzzing campaigns");
    const fuzz_runner_exe = b.addExecutable(.{
        .name = "fuzz_runner",
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_runner_exe.root_module.addImport("memora", memora_module);
    const fuzz_runner_run = b.addRunArtifact(fuzz_runner_exe);
    if (b.args) |args| {
        fuzz_runner_run.addArgs(args);
    }
    fuzz_runner_step.dependOn(&fuzz_runner_run.step);

    // Quick fuzzing tests (for CI/development)
    const fuzz_quick_step = b.step("fuzz-quick", "Run quick fuzzing tests");
    const fuzz_quick_exe = b.addExecutable(.{
        .name = "fuzz_quick",
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_quick_exe.root_module.addImport("memora", memora_module);
    const fuzz_quick_run = b.addRunArtifact(fuzz_quick_exe);
    fuzz_quick_run.addArgs(&[_][]const u8{ "--iterations", "50", "--timeout", "5", "--save-dir", "quick_fuzz" });
    fuzz_quick_step.dependOn(&fuzz_quick_run.step);

    // Regression fuzzing tests
    const fuzz_regression_step = b.step("fuzz-regression", "Run regression fuzzing tests");
    const fuzz_regression_exe = b.addExecutable(.{
        .name = "fuzz_regression",
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_regression_exe.root_module.addImport("memora", memora_module);
    const fuzz_regression_run = b.addRunArtifact(fuzz_regression_exe);
    fuzz_regression_run.addArgs(&[_][]const u8{ "--mode", "regression", "--save-dir", "regression_results" });
    fuzz_regression_step.dependOn(&fuzz_regression_run.step);

    // Distributed fuzzing campaigns
    const fuzz_distributed_step = b.step("fuzz-distributed", "Run distributed fuzzing campaigns");
    const fuzz_distributed_exe = b.addExecutable(.{
        .name = "fuzz_distributed",
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_distributed_exe.root_module.addImport("memora", memora_module);
    const fuzz_distributed_run = b.addRunArtifact(fuzz_distributed_exe);
    fuzz_distributed_run.addArgs(&[_][]const u8{ "--mode", "distributed", "--timeout", "60" });
    fuzz_distributed_step.dependOn(&fuzz_distributed_run.step);

    // Stress testing campaigns
    const fuzz_stress_step = b.step("fuzz-stress", "Run stress testing campaigns");
    const fuzz_stress_exe = b.addExecutable(.{
        .name = "fuzz_stress",
        .root_source_file = b.path("examples/fuzz_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_stress_exe.root_module.addImport("memora", memora_module);
    const fuzz_stress_run = b.addRunArtifact(fuzz_stress_exe);
    fuzz_stress_run.addArgs(&[_][]const u8{ "--mode", "stress", "--iterations", "500", "--timeout", "60" });
    fuzz_stress_step.dependOn(&fuzz_stress_run.step);

    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_hnsw_basic_tests.step);
    test_all_step.dependOn(&run_query_optimizer_tests.step);
    test_all_step.dependOn(&run_cache_tests.step);
    test_all_step.dependOn(&run_parallel_tests.step);
    test_all_step.dependOn(&run_persistent_index_tests.step);
    test_all_step.dependOn(&run_monitoring_tests.step);
    test_all_step.dependOn(&test_raft_run.step);
    test_all_step.dependOn(&test_http_api_run.step);
    test_all_step.dependOn(&test_fuzzing_run.step);
    test_all_step.dependOn(&test_mcp_run.step);
    test_all_step.dependOn(&test_partitioning_run.step);

    // Comprehensive test suite including fuzzing
    const test_comprehensive_step = b.step("test-comprehensive", "Run all tests including fuzzing");
    test_comprehensive_step.dependOn(test_all_step);
    test_comprehensive_step.dependOn(&test_distributed_fuzzing_run.step);
    test_comprehensive_step.dependOn(&test_exit_snapshot_run.step);
    test_comprehensive_step.dependOn(&test_compression_run.step);
    test_comprehensive_step.dependOn(&fuzz_quick_run.step);

    // Add distributed demo
    const distributed_demo_step = b.step("demo-distributed", "Run distributed Memora demo");
    const distributed_demo_exe = b.addExecutable(.{
        .name = "distributed_demo",
        .root_source_file = b.path("examples/distributed_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    distributed_demo_exe.root_module.addImport("memora", memora_module);
    const distributed_demo_run = b.addRunArtifact(distributed_demo_exe);
    distributed_demo_step.dependOn(&distributed_demo_run.step);

    // Add HTTP server example
    const http_server_step = b.step("http-server", "Run Memora HTTP API server");
    const http_server_exe = b.addExecutable(.{
        .name = "http_server",
        .root_source_file = b.path("examples/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_server_exe.root_module.addImport("memora", memora_module);
    const http_server_run = b.addRunArtifact(http_server_exe);
    if (b.args) |args| {
        http_server_run.addArgs(args);
    }
    http_server_step.dependOn(&http_server_run.step);

    // Add HTTP client demo
    const http_client_demo_step = b.step("http-client-demo", "Show Memora HTTP API usage examples");
    const http_client_demo_exe = b.addExecutable(.{
        .name = "http_client_demo",
        .root_source_file = b.path("examples/http_client_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http_client_demo_run = b.addRunArtifact(http_client_demo_exe);
    http_client_demo_step.dependOn(&http_client_demo_run.step);

    // Add MCP server example
    const mcp_server_step = b.step("mcp-server", "Run Memora MCP Server for LLM integration");
    const mcp_server_exe = b.addExecutable(.{
        .name = "mcp_server",
        .root_source_file = b.path("examples/mcp_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_server_exe.root_module.addImport("memora", memora_module);
    const mcp_server_run = b.addRunArtifact(mcp_server_exe);
    if (b.args) |args| {
        mcp_server_run.addArgs(args);
    }
    mcp_server_step.dependOn(&mcp_server_run.step);

    // Add enhanced memory test example
    const enhanced_memory_step = b.step("test-enhanced-memory", "Test enhanced memory storage with vector embeddings and concept graphs");
    const enhanced_memory_exe = b.addExecutable(.{
        .name = "test_enhanced_memory",
        .root_source_file = b.path("test/test_enhanced_memory.zig"),
        .target = target,
        .optimize = optimize,
    });
    enhanced_memory_exe.root_module.addImport("memora", memora_module);
    const enhanced_memory_run = b.addRunArtifact(enhanced_memory_exe);
    enhanced_memory_step.dependOn(&enhanced_memory_run.step);

    // Add LLM Memory Demo - showcase the new memory data models
    const llm_memory_demo_step = b.step("llm-memory-demo", "Demonstrate LLM memory data models with semantic storage and retrieval");
    const llm_memory_demo_exe = b.addExecutable(.{
        .name = "llm_memory_demo",
        .root_source_file = b.path("examples/llm_memory_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    llm_memory_demo_exe.root_module.addImport("memora", memora_module);
    const llm_memory_demo_run = b.addRunArtifact(llm_memory_demo_exe);
    llm_memory_demo_step.dependOn(&llm_memory_demo_run.step);

    // Add Gossip Protocol Demo - showcase automatic node discovery
    const gossip_demo_step = b.step("gossip-demo", "Demonstrate gossip protocol for automatic node discovery and cluster formation");
    const gossip_demo_exe = b.addExecutable(.{
        .name = "gossip_demo",
        .root_source_file = b.path("examples/gossip_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    gossip_demo_exe.root_module.addImport("memora", memora_module);
    const gossip_demo_run = b.addRunArtifact(gossip_demo_exe);
    gossip_demo_step.dependOn(&gossip_demo_run.step);

    // Test memory loading from snapshots
    const test_memory_loading = b.addExecutable(.{
        .name = "test_memory_loading",
        .root_source_file = b.path("test/test_memory_loading.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_memory_loading.root_module.addImport("memora", memora_module);
    
    const test_memory_loading_cmd = b.addRunArtifact(test_memory_loading);
    const test_memory_loading_step = b.step("test-memory-loading", "Test memory loading from all snapshots");
    test_memory_loading_step.dependOn(&test_memory_loading_cmd.step);

    // Test graph index vs memory manager mismatch
    const test_graph_debug = b.addExecutable(.{
        .name = "test_graph_index_debug",
        .root_source_file = b.path("test/test_graph_index_debug.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_graph_debug.root_module.addImport("memora", memora_module);
    
    const test_graph_debug_cmd = b.addRunArtifact(test_graph_debug);
    const test_graph_debug_step = b.step("test-graph-debug", "Debug graph index vs memory manager mismatch");
    test_graph_debug_step.dependOn(&test_graph_debug_cmd.step);

    // Test exit snapshot functionality

    // Test concept restoration example
    const concept_restoration_test = b.addExecutable(.{
        .name = "concept_restoration_test",
        .root_source_file = b.path("test/test_concept_restoration.zig"),
        .target = target,
        .optimize = optimize,
    });
    concept_restoration_test.root_module.addImport("memora", memora_module);

    const concept_restoration_cmd = b.addRunArtifact(concept_restoration_test);
    const concept_restoration_step = b.step("test-concept-restoration", "Test concept and vector restoration after restart");
    concept_restoration_step.dependOn(&concept_restoration_cmd.step);

    // Test vector embedding fix
    const vector_fix_test = b.addExecutable(.{
        .name = "vector_fix_test",
        .root_source_file = b.path("test/test_vector_embedding_fix.zig"),
        .target = target,
        .optimize = optimize,
    });
    vector_fix_test.root_module.addImport("memora", memora_module);

    const vector_fix_cmd = b.addRunArtifact(vector_fix_test);
    const vector_fix_step = b.step("test-vector-fix", "Test vector embedding fix for MCP server");
    vector_fix_step.dependOn(&vector_fix_cmd.step);
} 