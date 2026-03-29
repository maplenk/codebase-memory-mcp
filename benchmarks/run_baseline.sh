#!/usr/bin/env bash
# run_baseline.sh — Capture baseline results from codebase-memory-mcp CLI
#
# Usage: ./benchmarks/run_baseline.sh [output_dir] [test_cases_file]
# Default output: benchmarks/baseline_v1/
# Default test cases: benchmarks/test_cases.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CBM_CLI="$PROJECT_ROOT/build/c/codebase-memory-mcp"
TEST_CASES="${2:-$SCRIPT_DIR/test_cases.json}"
OUTPUT_DIR="${1:-$SCRIPT_DIR/baseline_v1}"

if [ ! -x "$CBM_CLI" ]; then
    echo "ERROR: CLI binary not found at $CBM_CLI"
    echo "Build first: cd $PROJECT_ROOT && make -f Makefile.cbm cbm"
    exit 1
fi

if [ ! -f "$TEST_CASES" ]; then
    echo "ERROR: Test cases not found at $TEST_CASES"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Get number of test cases
NUM_CASES=$(python3 -c "import json; print(len(json.load(open('$TEST_CASES'))))")
echo "Running $NUM_CASES test cases..."
echo "Output directory: $OUTPUT_DIR"
echo "---"

# Summary file
SUMMARY="$OUTPUT_DIR/summary.json"
echo '{"runs": [' > "$SUMMARY"
FIRST=true

for i in $(seq 0 $((NUM_CASES - 1))); do
    # Extract test case fields
    TC=$(python3 -c "
import json, sys
cases = json.load(open('$TEST_CASES'))
tc = cases[$i]
print(json.dumps(tc))
")
    ID=$(echo "$TC" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
    TOOL=$(echo "$TC" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool'])")
    ARGS=$(echo "$TC" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['args']))")
    DESC=$(echo "$TC" | python3 -c "import json,sys; print(json.load(sys.stdin)['description'])")

    echo "[$((i+1))/$NUM_CASES] $ID: $DESC"
    echo "  Tool: $TOOL"

    # Run CLI and capture timing
    OUTFILE="$OUTPUT_DIR/${ID}.json"
    START_NS=$(python3 -c "import time; print(int(time.time_ns()))")

    "$CBM_CLI" cli "$TOOL" "$ARGS" > "$OUTFILE" 2>/dev/null || true

    END_NS=$(python3 -c "import time; print(int(time.time_ns()))")
    ELAPSED_MS=$(python3 -c "print(($END_NS - $START_NS) / 1_000_000)")

    # Measure output size
    OUTPUT_BYTES=$(wc -c < "$OUTFILE" | tr -d ' ')

    # Estimate token count (~4 chars per token)
    EST_TOKENS=$(python3 -c "print($OUTPUT_BYTES // 4)")

    echo "  Time: ${ELAPSED_MS}ms | Size: ${OUTPUT_BYTES} bytes (~${EST_TOKENS} tokens)"

    # Append to summary
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo ',' >> "$SUMMARY"
    fi

    python3 -c "
import json
entry = {
    'id': '$ID',
    'tool': '$TOOL',
    'description': '$DESC',
    'elapsed_ms': $ELAPSED_MS,
    'output_bytes': $OUTPUT_BYTES,
    'est_tokens': $EST_TOKENS
}
print(json.dumps(entry, indent=2), end='')
" >> "$SUMMARY"

    echo ""
done

echo ']}' >> "$SUMMARY"

echo "---"
echo "Baseline capture complete. Summary: $SUMMARY"

# Rebuild index.json listing all available runs (for viewer.html)
python3 -c "
import os, json, glob
runs = sorted([os.path.basename(os.path.dirname(p))
               for p in glob.glob(os.path.join('$SCRIPT_DIR', '*/summary.json'))])
with open(os.path.join('$SCRIPT_DIR', 'index.json'), 'w') as f:
    json.dump(runs, f)
print(f'Updated index.json: {runs}')
"

# Print summary table
echo ""
echo "=== BASELINE SUMMARY ==="
python3 -c "
import json

with open('$SUMMARY') as f:
    data = json.load(f)

total_ms = 0
total_bytes = 0
total_tokens = 0

print(f'{'ID':<30} {'Time (ms)':>10} {'Bytes':>10} {'~Tokens':>10}')
print('-' * 64)
for run in data['runs']:
    total_ms += run['elapsed_ms']
    total_bytes += run['output_bytes']
    total_tokens += run['est_tokens']
    print(f\"{run['id']:<30} {run['elapsed_ms']:>10.1f} {run['output_bytes']:>10} {run['est_tokens']:>10}\")

print('-' * 64)
print(f\"{'TOTAL':<30} {total_ms:>10.1f} {total_bytes:>10} {total_tokens:>10}\")
"
