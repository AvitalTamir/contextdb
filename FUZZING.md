# ContextDB Fuzzing Framework 🧪

**TigerBeetle-Inspired Randomized Testing for ContextDB**

## 🚀 Quick Start - Continuous Fuzzing Commands

### **Ready-to-Run Build Targets**

```bash
# Quick development testing (recommended for daily use)
zig build fuzz-quick          # 50 iterations, 5s timeout, ~2min
zig build fuzz-regression     # Test known-good seeds, ~1min

# Comprehensive testing
zig build test-fuzzing        # Framework unit tests, ~30s
zig build fuzz-distributed   # Raft consensus testing, ~5min
zig build fuzz-stress         # Memory/performance testing, ~10min
zig build test-comprehensive # Everything including fuzzing, ~15min
```

### **Custom Continuous Fuzzing Campaigns**

```bash
# Basic continuous testing
zig build fuzz -- --iterations 1000 --mode single-node --timeout 30

# High-intensity stress testing
zig build fuzz -- --mode stress --iterations 2000 --timeout 120

# Distributed Raft consensus testing
zig build fuzz -- --mode distributed --timeout 60

# Regression testing for stability
zig build fuzz -- --mode regression --save-dir regression_results

# Long-running overnight testing
zig build fuzz -- --iterations 50000 --min-entropy 16 --max-entropy 1024 --timeout 60

# Complex operations with large datasets
zig build fuzz -- --min-entropy 1024 --max-entropy 4096 --iterations 500 --timeout 180
```

### **Command Line Options**

```bash
zig build fuzz -- --help
```

| Option | Default | Description |
|--------|---------|-------------|
| `--iterations <n>` | 1000 | Number of test iterations |
| `--min-entropy <n>` | 32 | Minimum entropy bytes (smaller = simpler tests) |
| `--max-entropy <n>` | 512 | Maximum entropy bytes (larger = complex tests) |
| `--timeout <n>` | 30 | Timeout per test in seconds |
| `--mode <mode>` | single-node | `single-node`, `distributed`, `stress`, `regression` |
| `--save-dir <path>` | fuzz_results | Directory for saving failure cases |
| `--save-failures` | true | Save failure cases for analysis |
| `--no-save-failures` | false | Disable failure case saving |

## 🔥 Fuzzing Modes Explained

### **1. Single-Node Mode (`--mode single-node`)**
**Best for:** Daily development, CI/CD pipelines, quick testing

Tests core ContextDB functionality:
- ✅ Node/edge/vector insertions
- ✅ Graph traversal queries  
- ✅ Vector similarity searches
- ✅ Hybrid graph+vector queries
- ✅ Snapshot creation/recovery
- ✅ Memory pressure scenarios

**Example:**
```bash
zig build fuzz -- --mode single-node --iterations 5000 --timeout 15
```

**Sample Output:**
```
🔥 Running Single-Node Fuzzing Campaign
   Iterations: 5000
   Entropy range: 32-512 bytes
   Timeout: 15s per test

Fuzz campaign completed!
  Successes: 4987
  Failures: 13
  Success rate: 99.7%
  Average operations per test: 23
  Average duration per test: 45ms
```

### **2. Distributed Mode (`--mode distributed`)**
**Best for:** Testing Raft consensus, network reliability, distributed scenarios

Tests distributed system behavior:
- ✅ Leader election with failures
- ✅ Network partition tolerance
- ✅ Split-brain protection
- ✅ Log replication consistency
- ✅ Concurrent operation handling

**Example:**
```bash
zig build fuzz -- --mode distributed --timeout 120 --iterations 1000
```

### **3. Stress Mode (`--mode stress`)**
**Best for:** Performance testing, memory pressure, load testing

High-intensity testing with:
- ✅ Large datasets (1000+ vectors)
- ✅ Deep graph traversals (depth > 10)
- ✅ Complex operations (4KB+ entropy)
- ✅ Memory pressure scenarios
- ✅ Extended timeout periods

**Example:**
```bash
zig build fuzz -- --mode stress --iterations 1000 --timeout 300
```

### **4. Regression Mode (`--mode regression`)**
**Best for:** Stability verification, release testing, CI validation

Tests known-good seeds:
- ✅ 8 golden seeds that should always pass
- ✅ Detects regressions in core functionality
- ✅ Quick verification (usually < 1 minute)
- ✅ Automatic failure reporting

