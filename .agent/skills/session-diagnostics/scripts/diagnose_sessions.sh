#!/usr/bin/env bash
# diagnose_sessions.sh — Quick diagnostic inspection of recent mini-agent sessions

SESSION_DIR="${HOME}/.mini/sessions"

if [ ! -d "$SESSION_DIR" ]; then
    echo "[!] Sessions directory does not exist: $SESSION_DIR"
    exit 0
fi

echo "========================================================"
echo "          MINI-AGENT SESSION DIAGNOSTIC REPORT          "
echo "========================================================"
echo "Directory: $SESSION_DIR"
echo ""

# 1. Top 5 latest session files
echo "--- [1. Top 5 latest journal files] ---"
ls -lh -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 5
echo ""

# 2. Latest session inspection
LATEST_JOURNAL=$(ls -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 1)
if [ -n "$LATEST_JOURNAL" ]; then
    echo "--- [2. Latest Session Status: $(basename "$LATEST_JOURNAL")] ---"
    TOTAL_LINES=$(wc -l < "$LATEST_JOURNAL")
    echo "Total recorded events: $TOTAL_LINES"
    echo "Last 5 events:"
    tail -n 5 "$LATEST_JOURNAL"
    echo ""
fi

# 3. Scan for recent errors
echo "--- [3. Errors recorded across the 10 most recent sessions] ---"
RECENT_FILES=$(ls -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 10)
if [ -n "$RECENT_FILES" ]; then
    ERR_COUNT=0
    for f in $RECENT_FILES; do
        ERRORS=$(grep -v '"error_detail":null' "$f" 2>/dev/null)
        if [ -n "$ERRORS" ]; then
            echo "[ERRORS IN $(basename "$f")]:"
            echo "$ERRORS"
            ERR_COUNT=$((ERR_COUNT + 1))
        fi
    done
    if [ "$ERR_COUNT" -eq 0 ]; then
        echo "✓ No backend/terminal errors detected in the 10 most recent sessions."
    fi
else
    echo "No journal files found."
fi

echo ""
echo "========================================================"
echo "Diagnostic complete."
