#!/usr/bin/env bash
# run_tests_with_mock.sh — Test toàn bộ project với mock LLM server.
# Usage:
#   scripts/run_tests_with_mock.sh [port]                 -> Chạy All-In-One test suite qua zig build test
#   scripts/run_tests_with_mock.sh --e2e-only <bin> <port> -> Chạy riêng tầng E2E mock (dành cho build.zig)
set -u
cd "$(dirname "$0")/.."

# ---------- Chế độ 1: Chạy trực tiếp từ terminal (All-In-One qua zig build test) ----------
if [[ "${1:-}" != "--e2e-only" ]]; then
  # Đảm bảo zig có trong PATH nếu dùng zvm
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
  echo "=== [All-In-One] Chạy toàn bộ test suite qua zig build test ==="
  exec zig build test --summary all -Dtest-port="$PORT" "$@"
fi

# ---------- Chế độ 2: --e2e-only (chạy mock server và E2E testcases) ----------
shift # Bỏ cờ --e2e-only
BIN="${1:-./zig-out/bin/mini}"
PORT="${2:-8399}"

if ! command -v node >/dev/null 2>&1; then
  echo "[E2E FAIL] 'node' không tìm thấy trong PATH để chạy mock server" >&2
  exit 1
fi

if [[ ! -x "$BIN" ]]; then
  echo "[E2E FAIL] binary '$BIN' không tồn tại hoặc không thể thực thi" >&2
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

echo "=== [E2E] Khởi động mock LLM server :$PORT ==="
# Dọn process cũ chiếm port (nếu có)
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
  echo "[E2E FAIL] Không thể kết nối mock LLM server trên :$PORT sau 3s" >&2
  cat "$LOG" >&2
  exit 1
fi

run_case() {
  local name="$1" prompt="$2" expect="$3"     # expect: chuỗi phải xuất hiện trong output
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
    echo "  [FAIL] $name (TIMEOUT 30s — mini treo/chờ SSE)"; FAIL=$((FAIL+1)); return
  fi
  if echo "$out" | grep -q "$expect"; then
    echo "  [PASS] $name"; PASS=$((PASS+1))
  else
    echo "  [FAIL] $name (mong đợi: '$expect')"; FAIL=$((FAIL+1))
    echo "$out" | head -10 | sed 's/^/         | /'
  fi
}

echo "=== [E2E] Chạy test cases (mock LLM) ==="
run_case "simple text response"   "Nói xin chào"                 "Xin chào từ mock LLM!"
run_case "long text streaming"    "đọc long text help me"        "AAAAAAAAAAAAAAAAAAAA"
run_case "tool call bash"         "hãy dùng bash chạy echo"      "mock-tool-ok"

echo ""
echo "======================================"
echo "KẾT QUẢ E2E: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