**Example:**
```bash
zig build fuzz -- --mode regression --save-dir nightly_regression
```

## 📊 Understanding Fuzzing Output

### **What the Messages Mean**

When you see this output:
```
No persistent indexes found, loading from log...
Saved persistent indexes in 234µs
```

**This is normal!** Each fuzzing iteration creates a fresh ContextDB instance. The persistent index messages are just startup overhead - the fuzzing is actually testing:

✅ **Database Operations**: Insert/query nodes, edges, vectors  
✅ **Graph Traversal**: BFS/DFS with random depths  
✅ **Vector Similarity**: HNSW search with random embeddings  
✅ **Hybrid Queries**: Combined graph+vector operations  
✅ **Snapshot System**: Creation, recovery, S3 sync  
✅ **Memory Management**: Allocation patterns, leak detection  

### **Operation Distribution Analysis**

Look for this in the test output:
```
Operation distribution over 15 operations:
  insert_node: 3 (20.0%)     ← Node insertions
  insert_edge: 2 (13.3%)     ← Edge insertions  
  insert_vector: 4 (26.7%)   ← Vector insertions
  query_related: 2 (13.3%)   ← Graph queries
  query_similar: 3 (20.0%)   ← Vector similarity
  query_hybrid: 1 (6.7%)     ← Hybrid queries
  create_snapshot: 0 (0.0%)  ← Snapshots
```

### **Failure Case Analysis**

When failures occur, detailed information is saved:
```
FAILURE (seed: 4398046511104, length: 256): Insert edge error
```

Check the `fuzz_results/` directory for detailed failure reports:
```bash
ls fuzz_results/
# failure_4398046511104.txt

cat fuzz_results/failure_4398046511104.txt
# Seed: 4398046511104
# Length: 256
# PRNG Seed: 67890
# Operations completed: 15
# Entropy consumed: 203
# Duration (ns): 89234567
# Error: Insert edge error
```

## 🔄 Continuous Integration Setup

### **GitHub Actions Example**

```yaml
name: Fuzzing Tests
on:
  push:
    branches: [ main ]
  schedule:
    - cron: '0 2 * * *'  # Nightly at 2 AM

jobs:
  quick-fuzz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: goto-bus-stop/setup-zig@v2
      
      # Fast tests for every commit
      - name: Quick fuzzing tests
        run: zig build fuzz-quick
        
      - name: Regression tests
        run: zig build fuzz-regression

  comprehensive-fuzz:
    runs-on: ubuntu-latest
    if: github.event_name == 'schedule'  # Only nightly
    steps:
      - uses: actions/checkout@v3
      - uses: goto-bus-stop/setup-zig@v2
      
      # Comprehensive testing overnight
      - name: Stress testing
        run: zig build fuzz -- --mode stress --iterations 2000
        
      - name: Distributed testing  
        run: zig build fuzz -- --mode distributed --iterations 1000
        
      - name: Save failure artifacts
        uses: actions/upload-artifact@v3
        if: failure()
        with:
          name: fuzz-failures
          path: fuzz_results/
```

### **Local Development Workflow**

```bash
# Before committing code
zig build fuzz-quick            # 2 minutes
zig build fuzz-regression       # 1 minute

# Before major releases
zig build test-comprehensive    # 15 minutes

# Overnight continuous testing
nohup zig build fuzz -- --iterations 100000 --timeout 30 > fuzz.log 2>&1 &
```

## 💡 Best Practices for Continuous Fuzzing

### **1. Start Small, Scale Up**

```bash
# Development: Quick feedback
zig build fuzz-quick

# Testing: Medium coverage  
zig build fuzz -- --iterations 5000

# Production: Comprehensive
zig build fuzz -- --iterations 50000 --mode stress
```

### **2. Use Entropy Size Strategically**

| Entropy Range | Use Case | Typical Duration |
|---------------|----------|------------------|
| 16-64 bytes | Quick development testing | 1-5ms per test |
| 64-256 bytes | Standard CI testing | 10-50ms per test |
| 256-1024 bytes | Integration testing | 50-200ms per test |
| 1024+ bytes | Stress/performance testing | 200ms+ per test |

### **3. Monitor Failure Patterns**

```bash
# Analyze failure patterns over time
grep -h "Error:" fuzz_results/failure_*.txt | sort | uniq -c | sort -nr

# Most common failures:
#    15 Insert edge error
#     8 Query timeout error  
#     3 Vector not found error
#     1 Snapshot creation error
```

