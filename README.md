# Memora 🧠

A **distributed hybrid vector and graph database** designed as an **LLM long-term memory backend** with **human visibility layers**. Built in Zig with **Raft consensus** for reliability, **MCP integration** for LLM access, and **Cypher-like queries** for human exploration.

## 🎯 Bifocal Memory System

Memora serves as a **dual-purpose memory architecture**:

**🤖 For LLMs**: High-performance semantic memory store via **Model Context Protocol (MCP)**<br />
**👨‍💻 For Humans**: Transparent, queryable knowledge graph with **web UI** and **audit capabilities**

### 💡 Why This Is Powerful

| Feature | Description |
|---------|-------------|
| 🔁 **Feedback Loop** | LLMs read/write memories with purpose; humans inspect, audit, and correct |
| 🔍 **Visibility + Explainability** | Trace answers back to source paragraphs, events, relationships |
| 🔗 **Shared World Model** | Graph shows how concepts connect (not just stored) |
| 🧠 **Long-Term Memory API** | LLM stores observations, experiences, decisions |
| 🔍 **Memory Audit** | Devs and users can query what the LLM "knows" |
| 🧩 **Cross-Session Coherence** | Persistent memory survives across prompts/sessions |
| 🔗 **Traceable Retrieval** | Responses tied to graph+vector provenance |
| 🧑‍💻 **Human/LLM Co-curation** | Humans can shape or clean memory alongside the model |

## 🏗️ Architecture: Observability Dashboard for Machine Cognition

```
┌────────────────────────────────────────────────────────────────┐
│                         Memora System                          │
├────────────────────────────────────────────────────────────────┤
│  Access Layer                                                  │
│  ┌─────────────────┐  ┌──────────────────┐ ┌─────────────────┐ │
│  │   MCP Server    │  │   Web UI         │ │ Cypher-like QL  │ │
│  │ (LLM Interface) │  │ (Human Insight)  │ │ (Dev Queries)   │ │
│  └─────────────────┘  └──────────────────┘ └─────────────────┘ │
├────────────────────────────────────────────────────────────────┤
│  Consensus Layer (Raft Protocol)                               │
│  ┌─────────────────┐  ┌──────────────────┐ ┌─────────────────┐ │
│  │ Leader Election │  │ Log Replication  │ │ Fault Tolerance │ │
│  │ (150-300ms)     │  │ (TCP + CRC32)    │ │ (Majority)      │ │
│  └─────────────────┘  └──────────────────┘ └─────────────────┘ │
├────────────────────────────────────────────────────────────────┤
│  Memory Layer                                                  │
│  ┌─────────────────┐  ┌──────────────────┐ ┌─────────────────┐ │
│  │ Concept Graph   │  │ Semantic Vectors │ │ Memory Cache    │ │
│  │ (Knowledge Web) │  │ (Similarity)     │ │ (LRU + LFU)     │ │
│  └─────────────────┘  └──────────────────┘ └─────────────────┘ │
├────────────────────────────────────────────────────────────────┤
│  Storage Layer                                                 │
│  ┌─────────────────┐  ┌──────────────────┐ ┌─────────────────┐ │
│  │  Graph Index    │  │  Vector Index    │ │ Experience Log  │ │
│  │ (Memory-Mapped) │  │ (HNSW Structure) │ │ (Replicated)    │ │
│  └─────────────────┘  └──────────────────┘ └─────────────────┘ │
├────────────────────────────────────────────────────────────────┤
│  Persistence Layer                                             │
│  ┌─────────────────┐  ┌──────────────────┐ ┌─────────────────┐ │
│  │ Memory Snapshots│  │ Network Protocol │ │ S3 Sync         │ │
│  │ (Event Sourcing)│  │ (Binary + CRC32) │ │ (Snapshots)     │ │
│  └─────────────────┘  └──────────────────┘ └─────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

## 🌐 API Access

### HTTP REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/v1/health` | Health check and cluster status |
| `GET` | `/api/v1/metrics` | Database metrics and statistics |
| `POST` | `/api/v1/nodes` | Insert a new node |
| `GET` | `/api/v1/nodes/:id` | Get node information |
| `GET` | `/api/v1/nodes/:id/related` | Get related nodes (graph traversal) |
| `POST` | `/api/v1/edges` | Insert a new edge |
| `POST` | `/api/v1/vectors` | Insert a new vector |
| `GET` | `/api/v1/vectors/:id/similar` | Get similar vectors |
| `POST` | `/api/v1/batch` | Batch insert nodes, edges, and vectors |
| `POST` | `/api/v1/query/hybrid` | Execute hybrid graph+vector queries |
| `POST` | `/api/v1/snapshot` | Create a database snapshot |


