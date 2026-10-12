#!/usr/bin/env bash
# run_tests_with_mock.sh — Test entire project with mock LLM server.
# Usage:
#   scripts/run_tests_with_mock.sh [port]                  -> Run All-In-One test suite via zig build test
#   scripts/run_tests_with_mock.sh --e2e-only <bin> <port> -> Run E2E mock layer only (for build.zig)
set -u
cd "$(dirname "$0")/.."

# ---------- Mode 1: Direct terminal run (All-In-One via zig build test) ----------
if [[ "${1:-}" != "--e2e-only" ]]; then
  # Ensure zig is in PATH if using zvm
  if ! command -v zig >/dev/null 2>&1; then
    for candidate in "$HOME/.zvm/0.16.0" "$HOME/.zvm/bin"; do
      if [[ -x "$candidate/zig" ]]; then
        export PATH="$candidate:$PATH"
        break
      fi
    done
  fi

  PORT="${1:-8399}"
  if [[ $# -gt 0 ]]; then shift; fi
  echo "=== [All-In-One] Running full test suite via zig build test ==="
  exec zig build test --summary all -Dtest-port="$PORT" "$@"
fi

# ---------- Mode 2: --e2e-only (run mock server and E2E testcases) ----------
shift # Drop --e2e-only flag
BIN="${1:-./zig-out/bin/mini}"
PORT="${2:-8399}"

if ! command -v node >/dev/null 2>&1; then
  echo "[E2E FAIL] 'node' not found in PATH to run mock server" >&2
  exit 1
fi

if [[ ! -x "$BIN" ]]; then
  echo "[E2E FAIL] binary '$BIN' does not exist or is not executable" >&2
  exit 1
fi

MOCK_URL="http://127.0.0.1:${PORT}/v1"
LOG="/tmp/mock_llm_${PORT}.log"
TEMP_HOME=$(mktemp -d /tmp/mini-test-home-XXXXXX)
MOCK_PID=""
PASS=0
FAIL=0

cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_HOME" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== [E2E] Starting mock LLM server :$PORT ==="
# Clean up stale process on port if present
fuser -k "${PORT}/tcp" 2>/dev/null || true
sleep 0.3
node scripts/mock_llm_server.js "$PORT" >"$LOG" 2>&1 &
MOCK_PID=$!

READY=0
for i in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/health"; then
    READY=1
    break
  fi
  sleep 0.1
done

if [[ $READY -ne 1 ]]; then
  echo "[E2E FAIL] Could not connect to mock LLM server on :$PORT after 3s" >&2
  cat "$LOG" >&2
  exit 1
fi

run_case() {
  local name="$1" prompt="$2" expect="$3"     # expect: string that must appear in output
  local out
  out=$(timeout 30 env MINI_HOME="$TEMP_HOME" \
        OPENAI_COMPAT_URL="$MOCK_URL" \
        OPENAI_COMPAT_MODEL="mock-model" \
        OPENAI_COMPAT_API_KEY="sk-mock" \
        OPENAI_PROTOCOL=chat \
        MINI_EXECUTION_MODE=auto \
        MINI_NO_HISTORY=1 \
        "$BIN" -e "$prompt" 2>&1)
  local rc=$?
  if [[ $rc -eq 124 ]]; then
    echo "  [FAIL] $name (TIMEOUT 30s — mini hanging/waiting on SSE)"; FAIL=$((FAIL+1)); return
  fi
  if echo "$out" | grep -F -q "$expect"; then
    echo "  [PASS] $name"; PASS=$((PASS+1))
  else
    echo "  [FAIL] $name (expected: '$expect')"; FAIL=$((FAIL+1))
    echo "$out" | head -10 | sed 's/^/         | /'
  fi
}

echo "=== [E2E] Running test cases (mock LLM) ==="
run_case "simple text response"   "Say hello"                 "Hello from mock LLM!"
run_case "long text streaming"    "read long text help me"    "AAAAAAAAAAAAAAAAAAAA"
run_case "tool call bash"         "please use bash to run echo" "mock-tool-ok"


run_act52_regression() {
  local out rc journal act_started_count=0
  local regression_home="$TEMP_HOME/rfc023-home"
  mkdir -p "$regression_home"
  out=$(timeout 30 env HOME="$regression_home" MINI_HOME="$TEMP_HOME" \
        OPENAI_COMPAT_URL="$MOCK_URL" \
        OPENAI_COMPAT_MODEL="mock-model" \
        OPENAI_COMPAT_API_KEY="sk-mock" \
        OPENAI_PROTOCOL=chat \
        MINI_EXECUTION_MODE=auto \
        MINI_NO_HISTORY=1 \
        "$BIN" -e "RFC023-ACT52-REGRESSION" 2>&1)
  rc=$?
  journal=$(find "$regression_home/.mini/sessions" -maxdepth 1 -type f -name 'journal_*.jsonl' 2>/dev/null | head -1)
  if [[ $rc -eq 1 && -n "$journal" ]] && grep -F -q '"event_type":"task_stalled"' "$journal"; then
    act_started_count=$(grep -c '"act_id":1,"event_type":"act_started"' "$journal" || true)
    if [[ "$act_started_count" -ge 3 ]] &&
       grep -F -q '"attempt":1' "$journal" &&
       grep -F -q '"attempt":2' "$journal" &&
       grep -F -q '"attempt":3' "$journal" &&
       grep -F -q '"recovery_class":"thinking_loop"' "$journal"; then
      echo "  [PASS] Act 52 recovery regression"
      PASS=$((PASS+1))
      return
    fi
  fi
  echo "  [FAIL] Act 52 recovery regression (rc=$rc, journal=$journal, act_started=$act_started_count)"
  FAIL=$((FAIL+1))
  echo "$out" | head -15 | sed 's/^/         | /'
  [[ -n "$journal" ]] && tail -n 12 "$journal" | sed 's/^/         | /'
}
run_act52_regression


# Issue #25 E2E: thinking-only response gets a nudge advisory, then caps at thinking_loop stall
run_thinking_only_nudge() {
  local out rc journal
  local regression_home="$TEMP_HOME/thinking-only-home"
  mkdir -p "$regression_home"
  out=$(timeout 60 env HOME="$regression_home" MINI_HOME="$TEMP_HOME" \
        OPENAI_COMPAT_URL="$MOCK_URL" \
        OPENAI_COMPAT_MODEL="mock-model" \
        OPENAI_COMPAT_API_KEY="sk-mock" \
        OPENAI_PROTOCOL=chat \
        MINI_EXECUTION_MODE=auto \
        MINI_NO_HISTORY=1 \
        "$BIN" -e "think-only task" 2>&1)
  rc=$?
  journal=$(find "$regression_home/.mini/sessions" -maxdepth 1 -type f -name 'journal_*.jsonl' 2>/dev/null | head -1)
  local act_started=0
  if [[ -n "$journal" ]] && grep -F -q '"event_type":"task_stalled"' "$journal" && \
     grep -F -q '"recovery_class":"thinking_loop"' "$journal"; then
    act_started=$(grep -c '"event_type":"act_started"' "$journal" || true)
    if [[ "$act_started" -ge 2 ]] && echo "$out" | grep -F -q "internal reasoning/thinking only"; then
      echo "  [PASS] issue #25: thinking-only nudge advisory + capped 2 acts -> thinking_loop stall"
      PASS=$((PASS+1))
      return
    fi
  fi
  echo "  [FAIL] issue #25: thinking-only nudge + cap regression (rc=$rc, journal=$journal, act_started=$act_started)"
  FAIL=$((FAIL+1))
  [[ -n "$journal" ]] && tail -n 15 "$journal" | sed 's/^/         | /'
  echo "$out" | head -15 | sed 's/^/         | /'
}
run_thinking_only_nudge


# Issue #24 E2E: usage + context_tokens recorded in act_completed delta
run_issue24_usage_delta() {
  local out rc journal
  local usage_home="$TEMP_HOME/usage-home"
  mkdir -p "$usage_home"
  out=$(timeout 60 env HOME="$usage_home" MINI_HOME="$TEMP_HOME" \
        OPENAI_COMPAT_URL="$MOCK_URL" \
        OPENAI_COMPAT_MODEL="mock-model" \
        OPENAI_COMPAT_API_KEY="sk-mock" \
        OPENAI_PROTOCOL=chat \
        MINI_EXECUTION_MODE=auto \
        MINI_NO_HISTORY=1 \
        "$BIN" -e "usage test" 2>&1)
  rc=$?
  journal=$(find "$usage_home/.mini/sessions" -maxdepth 1 -type f -name 'journal_*.jsonl' 2>/dev/null | head -1)
  if [[ -n "$journal" ]] && grep -F -q '"usage":' "$journal" && \
     grep -F -q '"reasoning_tokens"' "$journal"; then
    echo "  [PASS] issue #24: usage (input/output/reasoning_tokens) recorded in act_completed delta"
    PASS=$((PASS+1))
    return
  fi
  echo "  [FAIL] issue #24: usage not recorded in journal (rc=$rc, journal=$journal)"
  FAIL=$((FAIL+1))
  [[ -n "$journal" ]] && tail -n 12 "$journal" | sed 's/^/         | /'
  echo "$out" | head -15 | sed 's/^/         | /'
}
run_issue24_usage_delta

echo ""
# Media vision ingestion testcase
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89' > "$TEMP_HOME/test_img.png"
run_case "media vision ingestion" "@image:$TEMP_HOME/test_img.png Describe this" "[Vision Verified] Image received"

# Agnes AI video generation E2E testcase
echo "  Testing Agnes AI video generation..."
out_video=$(timeout 30 env MINI_HOME="$TEMP_HOME" \
      OPENAI_COMPAT_URL="$MOCK_URL" \
      OPENAI_COMPAT_MODEL="mock-model" \
      OPENAI_COMPAT_API_KEY="sk-mock-agnes" \
      OPENAI_PROTOCOL=chat \
      MINI_VIDEO_GEN_ENABLED=1 \
      MINI_VIDEO_GEN_PROVIDER=agnes \
      MINI_VIDEO_GEN_MODEL="agnes-video-2.5" \
      MINI_EXECUTION_MODE=auto \
      MINI_NO_HISTORY=1 \
      "$BIN" -e "please generate video" 2>&1)
if echo "$out_video" | grep -F -q "video/mp4"; then
  echo "  [PASS] agnes video generation"
  PASS=$((PASS+1))
else
  echo "  [FAIL] agnes video generation"
  echo "$out_video" | head -15 | sed 's/^/         | /'
  FAIL=$((FAIL+1))
fi

echo ""
echo "======================================"
echo "E2E RESULTS: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
