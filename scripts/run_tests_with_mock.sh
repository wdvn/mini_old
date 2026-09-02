#!/usr/bin/env bash
# run_tests_with_mock.sh — Test toàn bộ project với mock LLM server.
# Usage: scripts/run_tests_with_mock.sh [port]
#   1. Unit tests:        zig build test --summary all
#   2. Build binary:      zig build
#   3. E2E với mock LLM:  chạy ./zig-out/bin/mini-agent -e "<prompt>" trỏ vào mock server,
#                         so khớp output với expectation từng case.
set -u
cd "$(dirname "$0")/.."

PORT="${1:-8399}"
MOCK_URL="http://127.0.0.1:${PORT}/v1"
LOG=/tmp/mock_llm_${PORT}.log
BIN=./zig-out/bin/mini
PASS=0; FAIL=0

# ---------- Bước 0: binary ----------
if [[ ! -x "$BIN" ]]; then
  echo "[runner] binary chưa có, build..."
  zig build || { echo "FATAL: zig build thất bại"; exit 1; }
fi

# ---------- Bước 1: unit tests ----------
echo "=== [1/3] zig build test --summary all ==="
if zig build test --summary all; then
  echo "[runner] Unit tests: PASS"; PASS=$((PASS+1))
else
  echo "[runner] Unit tests: FAIL"; FAIL=$((FAIL+1))
fi

# ---------- Bước 2: mock server ----------
echo "=== [2/3] Khởi động mock LLM server :$PORT ==="
# Dọn process cũ chiếm port (nguyên nhân treo/kẹt mock cũ)
fuser -k "${PORT}/tcp" 2>/dev/null; sleep 0.3
node scripts/mock_llm_server.js "$PORT" >"$LOG" 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT
for i in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break
  sleep 0.1
done

run_case() {
  local name="$1" prompt="$2" expect="$3"     # expect: chuỗi phải xuất hiện trong output
  local out
  out=$(timeout 30 env MINI_HOME=/tmp/mini-test-home \
        OPENAI_COMPAT_URL="$MOCK_URL" \
        OPENAI_COMPAT_MODEL="mock-model" \
        OPENAI_COMPAT_API_KEY="sk-mock" \
        OPENAI_PROTOCOL=chat \
        MINI_EXECUTION_MODE=auto \
        MINI_NO_HISTORY=1 \
        "$BIN" -e "$prompt" 2>&1)
  local rc=$?
  if [[ $rc -eq 124 ]]; then
    echo "  [FAIL] $name (TIMEOUT 30s — mini treo/chờ SSE)"; FAIL=$((FAIL+1)); return
  fi
  if echo "$out" | grep -q "$expect"; then
    echo "  [PASS] $name"; PASS=$((PASS+1))
  else
    echo "  [FAIL] $name (mong đợi: '$expect')"; FAIL=$((FAIL+1))
    echo "$out" | head -10 | sed 's/^/         | /'
  fi
}

echo "=== [3/3] E2E cases (mock LLM) ==="
run_case "simple text response"   "Nói xin chào"                 "Xin chào từ mock LLM!"
run_case "long text streaming"    "đọc long text help me"        "AAAAAAAAAAAAAAAAAAAA"
run_case "tool call bash"         "hãy dùng bash chạy echo"      "mock-tool-ok"

echo ""
echo "======================================"
echo "KẾT QUẢ: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
