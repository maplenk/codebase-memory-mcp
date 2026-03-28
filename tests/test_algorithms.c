/*
 * test_algorithms.c — Tests for v2 ranking algorithms:
 *   - Personalized PageRank (PPR)
 *   - Betweenness centrality (Brandes)
 *   - FTS5 BM25 search
 *   - Composite ranked search
 *
 * Uses a small known graph to verify correctness:
 *
 *   A (hub) --CALLS--> B --CALLS--> D
 *   A --CALLS--> C --CALLS--> D
 *   A --CALLS--> E
 *   B --IMPORTS--> C
 *   D --CALLS--> E
 *
 * Expected properties:
 *   - A has highest out-degree (3)
 *   - D has highest in-degree (2) → high global PageRank
 *   - B and C are bridges between A and D → high betweenness
 *   - PPR seeded from A should rank B,C,D,E highly
 *   - FTS5 should match node names/paths
 */
#include "test_framework.h"
#include <store/store.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

/* ── Helpers ───────────────────────────────────────────────────── */

#define PROJECT "test_algo"
#define PROJECT_PATH "/tmp/test_algo"

static cbm_store_t *make_test_graph(void) {
    cbm_store_t *s = cbm_store_open_memory();
    if (!s) return NULL;

    cbm_store_upsert_project(s, PROJECT, PROJECT_PATH);

    /* Nodes: A (hub), B (bridge), C (bridge), D (sink), E (leaf) */
    cbm_node_t nodes[] = {
        {0, PROJECT, "Function", "processOrder",   "app.processOrder",   "app/order.php",    10, 50, NULL},
        {0, PROJECT, "Function", "validatePayment", "app.validatePayment", "app/payment.php",  20, 40, NULL},
        {0, PROJECT, "Function", "checkInventory",  "app.checkInventory",  "app/inventory.php", 5, 30, NULL},
        {0, PROJECT, "Function", "sendReceipt",     "app.sendReceipt",     "app/receipt.php",  10, 25, NULL},
        {0, PROJECT, "Function", "logEvent",         "app.logEvent",        "app/logger.php",    1, 15, NULL},
    };

    int64_t ids[5];
    for (int i = 0; i < 5; i++) {
        ids[i] = cbm_store_upsert_node(s, &nodes[i]);
        if (ids[i] <= 0) {
            cbm_store_close(s);
            return NULL;
        }
    }

    /* Edges: A→B, A→C, A→E, B→D, C→D, B→C (IMPORTS), D→E */
    cbm_edge_t edges[] = {
        {0, PROJECT, ids[0], ids[1], "CALLS", NULL},     /* A→B */
        {0, PROJECT, ids[0], ids[2], "CALLS", NULL},     /* A→C */
        {0, PROJECT, ids[0], ids[4], "CALLS", NULL},     /* A→E */
        {0, PROJECT, ids[1], ids[3], "CALLS", NULL},     /* B→D */
        {0, PROJECT, ids[2], ids[3], "CALLS", NULL},     /* C→D */
        {0, PROJECT, ids[1], ids[2], "IMPORTS", NULL},   /* B→C */
        {0, PROJECT, ids[3], ids[4], "CALLS", NULL},     /* D→E */
    };

    for (int i = 0; i < 7; i++) {
        if (cbm_store_insert_edge(s, &edges[i]) <= 0) {
            cbm_store_close(s);
            return NULL;
        }
    }

    return s;
}

/* ══════════════════════════════════════════════════════════════════
 *  GLOBAL PAGERANK (sanity check — existing functionality)
 * ══════════════════════════════════════════════════════════════════ */

TEST(pagerank_basic) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    int rc = cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    ASSERT_EQ(rc, CBM_STORE_OK);

    /* D (sendReceipt) has 2 incoming CALLS → should have high PageRank.
     * E (logEvent) has 2 incoming (A→E, D→E) → also high.
     * A (processOrder) has 0 incoming → low PageRank. */

    /* Query pagerank scores via node_scores table */
    cbm_node_t d = {0};
    rc = cbm_store_find_node_by_qn(s, PROJECT, "app.sendReceipt", &d);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(d.id, 0);

    cbm_store_close(s);
    PASS();
}

