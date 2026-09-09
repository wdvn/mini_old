#!/usr/bin/env bash
# run.sh — Arxiv Paper Aggregator Agent
#
# Usage:
#   ./run.sh
#   ./run.sh --max-results 30
#   ./run.sh --output /path/to/file.md
#
# Environment variables:
#   OPENAI_COMPAT_URL
#   MINI_BIN

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

# ─── Auto-detect OS + arch ────────────────────────────────────────────────────
_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
_arch="$(uname -m)"

case "$_arch" in
    x86_64|amd64)   _arch="amd64" ;;
    aarch64|arm64)  _arch="arm64" ;;
esac
case "$_os" in
    darwin) _os="darwin" ;;
    linux)  _os="linux" ;;
esac

PREBUILT_NAME="mini-${_os}-${_arch}"
PREBUILT_BIN="$PROJECT_ROOT/bin/$PREBUILT_NAME"

if [[ -n "${MINI_BIN:-}" ]]; then
    echo "[arxiv] Using binary: $MINI_BIN (from env)"
elif [[ -f "$PREBUILT_BIN" ]]; then
    MINI_BIN="$PREBUILT_BIN"
    echo "[arxiv] Using prebuilt: bin/$PREBUILT_NAME"
elif [[ -f "$PROJECT_ROOT/bin/mini" ]]; then
    MINI_BIN="$PROJECT_ROOT/bin/mini"
    echo "[arxiv] Using prebuilt: bin/mini"
elif [[ -f "$PROJECT_ROOT/zig-out/bin/mini" ]]; then
    MINI_BIN="$PROJECT_ROOT/zig-out/bin/mini"
    echo "[arxiv] Using local build: zig-out/bin/mini"
else
    echo "[arxiv] ⚠ No binary found for ${_os}/${_arch}"
    cd "$PROJECT_ROOT"
    ZIG="${HOME}/setup/zig/zig"
    [[ -x "$ZIG" ]] || ZIG="$(command -v zig)"
    "$ZIG" build -Doptimize=ReleaseSafe
    mkdir -p "$PROJECT_ROOT/bin"
    cp "zig-out/bin/mini" "$PROJECT_ROOT/bin/mini"
    MINI_BIN="$PROJECT_ROOT/bin/mini"
fi

for ENV_FILE in "$PROJECT_ROOT/.env" "$HOME/.mini/.env"; do
    if [[ -f "$ENV_FILE" ]]; then
        echo "[arxiv] Loading env: $ENV_FILE"
        set -a; source "$ENV_FILE"; set +a
        break
    fi
done

ARXIV_COUNT=20
OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-results) ARXIV_COUNT="$2"; shift 2 ;;
        --output)      OUTPUT_PATH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

DATE=$(date +%Y-%m-%d)
OUTPUT_PATH="${OUTPUT_PATH:-$SKILL_DIR/arxiv_${DATE}.md}"

TMP_PROMPT=$(mktemp)
cat << PROMPT > "$TMP_PROMPT"
Your goal today is to generate the latest Computer Science Research Digest from arXiv.

**Execution Configuration:**
- Maximum papers: ${ARXIV_COUNT}
- Output file path: ${OUTPUT_PATH}

**Tasks to perform:**
1. Get today's date and time.
2. From the arXiv API, fetch the latest ${ARXIV_COUNT} papers in Computer Science.
   URL: http://export.arxiv.org/api/query?search_query=cat:cs.AI+OR+cat:cs.LG+OR+cat:cs.CL+OR+cat:cs.CV&sortBy=submittedDate&sortOrder=descending&max_results=${ARXIV_COUNT}
3. Use Python to parse the XML and output JSON/Text for easier agent processing.
4. Select and analyze the abstract of each paper and summarize them clearly for software engineers.
5. Save the digest into the report file ${OUTPUT_PATH} using the file_write tool.
6. Finish with a brief completion message confirming file_write succeeded.
PROMPT

echo "=========================================="
echo "          ARXIV PAPER AGGREGATOR          "
echo "=========================================="
echo "[arxiv] Max results: $ARXIV_COUNT"
echo "[arxiv] Output path: $OUTPUT_PATH"
echo ""

export MINI_SYSTEM_FILE="$SKILL_DIR/system_prompt.md"
export MINI_NO_HISTORY=1

"$MINI_BIN" --single "$TMP_PROMPT"

STATUS=$?
echo ""
if [[ $STATUS -eq 0 ]]; then
    if [[ -f "$OUTPUT_PATH" ]]; then
        echo "[arxiv] ✓ Completed! Report file: $OUTPUT_PATH"
    else
        echo "[arxiv] ✓ Agent finished but output file not found."
    fi
else
    echo "[arxiv] ✗ An error occurred during execution (exit code $STATUS)." >&2
fi

rm -f "$TMP_PROMPT"
exit $STATUS

