#!/usr/bin/env bash
# run_llm_bench.sh — Run LLM comparison benchmarks
#
# Runs 5 coding tasks across 4 configurations:
#   1. Claude without MCP (grep/glob/read only)
#   2. Claude with MCP (codebase-memory-mcp tools available)
#   3. Codex without MCP
#   4. Codex with MCP
#
# Usage: ./benchmarks/run_llm_bench.sh [output_dir] [--config=CONFIG]
#   CONFIG: all | claude-nomcp | claude-mcp | codex-nomcp | codex-mcp
#   Default: all
#
# Prerequisites:
#   - claude CLI (claude.ai/code)
#   - codex CLI (codex-cli)
#   - qbapi repo at /Users/naman/Documents/QBApps/qbapi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TASKS_DIR="$SCRIPT_DIR/llm_tasks"
QBAPI_DIR="/Users/naman/Documents/QBApps/qbapi"
OUTPUT_DIR="${1:-$SCRIPT_DIR/llm_results}"
CONFIG="${2:---config=all}"
CONFIG="${CONFIG#--config=}"

MAX_TURNS=15

# MCP config for codebase-memory-mcp
MCP_CONFIG='{
  "mcpServers": {
    "codebase-memory-mcp": {
      "command": "'"$PROJECT_ROOT"'/build/c/codebase-memory-mcp",
      "args": []
    }
  }
}'

if [ ! -d "$QBAPI_DIR" ]; then
    echo "ERROR: qbapi repo not found at $QBAPI_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Task files
