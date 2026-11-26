# SVS-VAMANA Vector Index in Redis — Intel® AI for Enterprise Agent Toolkit

The shared Redis of the Agent Toolkit is open-source **Redis 8** (`redis_stack_tag`, default `8.10.3`). Redis 8 has three vector index types built in. One of them is **SVS-VAMANA**, the graph index from Intel® [Scalable Vector Search](https://github.com/intel/ScalableVectorSearch).

The toolkit does not create any vector index itself. Each agent app picks the index type when it creates its own index. **HNSW stays a good default.** This guide shows when SVS-VAMANA is the better choice and how to use it.

- [Which index to choose](#which-index-to-choose)
- [Create an SVS-VAMANA index](#create-an-svs-vamana-index)
- [Search an SVS-VAMANA index](#search-an-svs-vamana-index)
- [Settings](#settings)
- [Measured results](#measured-results)
- [Limits](#limits)

## Which index to choose

| Index | Pick it when | Keep in mind |
|---|---|---|
| `FLAT` | Small data (a few thousand vectors), or each search is filtered to a small part of the data (for example one user's memories) | Exact results. Every search reads all matching vectors |
| `HNSW` | General use. This is the right default for most agents | No compression |
| `SVS-VAMANA` | You need the highest accuracy (recall about 0.995 at large search windows), or each agent holds about 10,000 memories or more | Builds a little slower than HNSW at small sizes. Same memory as HNSW |
| `SVS-VAMANA` + `COMPRESSION LVQ8` | Memory is the cost: the index is about **73% smaller** | On open-source Redis this becomes 8-bit scalar compression (`GlobalSQ8`, see [Limits](#limits)). Accuracy stops near 0.98. On small data it is slower than plain SVS-VAMANA |

In an agent, one memory search takes a few milliseconds, while one LLM turn takes seconds. So the index type rarely changes how long an agent task takes. It matters when agents search a lot (many searches per turn), memory is large (10,000+ memories per agent), many agents run at once, and the LLM is fast.

## Create an SVS-VAMANA index

Get the Redis URL from the toolkit's Secret (see [Backend Connection Reference](backend-connection-reference.md#redis-session-memory--caching)):

```bash
export REDIS_URL=$(kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d)
```

### With redis-cli

```bash
redis-cli -u "$REDIS_URL"    # or: kubectl exec -it -n redis redis-stack-server-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning'
```

```
# Plain SVS-VAMANA: 768-dimension vectors, cosine distance, filter by user
FT.CREATE agent_memory ON HASH PREFIX 1 memory: SCHEMA user_id TAG text TEXT embedding VECTOR SVS-VAMANA 6 TYPE FLOAT32 DIM 768 DISTANCE_METRIC COSINE

# Same, with compression (about 73% smaller index)
FT.CREATE agent_memory ON HASH PREFIX 1 memory: SCHEMA user_id TAG text TEXT embedding VECTOR SVS-VAMANA 8 TYPE FLOAT32 DIM 768 DISTANCE_METRIC COSINE COMPRESSION LVQ8
```

The number after `SVS-VAMANA` is the count of the words that follow it (`6` or `8` above). Check the index with `FT.INFO agent_memory`: it shows `algorithm SVS-VAMANA`, and `compression NO` or `compression GlobalSQ8`.

### With RedisVL (Python)

[RedisVL](https://github.com/redis/redis-vl-python) 0.33 and later support SVS-VAMANA (`pip install redisvl`). Set `algorithm` to `svs-vamana`:

```python
import os
import numpy as np
from redisvl.index import SearchIndex
from redisvl.query import VectorQuery

schema = {
    "index": {"name": "agent_memory", "prefix": "memory", "storage_type": "hash"},
    "fields": [
        {"name": "user_id", "type": "tag"},
        {"name": "text", "type": "text"},
        {
            "name": "embedding",
            "type": "vector",
            "attrs": {
                "algorithm": "svs-vamana",
                "dims": 768,
                "distance_metric": "cosine",
                "datatype": "float32",
                # Optional: about 73% smaller index (8-bit scalar compression on open-source Redis)
                # "compression": "LVQ8",
            },
        },
    ],
}

index = SearchIndex.from_dict(schema, redis_url=os.environ["REDIS_URL"])
index.create(overwrite=True)

vec = np.random.rand(768).astype(np.float32)
index.load([{"user_id": "alice", "text": "Prefers email updates", "embedding": vec.tobytes()}])

query = VectorQuery(
    vector=vec.tolist(),
    vector_field_name="embedding",
    return_fields=["text"],
    num_results=4,
    search_window_size=40,  # SVS-VAMANA only; larger = more accurate, slower
)
print(index.query(query))
```

To move an existing app from HNSW to SVS-VAMANA, create the index with the new type under the same name before the app starts. Apps that reuse an existing index then use it with no code change. To change an index that already exists, drop it (`FT.DROPINDEX <name>`, without `DD`, keeps the data) and create it again; Redis indexes the stored data again.

## Search an SVS-VAMANA index

The search is the same as for HNSW. Only the tuning option has another name: `SEARCH_WINDOW_SIZE` instead of `EF_RUNTIME`. `EF_RUNTIME` on an SVS-VAMANA index returns an error.

```
# Top 4 memories of one user; $vec is the query embedding as raw float32 bytes
FT.SEARCH agent_memory "(@user_id:{alice})=>[KNN 4 @embedding $vec SEARCH_WINDOW_SIZE 40 AS score]" PARAMS 2 vec "<bytes>" RETURN 2 text score SORTBY score DIALECT 2
```

A window of about 40 gave recall 0.95–0.97 in our tests. Use 80–160 when accuracy matters more than speed.

## Settings

| Setting | Where | Default | What it does |
|---|---|---|---|
| `redis_stack_image` | `env/<name>/config.agent-toolkit.yaml` | `redis` | Redis image |
| `redis_stack_tag` | `env/<name>/config.agent-toolkit.yaml` | `8.10.3` | Redis version. SVS-VAMANA needs **8.2 or later** |
| `GRAPH_MAX_DEGREE` | `FT.CREATE` | `32` | Links per vector in the graph. Higher = more accurate, more memory |
| `CONSTRUCTION_WINDOW_SIZE` | `FT.CREATE` | `200` | Search window while building. Higher = better graph, slower build |
| `COMPRESSION` | `FT.CREATE` | none | `LVQ8`, `LVQ4x8` and others. Becomes `GlobalSQ8` on open-source Redis |
| `SEARCH_WINDOW_SIZE` | `FT.CREATE` or the query | `10` | Search window. Higher = more accurate, slower |

RedisVL uses its own build defaults (`graph_max_degree` 40, `construction_window_size` 250, `search_window_size` 20) unless you set them.

Redis 8.10 searches with 16 worker threads by default (fewer if Redis sees fewer CPU cores). Check with `CONFIG GET search-workers`.

After a change to `redis_stack_image` or `redis_stack_tag`, upgrade Redis alone. Data is kept:

```bash
./es_auto_installer.sh install redis_stack --only
./es_auto_installer.sh validate redis_stack --only    # includes an SVS-VAMANA check
```

## Measured results

Intel® Xeon® 6 (6783P-C), single-node cluster, Redis 8.10.3 with 16 search threads, toolkit Redis role. 100,000 DBpedia texts embedded with `BAAI/bge-base-en-v1.5` (768 dimensions), 1,000 held-out queries, Python client, single runs.

**Search over all data, search window 40, 32 clients:**

| Index | Recall@10 | p50 latency | Searches per second | Index memory | Build time |
|---|---|---|---|---|---|
| FLAT | 1.000 | 29.4 ms | 685 | 299 MB | 3 s |
| HNSW (M 16, EF_CONSTRUCTION 200) | 0.950 | 1.5 ms | 45,687 | 327 MB | 15 s |
| SVS-VAMANA | 0.966 | 1.8 ms | 40,314 | 308 MB | 14 s |
| SVS-VAMANA + LVQ8 (`GlobalSQ8`) | 0.959 | 1.6 ms | 46,967 | **89 MB** | 10 s |

**High accuracy, search window 160, 32 clients:**

| Index | Recall@10 | Searches per second |
|---|---|---|
| HNSW | 0.992 | 29,312 |
| SVS-VAMANA | **0.995** | 17,083 |
| SVS-VAMANA + LVQ8 (`GlobalSQ8`) | 0.985 | 27,059 |

**Search inside one user (1% of the data):** all index types gave about the same speed (28,600–38,600 searches per second), and FLAT was exact. SVS-VAMANA + LVQ8 recall was 0.989 instead of 1.000.

**By memory size per agent** (same data, the agent's real filtered query):

| Memories per agent | SVS-VAMANA vs HNSW |
|---|---|
| 1,000 | Same within a few ms |
| 10,000 | 42–46% faster per search, 70–91% more searches per second |
| 100,000 | 32% faster at 256 searches at once; about the same at lower load |

**In a real agent** (LLM on CPU, about 16 s per turn), memory search was under 0.2% of task time with every index type, even with 100,000 memories per user.

**Redis Stack 7.4 compared with Redis 8.10.3** (100,000 × 768-d vectors, `BAAI/bge-base-en-v1.5`, search window 40, 32 clients):

| Redis and index | Recall@10 | Searches per second | Index memory | Build time |
|---|---|---|---|---|
| Redis Stack 7.4.7, HNSW (before this upgrade) | 0.949 | 6,460 | 329 MB | 52 s |
| Redis 8.10.3, HNSW | 0.950 | 45,687 | 327 MB | 15 s |
| Redis 8.10.3, SVS-VAMANA | 0.966 | 40,314 | 308 MB | 14 s |
| Redis 8.10.3, SVS-VAMANA + LVQ8 (`GlobalSQ8`) | 0.959 | 46,967 | 89 MB | 10 s |

The upgrade alone gives about **7× more searches per second** and **5× faster index builds** with any index, mostly from Redis 8.10's 16 search threads (the default). SVS-VAMANA with compression cuts index memory by **about 73%**.

## Limits

- **Intel LVQ and LeanVec compression are not in open-source Redis.** The official `redis` image has no Intel compression library. When you ask for `COMPRESSION LVQ8` (or another LVQ type), Redis uses 8-bit scalar compression (`GlobalSQ8`) instead. It saves the same memory but reaches lower accuracy (about 0.98 at most). Intel LVQ and LeanVec need a Redis built with Intel's library (`BUILD_INTEL_SVS_OPT=yes`), which uses Redis under the RSALv2 licence. The Agent Toolkit does not ship that build.
- **SVS-VAMANA does not make Redis faster in general.** Above about 45,000 searches per second, the limit was most likely Redis's main thread or the test client, not the index.
- **Only on Redis 8.2 or later.** On an older Redis, `FT.CREATE` with `SVS-VAMANA` fails with `Bad arguments for vector similarity algorithm`.
- **Results come from one dataset on one machine.** Measure with your own data before you switch.