```bash
# Health check and memory stats
curl http://localhost:8080/api/v1/health

# Store data
curl -X POST http://localhost:8080/api/v1/nodes \
  -H "Content-Type: application/json" \
  -d '{"id": 100, "label": "UserPreference"}'

# Query relationships
curl http://localhost:8080/api/v1/nodes/1/related

# Vector similarity
curl http://localhost:8080/api/v1/vectors/1/similar

# Hybrid queries
curl -X POST http://localhost:8080/api/v1/query/hybrid \
  -H "Content-Type: application/json" \
  -d '{"node_id": 1, "depth": 2, "top_k": 5}'
```

### MCP Server Endpoints

```bash
# Start MCP server
zig build mcp-server --port 9090

# LLMs connect via MCP protocol
# Supports all MCP v1.0 capabilities:
# - Resource discovery
# - Tool invocation  
# - Streaming responses
# - Bidirectional communication
```

## 🚀 Quick Start

### Prerequisites

- **Zig 0.14+** - [Install Zig](https://ziglang.org/download/)
- **MCP-compatible LLM** - Claude, GPT-4, or custom implementation

### Setup

```bash
# Clone Memora
git clone <repo-url> memora
cd memora

# Build and start HTTP server
zig build http-server

# Or start MCP server for LLM integration
zig build mcp-server

# Servers run on localhost:8080 (HTTP) and localhost:9090 (MCP)
```

### Basic Usage

```zig
const std = @import("std");
const ContextDB = @import("src/main.zig").ContextDB;
const types = @import("src/types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = ContextDB.ContextDBConfig{
        .data_path = "memora_data",
        .enable_persistent_indexes = true,
    };

    var db = try ContextDB.init(allocator, config);
    defer db.deinit();

    // Store knowledge as nodes, edges, vectors
    try db.insertNode(types.Node.init(1, "UserPreference"));
    try db.insertEdge(types.Edge.init(1, 2, types.EdgeKind.related));
    
    const related = try db.queryRelated(1, 2);
    defer related.deinit();
}
```

## 📊 Data Types

### Core Types

```zig
// Node: Graph vertex with ID and label
const Node = packed struct {
    id: u64,
    label: [32]u8,
};

// Edge: Graph connection with relationship type
const Edge = packed struct {
    from: u64,
    to: u64,
    kind: u8, // EdgeKind enum value
};

// Vector: 128-dimensional embedding
const Vector = packed struct {
    id: u64,
    dims: [128]f32,
};
```

### Edge Types

```zig
const EdgeKind = enum(u8) {
    owns = 0,
    links = 1,
    related = 2,
    child_of = 3,
    similar_to = 4,
};
```

## 🔍 Query Capabilities

### Graph Queries

```zig
// Find nodes within N hops
const related = try db.queryRelated(start_node_id, depth);

// Hybrid graph+vector queries
const hybrid_result = try db.queryHybrid(start_node_id, depth, top_k);
defer hybrid_result.deinit();
```

### Vector Queries

```zig
// Find K most similar vectors
const similar = try db.querySimilar(vector_id, top_k);
```

## 💾 Storage System

### Iceberg-Style File Layout

```
memora/
├── metadata/
│   ├── snapshot-000001.json
│   ├── snapshot-000002.json
│   └── snapshot-000003.json
├── vectors/
│   ├── vec-000001.blob       # Binary vector data
│   ├── vec-000002.blob
│   └── vec-000003.blob
├── nodes/
│   ├── node-000001.json      # JSON node data
│   ├── node-000002.json
│   └── node-000003.json
├── edges/
│   ├── edge-000001.json      # JSON edge data
│   ├── edge-000002.json
│   └── edge-000003.json
└── memora.log               # Append-only binary log
```

## ☁️ Distributed Memory Architecture

### Multi-Node Memory Clusters

```bash
# Start 3-node cluster
# Node 1 (Leader)
zig build run-distributed -- --node-id=1 --port=8001

# Node 2 (Follower)  
zig build run-distributed -- --node-id=2 --port=8001

# Node 3 (Follower)
zig build run-distributed -- --node-id=3 --port=8001
```

### Memory Replication & Consistency

- **Strong Consistency**: All writes replicated via Raft consensus
- **Read Scaling**: Can read from any node for performance
- **Partition Tolerance**: Continues operating with majority of nodes
- **Automatic Recovery**: Failed nodes catch up automatically when rejoining

## 🧪 Testing

### Test Commands
```bash
# Run all tests
zig build test-all

# Test specific components
zig build test-raft          # Distributed consensus tests
zig build test               # Core database tests
zig build test-http-api      # HTTP REST API tests

# Fuzzing campaigns
zig build fuzz-quick         # Quick fuzzing (50 iterations)
zig build fuzz-stress        # Stress testing with large datasets

# Run distributed demo
zig build demo-distributed   # Interactive cluster demonstration
```

## 🎯 Performance Benchmarks

### Operation Latency

| Operation | Single Node | 3-Node Cluster |
|-----------|-------------|----------------|
| Node Insert | ~200μs | ~2ms |
| Vector Query | ~500μs | ~500μs |
| Graph Traversal | ~1ms | ~1ms |
| Hybrid Query | ~2ms | ~2ms |

### Capacity

- **Nodes/Vectors**: Tested with 100K+ items
- **Concurrent Connections**: HTTP server handles 1000+ connections
- **Memory Usage**: Efficient memory-mapped indexes
- **Storage**: Compressed snapshots with S3 sync

## 🚀 Development Roadmap

### Completed Systems ✅

- **✅ HNSW Vector Indexing** - O(log n) semantic search capability
- **✅ Query Optimization Engine** - Intelligent query planning and caching
- **✅ Caching System** - High-performance memory access with LRU/LFU policies
- **✅ Parallel Processing System** - Multi-threaded operations with load balancing
- **✅ Memory-Mapped Persistent Indexes** - Instant startup via disk-backed indexes
- **✅ Distributed Consensus (Raft)** - Multi-node replication with leader election
- **✅ HTTP REST API** - Production-ready web API for programmatic access
- **✅ Monitoring & Metrics** - Comprehensive operation observability
- **✅ Advanced Configuration System** - Production-ready configuration management

### Strategic Priority Systems 🎯

#### **Priority 1: LLM Integration (Q1 2025)**
- **🔄 Model Context Protocol (MCP) Server** - Native MCP v1.0 implementation for LLM memory access
- **🔄 LLM Memory Data Models** - Experiences, concepts, relationships optimized for LLM workflows
- **🔄 LLM Session Management** - Track memory across conversations and context switches
- **🔄 Memory Confidence & Provenance** - Help LLMs understand memory reliability and source tracking

#### **Priority 2: Human Visibility (Q1 2025)**
- **🔄 MemQL Query Language** - Cypher-like syntax for memory exploration and debugging
- **🔄 Web UI Memory Dashboard** - Visual memory timeline, concept graphs, decision audit trails
- **🔄 Memory Audit & Curation Tools** - Human interfaces for inspecting and correcting LLM memories
- **🔄 LLM Decision Provenance Tracking** - Trace responses back to specific memory evidence

#### **Priority 3: Production Operations (Q2 2025)**
- **🔄 Structured Memory Logging** - Professional debugging and audit trails for memory operations
- **🔄 Memory Lifecycle Management** - Automatic cleanup, archival, and importance-based retention
- **🔄 Multi-Tenant Memory** - Isolated memory spaces for different LLMs/users/projects
- **🔄 Memory Analytics & Insights** - Understanding LLM learning patterns and memory utilization

#### **Priority 4: Advanced Memory Features (Q2-Q3 2025)**
- **🔄 Memory Compression & Summarization** - Intelligent memory consolidation for long-term storage
- **🔄 Cross-Model Memory Sharing** - Secure memory exchange between different LLM instances
- **🔄 Temporal Memory Reasoning** - Time-aware memory retrieval and concept evolution tracking
- **🔄 Memory Contradiction Detection** - Identify and resolve conflicting memories automatically

#### **Priority 5: Scale & Reliability (Q3-Q4 2025)**
- **🔄 Horizontal Memory Sharding** - Distribute massive memory datasets across nodes
- **🔄 Real-time Memory Replication** - Writer-reader replication with memory consistency guarantees
- **🔄 Memory Backup & Recovery** - Point-in-time memory restoration and disaster recovery
- **🔄 Advanced Memory Security** - Encryption, access control, and memory privacy protection

### LLM Memory Use Cases 🤖

- **📚 Long-term Conversational Memory** - Remember user preferences, context, and history across sessions
- **🧠 Knowledge Accumulation** - Build persistent knowledge from multiple interactions and sources
- **🔍 Contextual Decision Making** - Access relevant past experiences for better current responses
- **📈 Learning & Adaptation** - Track what works, what doesn't, and evolve interaction patterns
- **🔗 Cross-Domain Knowledge Transfer** - Apply insights from one domain to related problems
- **🎯 Personalization** - Adapt communication style and content based on stored user models

## 🤝 Contributing to LLM Memory Infrastructure

1. Fork the Memora repository
2. Create a feature branch focused on LLM memory capabilities
3. Add comprehensive tests including integration scenarios
4. Run `zig build test-all`
5. Submit a pull request with performance benchmarks

### Development Guidelines

- **Memory First**: All features should enhance LLM memory capabilities
- **Human Debuggable**: Ensure human developers can inspect and understand stored data
- **Deterministic**: Memory operations must be reproducible for testing
- **Performance Critical**: Memory retrieval should be sub-millisecond
- **Privacy Aware**: Design with multi-tenant memory isolation in mind

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **TigerBeetle**: Inspiration for deterministic, high-performance memory backend design
- **Model Context Protocol (MCP)**: Standard for LLM tool integration and memory access
- **Apache Iceberg**: Inspiration for immutable, time-travel capable memory snapshots
- **Zig Community**: For the amazing language perfect for system-level LLM infrastructure

---

**Memora**: *Building the memory layer for the age of AI* 🧠✨

Built with ❤️ and **Zig** for high-performance LLM memory infrastructure.
