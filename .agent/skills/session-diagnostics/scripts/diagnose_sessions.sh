#!/usr/bin/env bash
# diagnose_sessions.sh — Chẩn đoán nhanh các session gần nhất của mini-agent

SESSION_DIR="${HOME}/.mini/sessions"

if [ ! -d "$SESSION_DIR" ]; then
    echo "[!] Thư mục sessions không tồn tại: $SESSION_DIR"
    exit 0
fi

echo "========================================================"
echo "          MINI-AGENT SESSION DIAGNOSTIC REPORT          "
echo "========================================================"
echo "Thư mục: $SESSION_DIR"
echo ""

# 1. Top 5 latest session files
echo "--- [1. Top 5 file journal mới nhất] ---"
ls -lh -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 5
echo ""

# 2. Latest session inspection
LATEST_JOURNAL=$(ls -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 1)
if [ -n "$LATEST_JOURNAL" ]; then
    echo "--- [2. Trạng thái Session gần nhất: $(basename "$LATEST_JOURNAL")] ---"
    TOTAL_LINES=$(wc -l < "$LATEST_JOURNAL")
    echo "Tổng số sự kiện ghi nhận: $TOTAL_LINES"
    echo "5 sự kiện cuối cùng:"
    tail -n 5 "$LATEST_JOURNAL"
    echo ""
fi

# 3. Scan for recent errors
echo "--- [3. Các lỗi ghi nhận trong 10 session gần nhất] ---"
RECENT_FILES=$(ls -t "$SESSION_DIR"/journal_*.jsonl 2>/dev/null | head -n 10)
if [ -n "$RECENT_FILES" ]; then
    ERR_COUNT=0
    for f in $RECENT_FILES; do
        ERRORS=$(grep -v '"error_detail":null' "$f" 2>/dev/null)
        if [ -n "$ERRORS" ]; then
            echo "[LỖI TẠI $(basename "$f")]:"
            echo "$ERRORS"
            ERR_COUNT=$((ERR_COUNT + 1))
        fi
    done
    if [ "$ERR_COUNT" -eq 0 ]; then
        echo "✓ Không phát hiện lỗi backend/terminal nào trong 10 session gần nhất."
    fi
else
    echo "Không tìm thấy file journal."
fi

echo ""
echo "========================================================"
echo "Hoàn thành chẩn đoán."
