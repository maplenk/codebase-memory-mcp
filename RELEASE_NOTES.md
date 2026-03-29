# Ranking v2 — From PageRank to Multi-Signal Composite Search

## The Problem

codebase-memory-mcp v1 used a single signal for ranking: **PageRank**. You'd search for "payment processing" and get back whatever had the highest PageRank score among text matches. This worked for well-connected hub nodes but failed badly for:

- **Concept queries** ("authentication and session management") — PageRank doesn't know that "authentication" means `OauthMiddleware`
- **Cross-file exploration** ("complete order creation flow") — PageRank ranks individual nodes, not flows
- **Vocabulary gaps** — code is named `postOrd`, users search for "create order"

The result: on a 15-case benchmark, the old system scored **30 out of a possible ~200**. Most concept and cross-file queries returned irrelevant results.

## The New Architecture

### Multi-Signal Composite Ranking

Instead of PageRank alone, ranking is now a weighted combination of 5 independent signals:

```
score = W_PPR(0.35)         × Personalized PageRank
      + W_BM25(0.30)        × FTS5 BM25 text relevance
      + W_COCHANGE(0.20)    × Co-change frequency
      + W_BETWEENNESS(0.15) × Betweenness centrality
      + W_AUTHORITY(0.10)   × In-degree authority (HITS)
```

Each signal captures a different aspect of relevance:

| Signal | What it measures | Helps with |
|--------|-----------------|------------|
| **Personalized PageRank** | Graph proximity to query-relevant seed nodes | Finding related code through call/import edges |
| **BM25** | Text match quality (name, qualified_name, file_path, search_terms) | Direct name matches, prefix matching |
| **Co-change** | Files that change together in git history | Finding coupled code across modules |
| **Betweenness centrality** | Nodes that sit on many shortest paths in the graph | Identifying integration points, middleware, shared utilities |
| **In-degree authority** | Number of incoming edges (callers/importers) | Ranking genuinely important code over stubs and auto-generated files |

### FTS5 Search Pipeline

The text search layer was completely rebuilt:

1. **Prefix matching** — Query `"payment"` becomes `payment*` in FTS5, matching CamelCase-concatenated tokens like `paymentmappingservice` (from `PaymentMappingService`). This was the single biggest improvement.

2. **CamelCase splitting** — New `search_terms` column stores split forms: `OauthMiddleware` is indexed as `"OauthMiddleware Oauth Middleware"`. Now `middleware*` finds it. BM25 weight 0.25 (low enough to not dilute primary name matches).

3. **Stop word filtering** — English stop words plus common code verbs (`checks`, `creates`, `handles`, `gets`, `finds`) are stripped before FTS5 query building. Without this, `"checks*"` matched hundreds of `checkXxx` functions.

4. **Per-file result cap** — FNV-1a hash tracks file paths; any single file is limited to 3 FTS results. Prevents large files (like `_ide_helper.php` with 5000+ stubs) from flooding the candidate set. General algorithm, no hardcoded exclusions.

### Personalized PageRank (PPR)

PPR replaced global PageRank. Instead of a static, query-independent rank, PPR is seeded from the top 10 FTS hits and propagates through call/import/inheritance edges with per-type weights:

```
CALLS=1.0, INHERITS=0.9, HTTP_CALLS=0.8, IMPORTS=0.7, ...
```

15 iterations, damping factor 0.85. This means the graph signal is **query-dependent** — searching for "payment" propagates from payment-related nodes, not from globally popular nodes.

### Betweenness Centrality

Brandes' algorithm computes betweenness centrality across the entire call graph. Nodes that sit on many shortest paths (middleware, shared services, base controllers) score higher. This is precomputed at index time and stored in `node_scores.betweenness`.

### In-Degree Authority (Simplified HITS)

Inspired by Kleinberg's HITS algorithm. Instead of full hub/authority iteration, we use a simplified version: count incoming edges per node, normalize to [0,1]. Nodes called by many others are authoritative; auto-generated stubs with 0 callers are penalized.

### Explore Mode FTS Fallback

