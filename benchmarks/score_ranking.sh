#!/usr/bin/env bash
# score_ranking.sh — Mechanical scoring for autoresearch weight tuning.
#
# Rebuilds the binary, runs test cases against the indexed qbapi project,
# checks if expected files/symbols appear in output, and prints a single
# numeric score to stdout.
#
# Scoring:
#   A-tier (exact):   +15 per expected file found
#   B-tier (concept): +10 per expected file found
#   C-tier (cross):   +10 per expected file found, +5 per expected symbol
#   All tiers:        -0.001 × total_output_bytes (penalize verbosity)
#
# Usage: ./benchmarks/score_ranking.sh
# Output: single integer (e.g., "142")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CBM_CLI="$PROJECT_ROOT/build/c/codebase-memory-mcp"
CASES_FILE="$SCRIPT_DIR/autoresearch_cases.json"

# Step 1: Rebuild
make -C "$PROJECT_ROOT" -f Makefile.cbm cbm -j8 >/dev/null 2>&1

if [ ! -x "$CBM_CLI" ]; then
    echo "0"
    exit 1
fi

if [ ! -f "$CASES_FILE" ]; then
    echo "0"
    exit 1
fi

# Step 2: Run all test cases and score
python3 -c "
import json, subprocess, sys, os

cases_file = '$CASES_FILE'
cli = '$CBM_CLI'

with open(cases_file) as f:
    cases = json.load(f)

total_score = 0.0
total_bytes = 0

for tc in cases:
    tool = tc['tool']
    args = json.dumps(tc['args'])
    tier = tc.get('tier', 'B')

    # Run CLI
    try:
        result = subprocess.run(
            [cli, 'cli', tool, args],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout
    except Exception:
        output = ''

    output_bytes = len(output.encode('utf-8'))
    total_bytes += output_bytes
    output_lower = output.lower()

    # Score expected files
    expected_files = tc.get('expected_files', [])
    for ef in expected_files:
        if ef.lower() in output_lower:
            if tier == 'A':
                total_score += 15
            elif tier == 'B':
                total_score += 10
            else:  # C
                total_score += 10

    # Score expected symbols
    expected_symbols = tc.get('expected_symbols', [])
    for es in expected_symbols:
        if es.lower() in output_lower:
            if tier == 'C':
                total_score += 5
            else:
                total_score += 5

# Penalize verbosity (0.001 per byte)
total_score -= total_bytes * 0.001

# Print single integer
print(int(round(total_score)))
"
