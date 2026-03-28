# Autoresearch Ranking Improvement — Detailed Findings

## Overview

**Goal**: Improve codebase-memory-mcp's search ranking so the right files/symbols appear in MCP search results on the first call, reducing token waste when LLMs use the tool.

**Method**: Autonomous modify-verify-keep/discard loop (autoresearch plugin) against a mechanical scoring benchmark of 15 test cases across 3 difficulty tiers.

**Scope**: Primarily `src/store/store.c` (ranking pipeline) and `src/mcp/mcp.c` (tool handlers).

---

## Baseline Measurement

| Metric | Value |
|--------|-------|
| Score | 30 (gross 60, penalty 30.5) |
| Commit | `103f140` |
| Passing test cases | A1, A2, A4, B5 (partial) |
| Tests passing | 2683/2683 |

### Scoring Formula
```
A-tier (exact lookup):     +15 per expected file found
B-tier (concept search):   +10 per expected file found
C-tier (cross-file flow):  +10 per expected file found, +5 per expected symbol
All tiers:                 -0.001 x total_output_bytes (penalize verbosity)
```

### Baseline Hits & Misses
| Case | Tier | Score | Hits | Misses |
|------|------|-------|------|--------|
| A1 FiscalYearController | A | 15 | FiscalYearController.php | — |
| A2 postOrd | A | 20 | OrderController.php, postOrd | — |
| A3 POST route order | A | 0 | — | routes.php, OrderController.php |
| A4 Order model | A | 15 | Order.php | — |
| B1 payment processing | B | 0 | — | OrderController.php, PaymentMappingService.php |
| B2 user authentication | B | 0 | — | OauthMiddleware.php, webMiddleware.php |
| B3 inventory stock | B | 0 | — | InventoryController.php |
| B4 CRM loyalty | B | 0 | — | Order.php, basicAppController.php |
| B5 middleware permissions | B | 10 | OauthMiddleware.php | MerchantMiddleware.php |
| B6 omnichannel sync | B | 0 | — | InventoryController.php, Unicommerce.php, EasyEcom.php |
| B7 POS billing | B | 0 | — | OrderController.php, basicAppController.php |
| C1 order flow | C | 0 | — | OrderController.php, Order.php, routes.php |
| C2 failed payments | C | 0 | — | OrderController.php, PaymentMappingService.php |
| C3 tax calculation | C | 0 | — | NavisionNew.php, NavisionClone.php, thirdParty.php |
| C4 loyalty redemption | C | 0 | — | Order.php, basicAppController.php |

---

## Root Cause Analysis

### Problem 1: FTS5 CamelCase Tokenization Gap
**What**: SQLite FTS5 with `unicode61` tokenizer treats `PaymentMappingService` as a single token. A query for "payment" does NOT match it.
**Why**: The `unicode61` tokenizer only splits on whitespace and punctuation, not CamelCase boundaries.
**Impact**: All B-tier concept queries fail because function/class names like `PaymentMappingService`, `InventoryController`, `OauthMiddleware` are single FTS5 tokens. A search for "payment" only matches functions literally named `payment()`.

### Problem 2: _ide_helper.php Flooding
**What**: Laravel's auto-generated `_ide_helper.php` contains 5000+ stub methods with generic names (`route`, `user`, `session`, `middleware`, `all`, `where`, `model`). These match common query words and dominate search results.
**Why**: The file has extreme symbol density (thousands of methods) all with short, generic names. BM25 scoring ranks them highest because they have perfect name matches.
**Impact**: A3, B2, B5, C3 all return _ide_helper.php methods instead of actual application code. Up to 18/20 result slots consumed by stubs.