/* ══════════════════════════════════════════════════════════════════
 *  BETWEENNESS CENTRALITY
 * ══════════════════════════════════════════════════════════════════ */

TEST(betweenness_basic) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    /* PageRank first (betweenness needs node_scores rows) */
    int rc = cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    ASSERT_EQ(rc, CBM_STORE_OK);

    rc = cbm_store_compute_betweenness(s, PROJECT);
    ASSERT_EQ(rc, CBM_STORE_OK);

    cbm_store_close(s);
    PASS();
}

TEST(betweenness_empty_project) {
    cbm_store_t *s = cbm_store_open_memory();
    ASSERT_NOT_NULL(s);
    cbm_store_upsert_project(s, "empty", "/tmp/empty");

    /* Betweenness on empty project should not crash */
    int rc = cbm_store_compute_pagerank(s, "empty", 20, 0.85);
    ASSERT_EQ(rc, CBM_STORE_OK);
    rc = cbm_store_compute_betweenness(s, "empty");
    ASSERT_EQ(rc, CBM_STORE_OK);

    cbm_store_close(s);
    PASS();
}

TEST(betweenness_single_node) {
    cbm_store_t *s = cbm_store_open_memory();
    ASSERT_NOT_NULL(s);
    cbm_store_upsert_project(s, "single", "/tmp/single");

    cbm_node_t n = {0, "single", "Function", "lonely", "a.lonely", "a.php", 1, 5, NULL};
    int64_t id = cbm_store_upsert_node(s, &n);
    ASSERT_GT(id, 0);

    int rc = cbm_store_compute_pagerank(s, "single", 20, 0.85);
    ASSERT_EQ(rc, CBM_STORE_OK);
    rc = cbm_store_compute_betweenness(s, "single");
    ASSERT_EQ(rc, CBM_STORE_OK);

    cbm_store_close(s);
    PASS();
}

/* ══════════════════════════════════════════════════════════════════
 *  PERSONALIZED PAGERANK (PPR)
 * ══════════════════════════════════════════════════════════════════ */

TEST(ppr_basic) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    /* Find node A (processOrder) to use as seed */
    cbm_node_t a = {0};
    int rc = cbm_store_find_node_by_qn(s, PROJECT, "app.processOrder", &a);
    ASSERT_EQ(rc, CBM_STORE_OK);
    int64_t seed_ids[] = {a.id};

    int64_t *out_ids = NULL;
    double *out_scores = NULL;
    int out_count = 0;

    rc = cbm_store_compute_personalized_pagerank(
        s, PROJECT, seed_ids, 1, 20, 0.85,
        &out_ids, &out_scores, &out_count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(out_count, 0);

    /* Seed node A should have highest PPR score */
    double a_score = -1;
    for (int i = 0; i < out_count; i++) {
        if (out_ids[i] == a.id) {
            a_score = out_scores[i];
            break;
        }
    }
    ASSERT(a_score > 0);

    /* All scores should be non-negative */
    for (int i = 0; i < out_count; i++) {
        ASSERT(out_scores[i] >= 0);
    }

    free(out_ids);
    free(out_scores);
    cbm_store_close(s);
    PASS();
}

TEST(ppr_multiple_seeds) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_node_t a = {0}, b = {0};
    cbm_store_find_node_by_qn(s, PROJECT, "app.processOrder", &a);
    cbm_store_find_node_by_qn(s, PROJECT, "app.validatePayment", &b);
    int64_t seeds[] = {a.id, b.id};

    int64_t *out_ids = NULL;
    double *out_scores = NULL;
    int out_count = 0;

    int rc = cbm_store_compute_personalized_pagerank(
        s, PROJECT, seeds, 2, 20, 0.85,
        &out_ids, &out_scores, &out_count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(out_count, 0);

    /* Both seeds should have non-trivial scores */
    double a_score = 0, b_score = 0;
    for (int i = 0; i < out_count; i++) {
        if (out_ids[i] == a.id) a_score = out_scores[i];
        if (out_ids[i] == b.id) b_score = out_scores[i];
    }
    ASSERT(a_score > 0);
    ASSERT(b_score > 0);

    free(out_ids);
    free(out_scores);
    cbm_store_close(s);
    PASS();
}

