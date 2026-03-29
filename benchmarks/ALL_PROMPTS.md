# LLM Benchmark Test Prompts

These are the 5 task prompts used in the codebase-memory-mcp benchmark harness.
Run against the qbapi codebase to test code understanding with/without MCP tools.

---

## Task 1: Order Refund Flow

Find all code that handles order refunds in this codebase and explain the flow end-to-end. Include:
- Which controller methods handle refunds
- What database tables are involved
- How refund amounts are calculated
- What payment integrations are triggered
- Any edge cases (partial refunds, no-charge orders, multi-tender)

---

## Task 2: Blast Radius Analysis

What is the blast radius of changing the `convertToArray` function in `app/helpers.php`? Specifically:
- How many functions directly call it?
- What are the most critical callers?
- If I changed its return type from array to object, what would break?
- What tests would I need to run?
- Rate the risk: LOW / MEDIUM / HIGH / CRITICAL

---

## Task 3: Add New Payment Type

What files would I need to modify to add a new payment type called "BNPL" (Buy Now Pay Later) to this POS system? Walk through:
- Where payment types are defined/registered
- What controller methods handle payment processing
- What database tables store payment data
- What validation needs to change
- What reporting/settlement code needs updating

---

## Task 4: Debug Credit Settlement

There's a bug: credit settlement is double-counting amounts when `isNoCharge=1`. Find:
- The `creditSettlement` function and trace its logic
- Where `isNoCharge` is checked in the settlement flow
- Why double-counting might occur
- The fix, with the exact code change needed

---

## Task 5: Invoice Number Generation

Explain how invoice numbers are generated across fiscal years in this codebase:
- Which service handles invoice number generation?
- How does the fiscal year transition affect numbering?
- What happens to the sequence counter when a new fiscal year starts?
- What compliance requirements does the system enforce?
- What are the edge cases (midnight transitions, concurrent requests)?

---

## How to run manually

**Claude with MCP:**
```bash
cd /Users/naman/Documents/QBApps/qbapi
claude -p "<paste prompt>" --max-turns 15 --mcp-config '{"mcpServers":{"codebase-memory-mcp":{"command":"/Users/naman/Documents/QBApps/codebase-memory-mcp/build/c/codebase-memory-mcp","args":[]}}}'
```

**Claude without MCP:**
```bash
cd /Users/naman/Documents/QBApps/qbapi
claude -p "<paste prompt>" --max-turns 15
```

**Codex with MCP** (uses globally configured MCP):
```bash
cd /Users/naman/Documents/QBApps/qbapi
codex exec "<paste prompt>" -m gpt-5.4 -c 'model_reasoning_effort="high"' --full-auto
```

**Codex without MCP:**
```bash
cd /Users/naman/Documents/QBApps/qbapi
codex exec "<paste prompt>" -m gpt-5.4 -c 'model_reasoning_effort="high"' -c 'mcp_servers={}' --full-auto
```