The `explore` mode (for broad area queries like "order creation flow") previously used only regex matching. When regex found 0 results, it now falls back to `cbm_store_ranked_search` with 20 results. This turned all C-tier cross-file queries from 0 to scoring.

### Compact Output

Removed debug fields (`ppr`, `bm25`, `betweenness`, `composite_score`) from the locate JSON response. The LLM only needs: `name`, `file`, `type`, `line`. Results are sorted by rank — position conveys importance. This saved ~800 bytes per query.

## Development Process

25 bounded iterations using the autoresearch methodology. Each iteration: modify one thing → build → run 2683 unit tests (guard) → score against 15 benchmark cases → keep or discard.

### Score Progression

```
Iter  Score  Delta  Status   What
 0      30    —     base     PageRank-only ranking
 1-7    —     —     discard  Weight tuning, LIKE fallback — no improvement
 8      46   +16    keep     FTS5 prefix queries (word*)
 9      59   +13    keep     Stop word filtering
10      60    +1    keep     Per-file cap (FNV-1a hash)
11      -1   -61    discard  Combined changes — catastrophic
12      72   +12    keep     Context tool + explore FTS fallback
13      73    +1    keep     In-degree authority (HITS)
14      93   +20    keep     Locate results 20→10
15     111   +18    keep     CamelCase splitting (search_terms)
16     112    +1    keep     Per-file cap 5→3
17     152   +40    discard  Synonym table — hardcodes project knowledge
18-22   —     —     discard  Weight tuning, neighbors, PPR iterations
23     120    +8    keep     Remove debug score fields
25     123    +3    keep     Remove composite score field
```

Key lessons:
- **7 failed iterations** before the first improvement. Pure weight tuning doesn't work when the right files aren't in the candidate set.
- **Always test changes in isolation.** Iteration 11 combined two +2 changes and got -61.
- **Don't hardcode.** Synonym tables and file exclusions scored well but were project-specific. Per-file caps and prefix queries are general.
- **Output efficiency matters.** 31 of 123 points came from reducing output bytes, not improving ranking.

## LLM End-to-End Validation

The same 15 cases run through Claude Code with and without codebase-memory-mcp:

|  | No MCP (grep/glob) | With MCP |
|--|---------------------|----------|
| **PASS** | 10 | **11** |
| **PARTIAL** | 4 | **3** |
| **FAIL** | 1 | 1 |
| **Cost** | **$4.56** | $5.03 |
| **Turns** | **88** | 131 |

MCP's advantage is modest because Claude Code is already good at grep/glob searching. The real value: MCP gives **direction on the first call** — the LLM then spends turns reading code deeply rather than searching blindly. On concept queries (B-tier), MCP consistently surfaces files the LLM wouldn't find via grep alone.

## Parameters Reference

```c
// BM25 column weights (src/store/store.c)
bm25(node_fts, 10.0, 5.0, 1.0, 0.25)  // name, qualified_name, file_path, search_terms

// Composite weights
W_PPR         = 0.35
W_BM25        = 0.30
W_COCHANGE    = 0.20
W_BETWEENNESS = 0.15
W_AUTHORITY   = 0.10

// FTS pipeline
PER_FILE_CAP      = 3       // max results per file in FTS candidate set
FILE_TRACK_CAP    = 128     // hash table size for file tracking
FTS_CANDIDATE_LIMIT = 500   // SQL LIMIT on FTS5 query

// PPR
seed_count  = 10    // top FTS hits used as PPR seeds
iterations  = 15
damping     = 0.85

// Output
locate_results  = 10
explore_fallback = 20
```

## Files Changed

- **`src/store/store.c`** — CamelCase splitting (`camel_case_split`, `build_search_terms`), FTS5 schema migration with backfill, per-file cap, stop word filtering, prefix query builder, in-degree authority, betweenness centrality, composite scoring
- **`src/mcp/mcp.c`** — Locate output compaction, explore FTS fallback, result count tuning
- **`src/store/store.h`** — `cbm_ranked_result_t` typedef cleanup
- **`benchmarks/`** — 15 A/B/C test cases, `score_ranking.sh` scoring script, `run_llm_bench.sh` LLM harness, `autoresearch_cases.json`, result archives, `viewer.html`