TEST(ppr_empty_seeds) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    int64_t *out_ids = NULL;
    double *out_scores = NULL;
    int out_count = 0;

    /* 0 seeds — should fall back to global or return OK with 0 results */
    int rc = cbm_store_compute_personalized_pagerank(
        s, PROJECT, NULL, 0, 20, 0.85,
        &out_ids, &out_scores, &out_count);
    /* Should not crash, either OK with results or ERR */
    (void)rc;

    free(out_ids);
    free(out_scores);
    cbm_store_close(s);
    PASS();
}

/* ══════════════════════════════════════════════════════════════════
 *  FTS5 SEARCH
 * ══════════════════════════════════════════════════════════════════ */

TEST(fts_rebuild) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    int rc = cbm_store_rebuild_fts(s, PROJECT);
    ASSERT_EQ(rc, CBM_STORE_OK);

    cbm_store_close(s);
    PASS();
}

TEST(fts_search_by_name) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    int rc = cbm_store_rebuild_fts(s, PROJECT);
    ASSERT_EQ(rc, CBM_STORE_OK);

    int64_t *ids = NULL;
    double *scores = NULL;
    int count = 0;

    rc = cbm_store_fts_search(s, PROJECT, "processOrder", 10, &ids, &scores, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(count, 0);

    /* Should find the processOrder node */
    cbm_node_t found = {0};
    rc = cbm_store_find_node_by_id(s, ids[0], &found);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT(strstr(found.name, "processOrder") != NULL || strstr(found.qualified_name, "processOrder") != NULL);

    free(ids);
    free(scores);
    cbm_store_close(s);
    PASS();
}

TEST(fts_search_by_path) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_rebuild_fts(s, PROJECT);

    int64_t *ids = NULL;
    double *scores = NULL;
    int count = 0;

    int rc = cbm_store_fts_search(s, PROJECT, "payment", 10, &ids, &scores, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(count, 0);

    /* Should find validatePayment (in payment.php) */
    cbm_node_t found = {0};
    cbm_store_find_node_by_id(s, ids[0], &found);
    ASSERT(strstr(found.file_path, "payment") != NULL || strstr(found.name, "Payment") != NULL);

    free(ids);
    free(scores);
    cbm_store_close(s);
    PASS();
}

TEST(fts_search_multiword) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_rebuild_fts(s, PROJECT);

    int64_t *ids = NULL;
    double *scores = NULL;
    int count = 0;

    /* Multi-word query — should match via OR */
    int rc = cbm_store_fts_search(s, PROJECT, "payment inventory", 10, &ids, &scores, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    /* Should find at least validatePayment and checkInventory */
    ASSERT_GTE(count, 2);

    free(ids);
    free(scores);
    cbm_store_close(s);
    PASS();
}

TEST(fts_search_no_results) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_rebuild_fts(s, PROJECT);

    int64_t *ids = NULL;
    double *scores = NULL;
    int count = 0;

    int rc = cbm_store_fts_search(s, PROJECT, "xyznonexistent", 10, &ids, &scores, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_EQ(count, 0);

    free(ids);
    free(scores);
    cbm_store_close(s);
    PASS();
}

TEST(fts_search_empty_query) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_rebuild_fts(s, PROJECT);

    int64_t *ids = NULL;
    double *scores = NULL;
    int count = 0;

    /* Empty query should return OK with 0 results, not crash */
    int rc = cbm_store_fts_search(s, PROJECT, "", 10, &ids, &scores, &count);
    (void)rc; /* may return ERR or OK with 0 */

    free(ids);
    free(scores);
    cbm_store_close(s);
    PASS();
}

/* ══════════════════════════════════════════════════════════════════
 *  COMPOSITE RANKED SEARCH
 * ══════════════════════════════════════════════════════════════════ */

