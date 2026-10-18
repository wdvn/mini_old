# Testing Suite, Benchmarks & Verification Guide

## 1. Multi-Tier All-In-One Test Suite

`mini-agent` features an automated, multi-tiered test suite that validates unit logic, security sandboxing, and end-to-end model interactions in a single command.

```
                          ┌────────────────────────────┐
                          │   zig build test           │
                          │   (All-In-One Test Suite)  │
                          └─────────────┬──────────────┘
                                        │
           ┌────────────────────────────┼────────────────────────────┐
           ▼                            ▼                            ▼
┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────────┐
│  Tier 1: Unit Tests  │    │ Tier 2: Integration  │    │  Tier 3: Mock LLM    │
│  (src/main.zig)      │    │ (Security & VM)      │    │  (scripts/mock_...js)│
├──────────────────────┤    ├──────────────────────┤    ├──────────────────────┤
│ - Core agent loop    │    │ - Per-Act isolation  │    │ - Simple text flow   │
│ - JSON & ANSI parser │    │ - Allow/block policy │    │ - SSE stream flow    │
│ - CSR Graph engine   │    │ - CAS rollback       │    │ - Multi-turn tool    │
│ - Protocol & types   │    │ - Memory leak audit  │    │   calling flow       │
└──────────────────────┘    └──────────────────────┘    └──────────────────────┘
```

---

## 2. Test Execution Commands

| Target Command | Description | Node.js Required? |
|---|---|---|
| `zig build test --summary all` | Runs complete 3-tier suite (all 21 build steps, 544+ tests). Pre-commit standard. | Yes |
| `zig build test-unit` | Runs Tier 1 (Unit) and Tier 2 (Security/VM integration) tests only. Fast local iteration. | No |
| `zig build test -Dskip-e2e=true` | Equivalent to `test-unit`. Skips external server dependencies. | No |
| `zig build test-e2e` | Runs only Tier 3 E2E mock server tests against compiled `mini` binary. | Yes |
| `zig build test -Dtest-port=8400` | Overrides the default mock server port (8399) in case of port collisions. | Yes |

---

## 3. Test Tier Specifications

### 3.1. Tier 1: Unit Tests
Direct unit tests compiled across all submodules from `src/main.zig`:
- **Core Engine**: Configuration loading, environment resolution, and history management.
- **Protocol**: Message serialization, tool use schemas, and token chunk decoders.
- **Algorithms**: CSR graph compilation, DFS cycle detection, BFS neighborhood traversal, and BM25 ranking.
- **UI**: UTF-8 line editor arithmetic, bracketed paste state machine, and streaming markdown lexer.

### 3.2. Tier 2: Security & VM Integration Tests (`testcases/test_codeact_security.zig`)
Validates system security invariants under simulated adversarial conditions:
- **Per-Act VM Isolation**: Verifies that variables declared in Act 1 (`const x = 10;`) do not contaminate Act 2, and that syntax collisions raise clean errors rather than process aborts.
- **Policy Enforcement**: Asserts that tools excluded by `MINI_TOOL_ALLOWLIST` or listed in `MINI_TOOL_BLOCKLIST` fail with a `TypeError` when called via `mini.*` in JavaScript.
- **CAS Rollback**: Modifies files, simulates a failure, and verifies exact restoration from the Content-Addressed Storage snapshot.
- **Memory Leak Audit**: Evaluates teardown sequences with `std.heap.Check.ok` to ensure zero memory leaks upon process exit.

### 3.3. Tier 3: End-to-End Mock LLM Suite
Spawns an independent Node.js server (`scripts/mock_llm_server.js`) on port 8399 that mimics OpenAI SSE responses, then tests the compiled `mini` binary against three core workflows:
1. **Simple Text**: Validates request formulation, single-turn completion, and exit code.
2. **Streaming Text**: Verifies token-by-token SSE assembly, markdown formatting, and thinking block parsing.
3. **Multi-Turn Bash Calling**: Simulates a model executing shell commands, feeding stdout observations back to the mock server, and continuing until `stop_reason: "end_turn"`.

---

## 4. Benchmark Suites

`mini-agent` includes dedicated benchmark harnesses in `testcases/` to measure real-world coding performance and engine scalability.

### 4.1. SWE-bench Verified Subset
Evaluates the agent on real GitHub issues from open-source repositories:
- **Dataset**: `testcases/swebench_verified_subset.json`
- **Harness**: `testcases/run_swebench_benchmark.sh` and `testcases/evaluate_swebench.py`
- Measures pass rate, patch generation validity, and turn count.

### 4.2. Berkeley Function Calling Leaderboard (BFCL)
Evaluates tool calling accuracy in the JavaScript CodeAct environment:
- **Dataset**: `testcases/bfcl_javascript_subset.json`
- **Harness**: `testcases/run_bfcl_benchmark.sh` and `testcases/evaluate.js`
- Asserts correct parameter types, error handling, and multi-tool composition.

### 4.3. ARC (Abstraction & Reasoning Corpus)
Tests multi-step reasoning capabilities on visual and spatial matrices:
- **Harness**: `testcases/run_arc_benchmark.sh` and `testcases/evaluate_arc.js`
- Datasets: `testcases/arc_007bbfb7.json`, `testcases/arc_00d62c1b.json`, `testcases/arc_1e0a9b12.json`.

### 4.4. Plan Scaling Sweep Benchmark (`testcases/test_plan_rfc024_bench.zig`)
Benchmarks internal engine throughput under extreme scale:
- Evaluates plan DAG parsing and JSON serialization scaling from 50 to 1,000 steps.
- Validates that graph traversal and dependency resolution remain sub-millisecond.

---

## 5. Release & Cross-Compilation

To build optimized release binaries for distribution:

```bash
# Optimized Linux build
zig build -Doptimize=ReleaseSafe

# Cross-compile for Linux ARM64
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

# Multi-platform packaging script
./scripts/build_release.sh
```

Packaged archives are written to `releases/` containing the compiled binary, standard skills library, and setup scripts.