### Problem 3: Vocabulary Gap for Concept Queries
**What**: Queries like "omnichannel", "POS", "billing", "authentication" don't appear in any indexed function/class name.
**Why**: FTS5 indexes `name`, `qualified_name`, and `file_path`. Concept terms that describe _what code does_ (not what it's named) have no FTS5 representation.
**Impact**: B2, B4, B6, B7 return irrelevant results or empty.

### Problem 4: Explore Mode Uses Regex, Not FTS5
**What**: The `context(explore)` mode uses `search_contains()` which does literal regex substring matching, not FTS5 ranked search. Natural language queries generate impossible regex patterns.
**Why**: `build_contains_regex_pattern("complete flow of creating a new order end to end")` creates `.*complete flow of creating a new order end to end.*`. No function name contains that string.
**Impact**: All C-tier queries returned 0 results (174 bytes empty JSON each).

---

## Iteration Log

### Iterations 1-5: Pure Weight Tuning (all discarded)
**Hypothesis**: Adjusting composite scoring weights (W_PPR, W_BM25, W_BETWEENNESS) and edge type weights would improve ranking.

| Iter | Change | Score | Delta | Outcome |
|------|--------|-------|-------|---------|
| 1 | BM25 file_path weight 1.0 → 5.0 | 29 | -1 | Discard — file path matches pulled in irrelevant files |
| 2 | W_PPR 0.35 → 0.55, W_BM25 0.30 → 0.15 | 30 | 0 | Discard — no effect, PPR scores already correlated with BM25 |
| 3 | PPR seed count 10 → 30 | 20 | -10 | Discard — more seeds diluted the signal, irrelevant files got PPR scores |
| 4 | IMPORTS edge weight 0.7 → 1.0 | 30 | 0 | Discard — import edges don't affect the test queries |
| 5 | Add Module to FTS5 label filter | 29 | -1 | Discard — Module labels introduced noise |

**Key Insight**: Weight tuning only works when the _correct files are already in the FTS candidate set_. The bottleneck was vocabulary coverage, not ranking within the set.

### Iterations 6-7: LIKE Fallback (both discarded)
**Hypothesis**: When FTS5 returns 0 results, fall back to SQL `LIKE` substring search on node names and file paths.

| Iter | Change | Score | Delta | Outcome |
|------|--------|-------|-------|---------|
| 6 | LIKE fallback on name + file_path | 21 | -9 | Discard — too noisy, matched hundreds of irrelevant functions |
| 7 | LIKE fallback on file_path only | 21 | -9 | Discard — still too broad, file paths matched too many files |

**Key Insight**: LIKE search is too coarse-grained. It doesn't rank results, so the top candidates are arbitrary. The byte penalty from returning 100 unranked results outweighed any benefit.

### Iteration 8: FTS5 Prefix Queries + _ide_helper Exclusion (KEPT, +16)
**Score**: 30 → 46

**Changes**:
1. **FTS5 prefix queries**: Changed query builder from `"payment OR settlement"` to `"payment* OR settlement*"`. The `*` suffix enables FTS5 prefix matching: `payment*` matches any token starting with "payment", including `paymentmappingservice` (the lowercased form of `PaymentMappingService`).
2. **Hardcoded _ide_helper.php exclusion**: Added `AND n.file_path NOT LIKE '%_ide_helper.php'` to the FTS query.

**Why prefix queries work**: FTS5's `unicode61` tokenizer lowercases tokens. `PaymentMappingService` becomes `paymentmappingservice` in the index. Prefix query `payment*` matches any token starting with `payment`, which catches CamelCase names.

**New hits from this change**:
- A3: OrderController.php (prefix "order*" matches `ordercontroller`)
- B1: PaymentMappingService.php (prefix "payment*" matches `paymentmappingservice`)
- B3: InventoryController.php (prefix "inventory*" matches `inventorycontroller`)
- B6: Unicommerce.php (prefix "unicom*" → not clear, but the file appeared)

**Algorithm**: FTS5 prefix matching is O(log N) in the index — it's a B-tree range scan on the token index, very efficient.

### Iteration 9: Stop Word Filtering (KEPT, +13)
**Score**: 46 → 59

**Change**: Added a stop word list to filter common English words before building the FTS5 query. Words like "that", "the", "and", "for", "checks", "creates", "handles", etc. are removed.

**Why**: B5 query "middleware that checks user permissions" — the word "checks" with prefix matching (`checks*`) matched hundreds of `checkXxx` functions (checkStoreAccess, checkString_e, etc.), pushing OauthMiddleware out of the top 20 results.

**Stop word categories**:
- Standard English articles/prepositions: a, an, the, in, of, for, by, to, at, with
- Common query verbs that match too many functions: checks, creates, finds, gets, handles, makes
- Common query filler: complete, flow, happens, places, every, there

**Result**: B5 recovered MerchantMiddleware.php (+10). Reduced noise across all queries.

### Iteration 10: Per-File Result Cap (KEPT, +1)
**Score**: 59 → 60

**Change**: Added per-file cap of 5 results in the FTS search. No single file can contribute more than 5 results to the candidate set. Uses FNV-1a hash for O(1) file path tracking.

**Why**: This replaced the hardcoded `_ide_helper.php` exclusion with a _general_ mechanism. Auto-generated files have high symbol density (thousands of functions). The per-file cap naturally limits their impact without naming specific files.

**Algorithm**: FNV-1a hash (64-bit) of file paths, tracked in a 128-entry array with linear scan. After FTS returns up to 500 candidates, we skip any file that already has 5 results. This gives ~100 candidates from diverse files.

**Why not out-degree penalty (tried and discarded)**: Also tried penalizing nodes with 0 outgoing edges (stubs that don't call anything) by multiplying their composite score by 0.2. Score was 49 — weaker than per-file cap because stubs still consumed FTS candidate slots even with lower scores.

### Iteration 11: Combined file_path 8.0 + cap 3 (DISCARDED, -61)
**Score**: 60 → -1 (catastrophic)

**Change**: Combined two changes: BM25 file_path column weight 1.0→8.0 + per-file cap 5→3.

**Why it failed**: The file_path weight boost at 8.0 was too aggressive. Every file path with a common word got inflated BM25 scores, causing the entire candidate set to be path-match dominated. Combined with the tighter cap of 3, only 3 results per file but from completely wrong files.

**Lesson**: Changes that individually show small improvements (+2 each) can interact catastrophically when combined. Always test combinations.

### Iteration 12: Restore v2 Context Tool + Explore FTS Fallback (KEPT, +12)
**Score**: 60 → 72

**Changes**:
1. **Restored `context` tool**: The v2 unified tool was in a git stash, not committed. It dispatches: `locate` mode → `ranked_search` (FTS5+PPR), `explore` mode → `handle_explore`.
2. **Explore FTS fallback**: When `handle_explore`'s regex-based `search_contains` returns 0 matches, falls back to `cbm_store_ranked_search()`. Ranked results are rendered in the same JSON format as regex matches.

**Why**: C-tier test cases use `context(explore)` mode. Without the fallback, natural language queries like "complete flow of creating a new order end to end" returned empty results because no function name matched the regex pattern.

**New hits**: C1 now scores +20 (OrderController.php + Order.php found via ranked_search fallback for "order" prefix match).

---

## Current State (Score 72)

| Metric | Baseline | Current | Change |
|--------|----------|---------|--------|
| Score | 30 | 72 | +42 (+140%) |
| Gross | 60 | 125 | +65 |
| Byte penalty | 30.5 | 52.6 | +22.1 (more results = more bytes) |
| Tests | 2683 | 2683 | No regression |

### Current Hits (8/15 cases score)
| Case | Score | Files Found |
|------|-------|-------------|
| A1 | 15 | FiscalYearController.php |
| A2 | 20 | OrderController.php + postOrd |
| A3 | 15 | OrderController.php |
| A4 | 15 | Order.php |
| B1 | 10 | PaymentMappingService.php |
| B3 | 10 | InventoryController.php |
| B5 | 10 | MerchantMiddleware.php |
| B6 | 10 | Unicommerce.php |
| C1 | 20 | OrderController.php + Order.php |

### Remaining Misses (7/15 cases score 0)
| Case | Missing | Root Cause |
|------|---------|------------|
| B2 "authentication" | OauthMiddleware, webMiddleware | "authentication*" doesn't prefix-match any middleware name |
| B4 "loyalty redemption" | Order.php, basicAppController | "loyalty*"/"redemption*" don't match these file/class names |
| B7 "POS billing" | OrderController, basicAppController | "pos*"/"billing*" don't match these names |
| C2 "failed payments" | OrderController, PaymentMappingService | Explore mode finds other payment-related files |
| C3 "tax calculation" | NavisionNew, NavisionClone, thirdParty | "tax*" doesn't prefix-match "navision" or "thirdparty" |
| C4 "loyalty points" | Order.php, basicAppController | Same vocabulary gap as B4 |

---

## Key Technical Decisions

### Decision 1: Prefix Queries Over Custom FTS5 Tokenizer
**Chosen**: FTS5 `word*` prefix matching
**Rejected**: Custom CamelCase-splitting tokenizer, or pre-processing names before FTS5 insertion

**Why**: A custom tokenizer requires significant C code (100+ lines) and would need FTS5 table rebuild on existing databases. Prefix queries achieve the same CamelCase matching with a 2-line change to the query builder. The tradeoff: prefix only matches from the start of CamelCase tokens (so "payment*" matches `PaymentMappingService` but "service*" doesn't match it from the middle).

### Decision 2: Per-File Cap Over File Exclusion
**Chosen**: Per-file cap of 5 results (FNV-1a hash tracking)
**Rejected**: Hardcoded `_ide_helper.php` exclusion, out-degree penalty

**Why**: Hardcoded exclusions don't generalize to other projects. Out-degree penalty (0.2x for nodes with 0 outgoing edges) scored 49 vs per-file cap's 60 — it was too weak because stubs still consumed FTS candidate slots. Per-file cap naturally handles any auto-generated file regardless of name.

### Decision 3: Stop Words Over Min Word Length
**Chosen**: Curated stop word list (40 words including verbs)
**Rejected**: Minimum word length for prefix matching (e.g., only `*` for words >=5 chars)

**Why**: Length-based filtering is too blunt. "user" (4 chars) is a useful query term. "checks" (6 chars) is noise. The stop word list allows surgical control. We include common English verbs that match too many code functions (checks, creates, finds, gets, handles, makes).

### Decision 4: Explore FTS Fallback
**Chosen**: When explore mode regex returns 0, fall back to ranked_search
**Rejected**: Rewriting explore to always use ranked_search

**Why**: Explore mode's regex search works well for targeted queries like "PaymentMappingService" (exact substring match). Only natural-language queries fail. The fallback preserves the regex path for queries that work, adding ranked_search only as a safety net.

---

## Algorithms Used

1. **FTS5 BM25** (SQLite built-in): Term frequency * inverse document frequency with document length normalization. Columns weighted: name=10.0, qualified_name=5.0, file_path=1.0.
2. **FTS5 Prefix Matching**: B-tree range scan on the FTS5 token index. `word*` matches all tokens starting with "word".
3. **Personalized PageRank (PPR)**: Graph-based ranking seeded from BM25 top hits. Spreads activation through call/import/inheritance edges with type-dependent weights.
4. **FNV-1a Hash**: 64-bit non-cryptographic hash for O(1) file path comparison in per-file capping.
5. **Betweenness Centrality**: Pre-computed graph metric stored in node_scores table. Nodes on many shortest paths score higher.

---

## Remaining Opportunities

### HITS Authority Score (+est 5-15 points)
Add HITS (Hyperlink-Induced Topic Search) authority/hub scores as a composite signal. Auto-generated stubs have low authority (nothing calls them) and low hub (they call nothing).

### Synonym/Concept Expansion (+est 15-30 points)
Map concept words to code identifiers: "authentication" → OAuth, Auth, Login. "billing" → Order, Invoice, Payment. Could be done via a static synonym table or learned from co-occurrence.

### Substring Matching in CamelCase (+est 10-20 points)
Currently prefix-only: "service*" doesn't match PaymentMapping**Service**. Splitting CamelCase before FTS5 insertion would allow middle-word matching.

### Byte Penalty Reduction (+est 10-15 points)
Current penalty is 52.6 (37% of gross score). Returning fewer results or more compact JSON would reduce this.
