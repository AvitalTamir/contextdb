# Memora Configuration Guide

This guide covers all configuration options available in Memora. The configuration system uses a simple `key=value` format and supports unit suffixes, comments, and environment-specific setups.

## 📋 Table of Contents

- [Getting Started](#getting-started)
- [Configuration Format](#configuration-format)
- [Core Database Settings](#core-database-settings)
- [Caching System](#caching-system)
- [HTTP API Configuration](#http-api-configuration)
- [Vector Search & HNSW](#vector-search--hnsw)
- [Graph Traversal](#graph-traversal)
- [Monitoring & Metrics](#monitoring--metrics)
- [Persistent Indexes](#persistent-indexes)
- [Compression System](#compression-system)
- [Snapshot System](#snapshot-system)
- [S3 Cloud Integration](#s3-cloud-integration)
- [Raft Consensus](#raft-consensus)
- [Distributed Clustering](#distributed-clustering)
- [Environment-Specific Configurations](#environment-specific-configurations)
- [Performance Tuning Guide](#performance-tuning-guide)

## Getting Started

### Quick Setup

```bash
# Copy the example configuration
cp memora.conf.example memora.conf

# Edit for your needs
nano memora.conf

# Start Memora
zig build run
```

### Configuration File Location

Memora looks for configuration files in this order:
1. `./memora.conf` (current directory)
2. `./memora.conf.example` (fallback to example)
3. Built-in defaults

## Configuration Format

### Basic Syntax

```ini
# Comments start with #
# Key-value pairs separated by =
key_name = value

# Whitespace is ignored
  spaced_key   =   spaced_value   

# Unit suffixes supported for sizes
log_max_size = 1GB
cache_initial_capacity = 1000
```

### Supported Units

| Unit | Multiplier | Example |
|------|------------|---------|
| `KB` or `kb` | 1,024 bytes | `log_initial_size = 512KB` |
| `MB` or `mb` | 1,024² bytes | `log_max_size = 100MB` |
| `GB` or `gb` | 1,024³ bytes | `log_max_size = 2GB` |

### Data Types

- **Integers**: `1000`, `65535`
- **Floats**: `0.75`, `1.5`
- **Booleans**: `true`, `false`
- **Strings**: `my-bucket-name`, `127.0.0.1`

## Core Database Settings

Controls fundamental database behavior and storage.

### Log Configuration

The append-only log is the foundation of Memora's durability guarantees.

```ini
# Initial size of the append-only log file
log_initial_size = 1MB

# Maximum size the log file can grow to before rotation
log_max_size = 1GB
```

**Tuning Guidelines:**
- **Development**: `log_initial_size = 1MB`, `log_max_size = 100MB`
- **Production**: `log_initial_size = 10MB`, `log_max_size = 10GB`
- **High-throughput**: `log_initial_size = 100MB`, `log_max_size = 100GB`

## Caching System

Memora includes a sophisticated multi-level caching system with LRU and LFU eviction policies.

### Cache Settings

```ini
# Exponential moving average smoothing factor for access time statistics
cache_stats_alpha = 0.1

# Initial capacity for cache hash tables
cache_initial_capacity = 1000

# Load factor threshold for cache resizing (0.0 to 1.0)
cache_load_factor_threshold = 0.75
```

**Configuration Examples:**

**Memory-Constrained Environment:**
```ini
cache_stats_alpha = 0.05
cache_initial_capacity = 500
cache_load_factor_threshold = 0.9
```

**High-Performance Setup:**
```ini
cache_stats_alpha = 0.2
cache_initial_capacity = 10000
cache_load_factor_threshold = 0.6
```

## HTTP API Configuration

Settings for the REST API server that provides language-agnostic access to Memora.

### Server Settings

```ini
# Port for the HTTP API server
http_port = 8080

# Buffer size for HTTP requests (in bytes)
http_request_buffer_size = 4096

# Buffer size for HTTP responses (in bytes)
http_response_buffer_size = 8192
```

### Health Check Thresholds

```ini
# Memory usage warning threshold (in GB)
health_memory_warning_gb = 1.0

# Memory usage critical threshold (in GB)
health_memory_critical_gb = 2.0

# Error rate warning threshold (percentage)
health_error_rate_warning = 1.0

# Error rate critical threshold (percentage)
health_error_rate_critical = 5.0
```

**Environment Examples:**

**Development Server:**
```ini
http_port = 8080
http_request_buffer_size = 2048
http_response_buffer_size = 4096
health_memory_warning_gb = 0.5
health_memory_critical_gb = 1.0
```

**Production API Server:**
```ini
http_port = 80
http_request_buffer_size = 8192
http_response_buffer_size = 16384
health_memory_warning_gb = 4.0
health_memory_critical_gb = 8.0
```

## Vector Search & HNSW

Configuration for the Hierarchical Navigable Small World (HNSW) vector similarity search system.

### Vector Configuration

```ini
# Dimensionality of vectors (must match your data)
vector_dimensions = 128

# Default similarity threshold for threshold queries (0.0 to 1.0)
vector_similarity_threshold = 0.5
```

### HNSW Algorithm Parameters

```ini
# Maximum connections per node in higher layers
hnsw_max_connections = 16

# Maximum connections per node in layer 0 (base layer)
hnsw_max_connections_layer0 = 32

# Size of dynamic candidate list during construction
hnsw_ef_construction = 200

# Level generation factor (1/ln(2) for exponential decay)
hnsw_ml_factor = 0.693147

# Random seed for deterministic HNSW behavior
hnsw_random_seed = 42

# Maximum number of layers in HNSW index
hnsw_max_layers = 16
```

### Vector Clustering

```ini
# Maximum iterations for k-means clustering
clustering_max_iterations = 100
```

**Performance Tuning:**

**High Accuracy Setup:**
```ini
vector_dimensions = 512
hnsw_max_connections = 32
hnsw_max_connections_layer0 = 64
hnsw_ef_construction = 400
vector_similarity_threshold = 0.8
```

**High Speed Setup:**
```ini
vector_dimensions = 128
hnsw_max_connections = 8
hnsw_max_connections_layer0 = 16
hnsw_ef_construction = 100
vector_similarity_threshold = 0.6
```

## Graph Traversal

Configuration for graph traversal algorithms including BFS, DFS, and shortest path finding.

### Traversal Limits

```ini
# Maximum depth for graph traversal queries (0-255)
graph_max_traversal_depth = 10

# Timeout for graph traversal operations (in milliseconds)
graph_traversal_timeout_ms = 5000

# Maximum queue size for BFS/DFS traversal (prevents memory exhaustion)
graph_max_queue_size = 10000

# Maximum neighbors to process per node (prevents combinatorial explosion)
graph_max_neighbors_per_node = 1000
```

### Graph Optimization

```ini
# Cache size for shortest path queries
graph_path_cache_size = 1000

# Use bidirectional search for shortest paths (true/false)
graph_enable_bidirectional_search = true
```

**Use Case Examples:**

**Social Network Analysis:**
```ini
graph_max_traversal_depth = 6  # Six degrees of separation
graph_max_neighbors_per_node = 5000  # Popular users
graph_path_cache_size = 10000
graph_enable_bidirectional_search = true
```

**Knowledge Graph:**
```ini
graph_max_traversal_depth = 15  # Deep concept relationships
graph_max_neighbors_per_node = 100  # Controlled connections
graph_path_cache_size = 5000
graph_enable_bidirectional_search = true
```

## Monitoring & Metrics

Comprehensive monitoring system with Prometheus compatibility and health checks.

### Metrics Collection

```ini
# How often to collect system metrics (in milliseconds)
metrics_collection_interval_ms = 1000

# Window size for rate calculations (number of samples)
metrics_rate_tracker_window_size = 60

# Enable latency histogram collection (true/false)
metrics_histogram_enable = true

# Enable Prometheus metrics export (true/false)
metrics_export_prometheus = true

# Enable JSON metrics export (true/false)
metrics_export_json = true
```

### Health Checks

```ini
# Health check execution interval (in milliseconds)
health_check_interval_ms = 5000

# Individual health check timeout (in milliseconds)
health_check_timeout_ms = 1000

# Enable memory usage tracking (true/false)
memory_stats_enable = true

# Enable error rate tracking (true/false)
error_tracking_enable = true
```

**Monitoring Scenarios:**

**Development Monitoring:**
```ini
metrics_collection_interval_ms = 5000
metrics_histogram_enable = false
metrics_export_prometheus = false
metrics_export_json = true
health_check_interval_ms = 10000
```

**Production Monitoring:**
```ini
metrics_collection_interval_ms = 1000
metrics_histogram_enable = true
metrics_export_prometheus = true
metrics_export_json = true
health_check_interval_ms = 3000
health_check_timeout_ms = 500
```

## Persistent Indexes

Memory-mapped indexes provide instant startup and crash-safe persistence.

### Index Management

```ini
# Enable persistent memory-mapped indexes for instant startup (true/false)
persistent_index_enable = true

# Sync indexes to disk every N operations (0 = manual sync only)
persistent_index_sync_interval = 100

# Automatically rebuild corrupted indexes from log (true/false)
persistent_index_auto_rebuild = true

# Memory alignment for mmap operations (bytes, should be power of 2)
persistent_index_memory_alignment = 16384
```

### Data Integrity

```ini
# Enable CRC32 checksum validation for data integrity (true/false)
persistent_index_checksum_validation = true

# Automatically cleanup old index files (true/false)
persistent_index_auto_cleanup = true

# Maximum size per index file in MB (helps with memory usage)
persistent_index_max_file_size_mb = 1024

# Force sync indexes on database shutdown (true/false)
persistent_index_sync_on_shutdown = true
```

### Future Features

```ini
# Enable index compression - now available! (true/false)
persistent_index_compression_enable = true
```

**Performance Configurations:**

**High-Performance Setup:**
```ini
persistent_index_enable = true
persistent_index_sync_interval = 50
persistent_index_memory_alignment = 65536
persistent_index_max_file_size_mb = 2048
persistent_index_checksum_validation = true
```

**Memory-Constrained Setup:**
```ini
persistent_index_enable = true
persistent_index_sync_interval = 500
persistent_index_memory_alignment = 8192
persistent_index_max_file_size_mb = 256
persistent_index_checksum_validation = false
```

## Compression System

Memora includes a sophisticated high-performance compression system optimized for vector data, persistent indexes, and snapshot storage. The compression engine provides significant space savings with minimal performance impact.

### Vector Compression Settings

```ini
# Vector quantization scale factor for 8-bit compression (1.0-255.0)
compression_vector_quantization_scale = 255.0

# Vector quantization offset value for data normalization
compression_vector_quantization_offset = 0.0

# Enable delta encoding for vector IDs (true/false)
compression_enable_delta_encoding = true
```

### Binary Data Compression Settings

```ini
# Minimum run length for RLE (Run-Length Encoding) compression (1-255)
compression_rle_min_run_length = 3

# Enable CRC32 checksums for compressed data integrity (true/false)
compression_enable_checksums = true

# Compression level for general data (1=fast, 9=best compression)
compression_level = 1
```

### Compression Thresholds

```ini
# Minimum data size to trigger compression (bytes)
compression_min_size_threshold = 1024

# Minimum compression ratio required to use compression (1.0+)
compression_min_ratio_threshold = 1.2

# Enable parallel compression processing (future feature, true/false)
compression_parallel_enable = false
```

**Performance Impact:**
- **Vector Compression**: 4-8x size reduction with quantization + delta encoding
- **Binary Compression**: 2-4x size reduction with RLE for sorted data
- **Compression Speed**: ~500MB/s for vectors, ~1GB/s for binary data
- **Decompression Speed**: ~800MB/s for vectors, ~1.5GB/s for binary data

**Configuration Examples:**

**High Compression (Storage Optimized):**
```ini
compression_vector_quantization_scale = 255.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 2
compression_enable_checksums = true
compression_level = 6
compression_min_size_threshold = 512
compression_min_ratio_threshold = 1.2
```

**Fast Compression (Performance Optimized):**
```ini
compression_vector_quantization_scale = 127.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 4
compression_enable_checksums = false
compression_level = 1
compression_min_size_threshold = 2048
compression_min_ratio_threshold = 1.5
```

**No Compression (Maximum Speed):**
```ini
compression_vector_quantization_scale = 1.0
compression_enable_delta_encoding = false
compression_rle_min_run_length = 255
compression_enable_checksums = false
compression_level = 1
compression_min_size_threshold = 1000000
compression_min_ratio_threshold = 10.0
```

## Snapshot System

Iceberg-style immutable snapshots for point-in-time recovery and S3 integration.

### Snapshot Automation

```ini
# Create snapshot every N operations (0 = disabled)
snapshot_auto_interval = 0

# Maximum size for snapshot metadata files in MB
snapshot_max_metadata_size_mb = 10

# Keep this many snapshots during cleanup
snapshot_cleanup_keep_count = 10

# Automatically cleanup old snapshots (true/false)
snapshot_cleanup_auto_enable = true
```

### Snapshot Format

```ini
# Use binary format for vector data vs JSON (true/false)
snapshot_binary_format_enable = true

# Verify data integrity during snapshot load (true/false)
snapshot_verify_checksums = true
```

### Future Features

```ini
# Enable snapshot compression - now available! (true/false)
snapshot_compression_enable = true

# Enable concurrent snapshot writes - future feature (true/false)
snapshot_concurrent_writes = false
```

**Backup Strategies:**

**Frequent Backups:**
```ini
snapshot_auto_interval = 1000  # Every 1000 operations
snapshot_cleanup_keep_count = 50
snapshot_cleanup_auto_enable = true
snapshot_binary_format_enable = true
```

**Long-Term Archival:**
```ini
snapshot_auto_interval = 10000  # Every 10000 operations
snapshot_cleanup_keep_count = 100
snapshot_cleanup_auto_enable = false  # Manual cleanup
snapshot_verify_checksums = true
```

## S3 Cloud Integration

Cloud-native persistence and backup to Amazon S3 or S3-compatible storage.

### S3 Configuration

```ini
# Enable S3 integration for cloud backup (true/false)
s3_enable = false

# S3 bucket name for storing snapshots
s3_bucket = ""

# AWS region for S3 operations
s3_region = us-east-1

# S3 prefix for all Memora files
s3_prefix = memora/
```

### S3 Performance

```ini
# Upload timeout in milliseconds (5 minutes default)
s3_upload_timeout_ms = 300000

# Download timeout in milliseconds (3 minutes default)
s3_download_timeout_ms = 180000

# Maximum retry attempts for S3 operations
s3_max_retries = 3

# Use multipart upload for files larger than this (MB)
s3_multipart_threshold_mb = 100
```

### S3 Data Management

```ini
# Automatically cleanup old S3 snapshots (true/false)
s3_cleanup_auto_enable = true

# Verify S3 uploads by downloading and comparing checksums (true/false)
s3_verify_uploads = true
```

**Cloud Deployment Examples:**

**Production S3 Setup:**
```ini
s3_enable = true
s3_bucket = my-production-memora
s3_region = us-west-2
s3_prefix = production/
s3_upload_timeout_ms = 600000
s3_verify_uploads = true
s3_cleanup_auto_enable = true
```

**Development S3 Setup:**
```ini
s3_enable = true
s3_bucket = my-dev-memora
s3_region = us-east-1
s3_prefix = development/
s3_upload_timeout_ms = 180000
s3_verify_uploads = false
s3_cleanup_auto_enable = false
```

## Raft Consensus

Distributed consensus configuration for multi-node clusters with high availability.

### Basic Raft Settings

```ini
# Enable Raft consensus for distributed operation (true/false)
raft_enable = false

# Current node ID in the cluster (must be unique)
raft_node_id = 1

# Port for Raft consensus communication
raft_port = 8001
```

### Timing Configuration

```ini
# Minimum election timeout (milliseconds) - prevents split elections
raft_election_timeout_min_ms = 150

# Maximum election timeout (milliseconds) - randomized to prevent ties
raft_election_timeout_max_ms = 300

# Heartbeat interval for leader (milliseconds) - keep followers informed
raft_heartbeat_interval_ms = 50

# Network operation timeout (milliseconds) - TCP connection timeouts
raft_network_timeout_ms = 30000
```

### Performance Settings

```ini
# Batch size for log replication (entries per RPC)
raft_log_replication_batch_size = 100

# Create snapshot after N log entries (for log compaction)
raft_snapshot_threshold = 10000

# Maximum entries per AppendEntries RPC (prevents large messages)
raft_max_append_entries = 50

# Leadership transfer timeout (milliseconds)
raft_leadership_transfer_timeout_ms = 5000
```

### Reliability Features

```ini
# Enable pre-vote extension to prevent disruptions (true/false)
raft_pre_vote_enable = true

# Enable CRC32 checksums for network messages (true/false)
raft_checksum_enable = true

# Enable compression for large messages - future feature (true/false)
raft_compression_enable = false
```

**Cluster Timing Examples:**

**Low-Latency Network:**
```ini
raft_election_timeout_min_ms = 100
raft_election_timeout_max_ms = 200
raft_heartbeat_interval_ms = 25
raft_network_timeout_ms = 15000
```

**High-Latency Network:**
```ini
raft_election_timeout_min_ms = 300
raft_election_timeout_max_ms = 600
raft_heartbeat_interval_ms = 100
raft_network_timeout_ms = 60000
```

## Distributed Clustering

Cluster management settings for replication, quorum, and failure handling.

### Replication Settings

```ini
# How many copies of data to maintain across the cluster
cluster_replication_factor = 3

# Minimum nodes required for read operations (consistency vs availability)
cluster_read_quorum = 2

# Minimum nodes required for write operations (durability vs availability)
cluster_write_quorum = 2
```

### Cluster Lifecycle

```ini
# Automatically join cluster on startup (true/false)
cluster_auto_join = true

# Expected cluster size for bootstrapping (prevents premature startup)
cluster_bootstrap_expect = 3

# Time to detect node failures (milliseconds)
cluster_failure_detection_ms = 10000

# Prevent split-brain scenarios with network partitions (true/false)
cluster_split_brain_protection = true
```

**Cluster Sizing Examples:**

**3-Node Cluster (Standard):**
```ini
cluster_replication_factor = 3
cluster_read_quorum = 2
cluster_write_quorum = 2
cluster_bootstrap_expect = 3
```

**5-Node Cluster (High Availability):**
```ini
cluster_replication_factor = 5
cluster_read_quorum = 3
cluster_write_quorum = 3
cluster_bootstrap_expect = 5
```

**7-Node Cluster (Maximum Fault Tolerance):**
```ini
cluster_replication_factor = 7
cluster_read_quorum = 4
cluster_write_quorum = 4
cluster_bootstrap_expect = 7
```

## Environment-Specific Configurations

### Development Environment

Optimized for fast iteration and debugging:

```ini
# Development Memora Configuration
log_initial_size = 1MB
log_max_size = 100MB

cache_initial_capacity = 500
http_port = 8080
health_memory_warning_gb = 0.5

vector_dimensions = 128
hnsw_ef_construction = 100
graph_max_traversal_depth = 5

metrics_collection_interval_ms = 5000
metrics_histogram_enable = false
persistent_index_sync_interval = 200

# Compression: Balanced for development
compression_vector_quantization_scale = 127.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 3
compression_enable_checksums = true
compression_level = 3
compression_min_ratio_threshold = 1.5
persistent_index_compression_enable = true

snapshot_auto_interval = 0
s3_enable = false
raft_enable = false
```

### Production Environment

Optimized for performance, reliability, and observability:

```ini
# Production Memora Configuration
log_initial_size = 100MB
log_max_size = 10GB

cache_initial_capacity = 10000
cache_load_factor_threshold = 0.6
http_port = 80
health_memory_warning_gb = 4.0
health_memory_critical_gb = 8.0

vector_dimensions = 512
hnsw_max_connections = 32
hnsw_ef_construction = 400
graph_max_traversal_depth = 15
graph_path_cache_size = 10000

metrics_collection_interval_ms = 1000
metrics_histogram_enable = true
metrics_export_prometheus = true
persistent_index_sync_interval = 50
persistent_index_memory_alignment = 65536

# Compression: Production optimized for storage efficiency
compression_vector_quantization_scale = 255.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 2
compression_enable_checksums = true
compression_level = 6
compression_min_ratio_threshold = 1.2
persistent_index_compression_enable = true

snapshot_auto_interval = 5000
snapshot_cleanup_keep_count = 50
snapshot_compression_enable = true
s3_enable = true
s3_bucket = production-memora
s3_region = us-west-2

raft_enable = true
cluster_replication_factor = 3
cluster_read_quorum = 2
cluster_write_quorum = 2
```

### High-Performance Environment

Optimized for maximum throughput and minimal latency:

```ini
# High-Performance Memora Configuration
log_initial_size = 1GB
log_max_size = 100GB

cache_initial_capacity = 50000
cache_load_factor_threshold = 0.5
http_request_buffer_size = 16384
http_response_buffer_size = 32768

vector_dimensions = 256
hnsw_max_connections = 64
hnsw_max_connections_layer0 = 128
hnsw_ef_construction = 800
graph_max_queue_size = 50000
graph_max_neighbors_per_node = 10000

metrics_collection_interval_ms = 500
persistent_index_sync_interval = 25
persistent_index_memory_alignment = 262144
persistent_index_max_file_size_mb = 4096

# Compression: High-performance optimized for speed
compression_vector_quantization_scale = 127.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 4
compression_enable_checksums = false
compression_level = 1
compression_min_ratio_threshold = 2.0
persistent_index_compression_enable = true

snapshot_auto_interval = 10000
snapshot_compression_enable = false
raft_heartbeat_interval_ms = 25
raft_log_replication_batch_size = 200
```

## Performance Tuning Guide

### Memory Optimization

**Reduce Memory Usage:**
```ini
cache_initial_capacity = 500
cache_load_factor_threshold = 0.9
hnsw_max_connections = 8
graph_max_queue_size = 5000
persistent_index_max_file_size_mb = 256
```

**Increase Memory Usage for Performance:**
```ini
cache_initial_capacity = 20000
cache_load_factor_threshold = 0.5
hnsw_max_connections = 64
graph_path_cache_size = 20000
persistent_index_memory_alignment = 262144
```

### Disk I/O Optimization

**Minimize Disk Writes:**
```ini
persistent_index_sync_interval = 1000
snapshot_auto_interval = 0  # Manual snapshots only
log_max_size = 10GB  # Larger log files
```

**Optimize for SSD:**
```ini
persistent_index_sync_interval = 50
persistent_index_memory_alignment = 65536
log_initial_size = 100MB
```

### Network Optimization

**Low-Latency Network:**
```ini
raft_heartbeat_interval_ms = 25
raft_election_timeout_min_ms = 100
raft_network_timeout_ms = 15000
http_request_buffer_size = 16384
```

**High-Latency Network:**
```ini
raft_heartbeat_interval_ms = 100
raft_election_timeout_min_ms = 300
raft_network_timeout_ms = 60000
raft_log_replication_batch_size = 200
```

### Vector Search Optimization

**Accuracy vs Speed Trade-offs:**

**High Accuracy:**
```ini
hnsw_ef_construction = 800
hnsw_max_connections = 32
vector_similarity_threshold = 0.9
```

**High Speed:**
```ini
hnsw_ef_construction = 100
hnsw_max_connections = 8
vector_similarity_threshold = 0.6
```

### Compression Optimization

**Storage Efficiency (Maximum Compression):**
```ini
compression_vector_quantization_scale = 255.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 2
compression_enable_checksums = true
compression_level = 9
compression_min_ratio_threshold = 1.05
persistent_index_compression_enable = true
snapshot_compression_enable = true
```

**Performance Priority (Minimal Compression Overhead):**
```ini
compression_vector_quantization_scale = 127.0
compression_enable_delta_encoding = true
compression_rle_min_run_length = 4
compression_enable_checksums = false
compression_level = 1
compression_min_ratio_threshold = 2.0
persistent_index_compression_enable = true
snapshot_compression_enable = false
```

**No Compression (Maximum Speed):**
```ini
compression_min_size_threshold = 1000000
compression_min_ratio_threshold = 10.0
persistent_index_compression_enable = false
snapshot_compression_enable = false
```

---

## 🔧 Configuration Validation

Memora automatically validates configuration values and provides helpful error messages for invalid settings. Unknown configuration keys are ignored for forward compatibility.

## 📚 Additional Resources

- [README.md](README.md) - Main documentation and getting started guide
- [memora.conf.example](memora.conf.example) - Complete example configuration with comments
- Performance benchmarks and tuning guides (coming soon)
- Deployment guides for cloud platforms (coming soon)

---

**💡 Pro Tip**: Start with the example configuration and gradually adjust settings based on your specific use case and performance requirements. Monitor system metrics to validate configuration changes. 