TASKS=($(ls "$TASKS_DIR"/*.md | sort))
NUM_TASKS=${#TASKS[@]}

echo "=== LLM Benchmark Runner ==="
echo "Tasks: $NUM_TASKS"
echo "Config: $CONFIG"
echo "Output: $OUTPUT_DIR"
echo "Max turns: $MAX_TURNS"
echo "---"

# Summary accumulator
SUMMARY_FILE="$OUTPUT_DIR/summary.json"
echo '{"config":"'"$CONFIG"'","runs":[' > "$SUMMARY_FILE"
FIRST_RUN=true

run_claude() {
    local task_file="$1"
    local task_id="$2"
    local use_mcp="$3"  # "yes" or "no"
    local config_name="claude-${use_mcp}mcp"
    local out_file="$OUTPUT_DIR/${task_id}_${config_name}.json"

    local prompt
    prompt=$(cat "$task_file")

    echo "  [$config_name] Running..."

    local start_ns
    start_ns=$(python3 -c "import time; print(int(time.time_ns()))")

    local claude_args=(
        -p "$prompt"
        --max-turns "$MAX_TURNS"
        --output-format json
    )

    if [ "$use_mcp" = "yes" ]; then
        # Only load codebase-memory-mcp (5 tools), no other MCP servers
        claude_args+=(--mcp-config "$MCP_CONFIG" --strict-mcp-config)
        # Allow MCP tools without interactive approval (they get permission-denied in -p mode otherwise)
        claude_args+=(--allowedTools "mcp__codebase-memory-mcp__context,mcp__codebase-memory-mcp__impact,mcp__codebase-memory-mcp__read_symbol,mcp__codebase-memory-mcp__query,mcp__codebase-memory-mcp__index")
        claude_args+=(--append-system-prompt "You have codebase-memory-mcp tools available (context, impact, read_symbol, query, index). Use them to explore and understand the codebase efficiently instead of grep/glob. Start with the context tool to find relevant code.")
    fi

    # Run Claude from qbapi directory (no -d flag in print mode)
    (cd "$QBAPI_DIR" && claude "${claude_args[@]}") > "$out_file" 2>/dev/null || true

    local end_ns
    end_ns=$(python3 -c "import time; print(int(time.time_ns()))")
    local elapsed_ms
    elapsed_ms=$(python3 -c "print(($end_ns - $start_ns) / 1_000_000)")

    # Extract metrics from JSON output
    local metrics
    metrics=$(python3 -c "
import json, sys
try:
    with open('$out_file') as f:
        data = json.load(f)
    usage = data.get('usage', {})
    # Include cache tokens in the total (cache reads are real input tokens)
    input_tokens = (usage.get('input_tokens', 0)
                    + usage.get('cache_read_input_tokens', 0)
                    + usage.get('cache_creation_input_tokens', 0))
    output_tokens = usage.get('output_tokens', 0)
    total_tokens = input_tokens + output_tokens
    num_turns = data.get('num_turns', 0)
    cost_usd = data.get('total_cost_usd', 0)
    result_text = data.get('result', '') or ''
    output_bytes = len(result_text.encode('utf-8'))
    print(json.dumps({
        'input_tokens': input_tokens,
        'output_tokens': output_tokens,
        'total_tokens': total_tokens,
        'num_turns': num_turns,
        'cost_usd': cost_usd,
        'output_bytes': output_bytes
    }))
except Exception as e:
    print(json.dumps({
        'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0,
        'num_turns': 0, 'cost_usd': 0, 'output_bytes': 0, 'error': str(e)
    }))
" 2>/dev/null)

    local total_tokens num_turns cost_usd output_bytes
    total_tokens=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_tokens'])")
    num_turns=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['num_turns'])")
    cost_usd=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['cost_usd'])")
    output_bytes=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['output_bytes'])")

    echo "    Time: ${elapsed_ms}ms | Tokens: $total_tokens | Turns: $num_turns | Cost: \$${cost_usd} | Output: ${output_bytes}B"

    # Append to summary
    if [ "$FIRST_RUN" = true ]; then
        FIRST_RUN=false
    else
        echo ',' >> "$SUMMARY_FILE"
    fi

    python3 -c "
import json
entry = {
    'id': '${task_id}__${config_name}',
    'tool': '$config_name',
    'description': '$task_id',
    'elapsed_ms': $elapsed_ms,
    'output_bytes': $output_bytes,
    'est_tokens': $total_tokens,
    'num_turns': $num_turns,
    'cost_usd': $cost_usd
}
print(json.dumps(entry, indent=2), end='')
" >> "$SUMMARY_FILE"
}

run_codex() {
    local task_file="$1"
    local task_id="$2"
    local use_mcp="$3"
    local config_name="codex-${use_mcp}mcp"
    local out_file="$OUTPUT_DIR/${task_id}_${config_name}.json"

    local prompt
    prompt=$(cat "$task_file")

    echo "  [$config_name] Running..."

    local start_ns
    start_ns=$(python3 -c "import time; print(int(time.time_ns()))")

    # Codex has codebase-memory-mcp configured globally via `codex mcp add`.
    if [ "$use_mcp" = "yes" ]; then
        prompt="Use codebase-memory-mcp tools (context, impact, read_symbol, query, index) to explore the codebase efficiently. Start with the context tool.

$prompt"
    fi

    local out_jsonl="$OUTPUT_DIR/${task_id}_${config_name}.jsonl"
    local answer_file="$OUTPUT_DIR/${task_id}_${config_name}_answer.txt"

    local codex_args=(
        exec "$prompt"
        -m gpt-5.4
        -c 'model_reasoning_effort="high"'
        --full-auto
        --cd "$QBAPI_DIR"
        --json
        --output-last-message "$answer_file"
    )

    if [ "$use_mcp" = "no" ]; then
        codex_args+=(-c "mcp_servers.codebase-memory-mcp.enabled=false")
    fi

    codex "${codex_args[@]}" > "$out_jsonl" 2>/dev/null || true

    local end_ns
    end_ns=$(python3 -c "import time; print(int(time.time_ns()))")
    local elapsed_ms
    elapsed_ms=$(python3 -c "print(($end_ns - $start_ns) / 1_000_000)")

    # Parse JSONL output for metrics
    local metrics
    metrics=$(python3 -c "
import json, os
try:
    input_tokens = 0
    output_tokens = 0
    tool_calls = 0
    num_turns = 0
    with open('$out_jsonl') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                ev = json.loads(line)
            except: continue
            # turn.completed has usage stats
            if ev.get('type') == 'turn.completed':
                num_turns += 1
                usage = ev.get('usage', {})
                input_tokens += usage.get('input_tokens', 0)
                input_tokens += usage.get('cached_input_tokens', 0)
                output_tokens += usage.get('output_tokens', 0)
            # Count tool calls from item.completed events
            if ev.get('type') == 'item.completed':
                item = ev.get('item', {})
                if item.get('type') in ('function_call', 'tool_call', 'mcp_tool_call'):
                    tool_calls += 1
    total_tokens = input_tokens + output_tokens
    # Read answer for output size
    output_bytes = 0
    if os.path.exists('$answer_file'):
        with open('$answer_file') as af:
            output_bytes = len(af.read().encode('utf-8'))
    # Fallback: estimate from JSONL size
    if total_tokens == 0:
        sz = os.path.getsize('$out_jsonl') if os.path.exists('$out_jsonl') else 0
        total_tokens = sz // 4
        if output_bytes == 0: output_bytes = sz
    print(json.dumps({
        'input_tokens': input_tokens, 'output_tokens': output_tokens,
        'total_tokens': total_tokens, 'tool_calls': tool_calls,
        'output_bytes': output_bytes
    }))
except Exception as e:
    print(json.dumps({
        'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0,
        'tool_calls': 0, 'output_bytes': 0, 'error': str(e)
    }))
" 2>/dev/null)

    local total_tokens tool_calls output_bytes
    total_tokens=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_tokens'])")
    tool_calls=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool_calls'])")
    output_bytes=$(echo "$metrics" | python3 -c "import json,sys; print(json.load(sys.stdin)['output_bytes'])")

    echo "    Time: ${elapsed_ms}ms | Tokens: $total_tokens | Tool calls: $tool_calls | Output: ${output_bytes}B"

    if [ "$FIRST_RUN" = true ]; then
        FIRST_RUN=false
    else
        echo ',' >> "$SUMMARY_FILE"
    fi

    python3 -c "
import json
entry = {
    'id': '${task_id}__${config_name}',
    'tool': '$config_name',
    'description': '$task_id',
    'elapsed_ms': $elapsed_ms,
    'output_bytes': $output_bytes,
    'est_tokens': $total_tokens,
    'tool_calls': $tool_calls
}
print(json.dumps(entry, indent=2), end='')
" >> "$SUMMARY_FILE"
}

for task_file in "${TASKS[@]}"; do
    task_id=$(basename "$task_file" .md)
    echo ""
    echo "=== Task: $task_id ==="

    case "$CONFIG" in
        all)
            run_claude "$task_file" "$task_id" "no"
            run_claude "$task_file" "$task_id" "yes"
            run_codex "$task_file" "$task_id" "no"
            run_codex "$task_file" "$task_id" "yes"
            ;;
        claude-nomcp)
            run_claude "$task_file" "$task_id" "no"
            ;;
        claude-mcp)
            run_claude "$task_file" "$task_id" "yes"
            ;;
        codex-nomcp)
            run_codex "$task_file" "$task_id" "no"
            ;;
        codex-mcp)
            run_codex "$task_file" "$task_id" "yes"
            ;;
        claude)
            run_claude "$task_file" "$task_id" "no"
            run_claude "$task_file" "$task_id" "yes"
            ;;
        codex)
            run_codex "$task_file" "$task_id" "no"
            run_codex "$task_file" "$task_id" "yes"
            ;;
        *)
            echo "Unknown config: $CONFIG"
            echo "Valid: all, claude, codex, claude-nomcp, claude-mcp, codex-nomcp, codex-mcp"
            exit 1
            ;;
    esac
done

echo ']}' >> "$SUMMARY_FILE"

echo ""
echo "=== Done ==="
echo "Results: $OUTPUT_DIR"
echo "Summary: $SUMMARY_FILE"

# Update benchmarks index
python3 -c "
import os, json, glob
idx = os.path.join('$SCRIPT_DIR', 'index.json')
runs = sorted([os.path.basename(os.path.dirname(p))
               for p in glob.glob(os.path.join('$SCRIPT_DIR', '*/summary.json'))])
with open(idx, 'w') as f:
    json.dump(runs, f)
print(f'Updated index.json: {runs}')
"

# Print summary table
python3 -c "
import json

with open('$SUMMARY_FILE') as f:
    data = json.load(f)

print()
print(f\"{'ID':<46} {'Time (s)':>10} {'Tokens':>10} {'Turns':>6} {'Cost':>8} {'Bytes':>8}\")
print('-' * 92)
for run in data['runs']:
    cost = run.get('cost_usd', 0) or 0
    print(f\"{run['id']:<46} {run['elapsed_ms']/1000:>10.1f} {run['est_tokens']:>10} {run.get('num_turns',0):>6} {'$'+f'{cost:.3f}':>8} {run['output_bytes']:>8}\")
"