### **4. Performance Benchmarking**

```bash
# Run performance benchmarks
zig build fuzz -- --save-dir benchmark --iterations 100

# This automatically triggers performance analysis
# when save-dir is "benchmark"
```

## 🛠️ Customization and Advanced Usage

### **Custom Test Campaigns**

Create your own testing scenarios:

```bash
# Memory pressure testing
zig build fuzz -- --min-entropy 2048 --max-entropy 8192 --iterations 100 --timeout 300

# Quick smoke testing
zig build fuzz -- --min-entropy 8 --max-entropy 32 --iterations 10000 --timeout 1

# Network simulation focus
zig build fuzz -- --mode distributed --timeout 180 --save-dir network_fuzz

# Save interesting cases for analysis
zig build fuzz -- --iterations 10000 --save-dir seed_mining
```

### **Reproducing Specific Failures**

```zig
// In your test code, reproduce exact failures:
test "reproduce specific failure" {
    const seed = fuzzing.FuzzSeed.init(256, 4398046511104);
    const result = try framework.runSingleNodeTest(seed);
    // Debug the exact sequence that caused the failure
}
```

---

## Overview

ContextDB includes a comprehensive fuzzing framework inspired by [TigerBeetle's approach to randomized testing](https://tigerbeetle.com/blog/2023-03-28-random-fuzzy-thoughts/). This framework provides:

- **Finite PRNG**: Deterministic, reproducible random testing
- **Structured Data Generation**: Generate complex database operations from entropy
- **Interactive Simulation**: Test distributed Raft consensus with network partitions
- **Predicate-Based Testing**: Define test scenarios using state predicates
- **Automatic Minimization**: Small entropy produces simple test cases

## Key Concepts

### Finite Random Number Generator (FiniteRng)

The core of our fuzzing approach is the `FiniteRng` - a random number generator that consumes a fixed amount of entropy bytes. This provides several key benefits:

```zig
const entropy = [_]u8{0x42, 0x13, 0x37, 0x99};
var frng = FiniteRng.init(&entropy);

const value1 = try frng.randomU32();  // Always the same for this entropy
const value2 = try frng.randomBool(); // Deterministic sequence
```

**Benefits:**
- **Deterministic**: Same entropy always produces the same test
- **Reproducible**: Share a seed to reproduce any test failure
- **Minimizable**: Shorter entropy = simpler test cases
- **Exhaustible**: Tests naturally terminate when entropy is consumed

### Seed-Based Test Generation

Each test is defined by a `FuzzSeed` that combines entropy length with a PRNG seed:

```zig
const seed = FuzzSeed.init(128, 42); // 128 bytes of entropy, seed=42
const entropy = try seed.generateEntropy(allocator);
var frng = FiniteRng.init(entropy);

// Now generate structured test data...
const operation = try generateRandomOperation(&frng, max_id);
```

### Structured Data Generation

Instead of just generating random bytes, we generate structured database operations:

```zig
pub const DatabaseOperation = union(enum) {
    insert_node: types.Node,
    insert_edge: types.Edge,
    insert_vector: types.Vector,
    query_related: struct { node_id: u64, depth: u8 },
    query_similar: struct { vector_id: u64, k: u8 },
    query_hybrid: struct { node_id: u64, depth: u8, k: u8 },
    create_snapshot: void,
};
```

## Framework Architecture

### Core Components

```
fuzzing.zig
├── FiniteRng              # Deterministic random generation
├── FuzzSeed               # Seed management and entropy generation
├── DatabaseOperation      # Structured operation generation  
├── NetworkSimulator       # Distributed system simulation
├── TestPredicate          # State-based test specification
├── FuzzFramework          # Main test execution engine
└── FuzzResult             # Test result tracking
```

### Network Simulation

For distributed testing, we simulate network conditions:

```zig
pub const NetworkSimulator = struct {
    // Simulates packet loss, delays, and partitions
    packet_loss_rate: f32 = 0.05,    // 5% packet loss
    delay_range: {min: u32, max: u32} = {1, 50}, // 1-50 tick delays
    
    pub fn sendMessage(src: u8, dst: u8, msg_type: raft.MessageType, payload: []const u8) !void
    pub fn tick() !?Message  // Deliver messages with simulated delays
    pub fn partitionNode(node_id: u8) void
};
```

### Predicate-Based Testing

Define test scenarios using state predicates:

```zig
const scenario = DistributedScenario.init("leader_election", &[_]TestPredicate{
    TestPredicate.checkLeaderElected(1),
    TestPredicate.checkNodesConverged(42),
}, 1000); // max ticks
```

## Integration with ContextDB

### Test Coverage

The fuzzing framework exercises all major ContextDB components:

| Component | Coverage |
|-----------|----------|
| **Graph Index** | Node/edge insertion, traversal queries, pathfinding |
| **Vector Index** | HNSW insertion, similarity search, clustering |
| **Hybrid Queries** | Combined graph+vector operations |
| **Persistent Storage** | Snapshot creation, crash recovery, S3 sync |
| **Raft Consensus** | Leader election, log replication, partition tolerance |
| **HTTP API** | Request parsing, response generation, error handling |
| **Memory Management** | Allocation patterns, leak detection, pressure testing |

### Performance Benchmarking

Built-in performance measurement:

```bash
zig build fuzz -- --save-dir benchmark
```

**Sample Benchmark Output:**
```
⚡ Running Fuzzing Performance Benchmark
   Measuring fuzzing framework overhead

Benchmarking entropy size: 16 bytes
  100 iterations in 1456ms (avg: 14ms per test)
  Avg operations per test: 4
  Success rate: 96.0%
  Throughput: 275.9 ops/second

Benchmarking entropy size: 512 bytes  
  100 iterations in 8934ms (avg: 89ms per test)
  Avg operations per test: 47
  Success rate: 91.0%
  Throughput: 527.0 ops/second
```

## Best Practices

### 1. Deterministic Testing

Always use deterministic seeds for reproducible tests:

```zig
test "reproducible fuzzing" {
    const seed = FuzzSeed.init(64, 12345);
    
    const result1 = try framework.runSingleNodeTest(seed);
    const result2 = try framework.runSingleNodeTest(seed);
    
    // Results should be identical
    try testing.expect(result1.operations_completed == result2.operations_completed);
}
```

### 2. Failure Case Preservation

Save interesting failure cases for regression testing:

```zig
const config = FuzzConfig{
    .save_cases = true,
    .save_dir = "critical_failures",
};
```

Failure files contain full reproduction information:
```
Seed: 4398046511104
Length: 256
PRNG Seed: 67890
Operations completed: 15
Entropy consumed: 203
Duration (ns): 89234567
Error: Insert edge error
```

### 3. Entropy Management

- **Small entropy** (16-64 bytes): Quick tests, simple operations
- **Medium entropy** (128-512 bytes): Typical workflows
- **Large entropy** (1024+ bytes): Stress testing, complex scenarios

### 4. Timeout Configuration

Set appropriate timeouts based on test complexity:

```zig
const config = FuzzConfig{
    .timeout_ns = 30_000_000_000, // 30 seconds for complex tests
};
```

## Roadmap

### Planned Enhancements

- [ ] **Coverage-Guided Fuzzing**: Integration with AFL-style coverage feedback
- [ ] **Property-Based Assertions**: Automated invariant checking
- [ ] **Parallel Fuzzing**: Multi-threaded test execution
- [ ] **Corpus Management**: Automatic test case corpus curation
- [ ] **Mutation Strategies**: Smart input mutation based on code coverage
- [ ] **Performance Fuzzing**: Automated performance regression detection

### Integration Targets

- [ ] **CI/CD Integration**: GitHub Actions workflows
- [ ] **Benchmark Integration**: Performance tracking over time
- [ ] **Crash Reporting**: Automatic bug report generation
- [ ] **Visualization**: Test coverage and failure pattern visualization

## Contributing

The fuzzing framework follows ContextDB's development principles:

1. **Deterministic**: All tests must be reproducible
2. **TigerBeetle-Inspired**: Follow established patterns from the blog post
3. **Zero External Dependencies**: Pure Zig implementation
4. **Performance-Conscious**: Minimize fuzzing overhead
5. **Comprehensive**: Cover all major system components

### Adding New Fuzzing Scenarios

1. Implement the scenario in `test/test_distributed_fuzzing.zig`
2. Add appropriate entropy patterns and predicates
3. Include performance benchmarks
4. Update documentation with usage examples
5. Add build targets for easy access

---

**Remember**: The goal of fuzzing is not just finding bugs, but building confidence in ContextDB's reliability under unexpected conditions. Every fuzzing run makes the system more robust! 🚀 