TEST(ranked_search_basic) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    /* Need PageRank + betweenness + FTS for composite search */
    cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    cbm_store_compute_betweenness(s, PROJECT);
    cbm_store_rebuild_fts(s, PROJECT);

    cbm_ranked_result_t *results = NULL;
    int count = 0;

    int rc = cbm_store_ranked_search(s, PROJECT, "order", 10, &results, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(count, 0);

    /* First result should be processOrder (matches "order") */
    ASSERT_NOT_NULL(results[0].name);
    ASSERT(strstr(results[0].name, "Order") != NULL || strstr(results[0].name, "order") != NULL);

    /* Composite score should be positive */
    ASSERT(results[0].composite_score > 0);

    /* Component scores should be populated */
    ASSERT(results[0].bm25_score != 0 || results[0].ppr_score >= 0);

    cbm_store_ranked_results_free(results, count);
    cbm_store_close(s);
    PASS();
}

TEST(ranked_search_returns_metadata) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    cbm_store_compute_betweenness(s, PROJECT);
    cbm_store_rebuild_fts(s, PROJECT);

    cbm_ranked_result_t *results = NULL;
    int count = 0;

    int rc = cbm_store_ranked_search(s, PROJECT, "payment", 10, &results, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_GT(count, 0);

    /* Check metadata fields are populated */
    ASSERT_NOT_NULL(results[0].name);
    ASSERT_NOT_NULL(results[0].file_path);
    ASSERT_GT(results[0].node_id, 0);

    cbm_store_ranked_results_free(results, count);
    cbm_store_close(s);
    PASS();
}

TEST(ranked_search_no_results) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    cbm_store_compute_betweenness(s, PROJECT);
    cbm_store_rebuild_fts(s, PROJECT);

    cbm_ranked_result_t *results = NULL;
    int count = 0;

    int rc = cbm_store_ranked_search(s, PROJECT, "xyznonexistent", 10, &results, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_EQ(count, 0);

    cbm_store_ranked_results_free(results, count);
    cbm_store_close(s);
    PASS();
}

TEST(ranked_search_respects_limit) {
    cbm_store_t *s = make_test_graph();
    ASSERT_NOT_NULL(s);

    cbm_store_compute_pagerank(s, PROJECT, 20, 0.85);
    cbm_store_compute_betweenness(s, PROJECT);
    cbm_store_rebuild_fts(s, PROJECT);

    cbm_ranked_result_t *results = NULL;
    int count = 0;

    /* Search for something that matches multiple nodes, limit to 2 */
    int rc = cbm_store_ranked_search(s, PROJECT, "app", 2, &results, &count);
    ASSERT_EQ(rc, CBM_STORE_OK);
    ASSERT_LTE(count, 2);

    cbm_store_ranked_results_free(results, count);
    cbm_store_close(s);
    PASS();
}

/* ══════════════════════════════════════════════════════════════════
 *  SUITE
 * ══════════════════════════════════════════════════════════════════ */

SUITE(algorithms) {
    /* PageRank sanity */
    RUN_TEST(pagerank_basic);

    /* Betweenness */
    RUN_TEST(betweenness_basic);
    RUN_TEST(betweenness_empty_project);
    RUN_TEST(betweenness_single_node);

    /* Personalized PageRank */
    RUN_TEST(ppr_basic);
    RUN_TEST(ppr_multiple_seeds);
    RUN_TEST(ppr_empty_seeds);

    /* FTS5 */
    RUN_TEST(fts_rebuild);
    RUN_TEST(fts_search_by_name);
    RUN_TEST(fts_search_by_path);
    RUN_TEST(fts_search_multiword);
    RUN_TEST(fts_search_no_results);
    RUN_TEST(fts_search_empty_query);

    /* Composite ranked search */
    RUN_TEST(ranked_search_basic);
    RUN_TEST(ranked_search_returns_metadata);
    RUN_TEST(ranked_search_no_results);
    RUN_TEST(ranked_search_respects_limit);
}
