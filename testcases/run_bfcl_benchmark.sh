#!/bin/bash

# run_bfcl_benchmark.sh
# Kịch bản chạy bộ test BFCL (Javascript Subset) cho mini

MINI_BIN="./zig-out/bin/mini"
TEST_FILE="testcases/bfcl_javascript_subset.json"
REPORT_DIR="testcases/reports"
REPORT_FILE="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="$REPORT_DIR/summary_$(date +%Y%m%d_%H%M%S).json"

mkdir -p "$REPORT_DIR"

if [ ! -f "$MINI_BIN" ]; then
    echo "Không tìm thấy $MINI_BIN. Vui lòng build mini trước bằng 'zig build'."
    exit 1
fi

if [ ! -f "$TEST_FILE" ]; then
    echo "Không tìm thấy file dataset: $TEST_FILE"
    exit 1
fi

echo "==========================================="
echo "Bắt đầu chạy benchmark BFCL cho mini"
echo "Dataset: $TEST_FILE"
echo "Report: $REPORT_FILE"
echo "===========================================" | tee -a "$REPORT_FILE"

total=0
success=0
failed=0

# Xóa file summary cũ (nếu có) và khởi tạo mảng JSON
echo "[" > "$SUMMARY_FILE"
first_entry=true

# Đọc từng dòng (JSONL)
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
        continue
    fi

    # Phân tích cú pháp bằng jq
    test_id=$(echo "$line" | jq -r '.id')
    
    # BFCL v3 thường có cấu trúc question: [[{"role": "user", "content": "..."}]]
    question=$(echo "$line" | jq -r '.question[0][0].content')
    
    # Lấy schema của các tool
    tools_schema=$(echo "$line" | jq -c '.function')

    echo "▶ Đang chạy Test ID: $test_id" | tee -a "$REPORT_FILE"
    echo "  Prompt: $question" | tee -a "$REPORT_FILE"

    # Xây dựng câu lệnh yêu cầu LLM gọi tool dựa trên schema
    # (Vì đây là bài test gọi hàm, ta yêu cầu LLM trả về JSON gọi hàm)
    full_prompt="Bạn là một trợ lý thông minh. Dưới đây là các công cụ (tools) bạn có thể sử dụng (dạng JSON schema):
$tools_schema

Yêu cầu của người dùng:
\"$question\"

Hãy gọi công cụ phù hợp nhất và chỉ in ra kết quả dưới dạng JSON object mô tả việc gọi tool (không giải thích thêm). Ví dụ: {\"name\": \"tên_hàm\", \"arguments\": {\"param\": \"value\"}}"

    # Chạy mini (single-shot execution)
    start_time=$(date +%s%3N)
    output=$($MINI_BIN -e "$full_prompt" 2>&1)
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))

    echo "  Output: $output" | tee -a "$REPORT_FILE"
    echo "  Thời gian: ${duration}ms" | tee -a "$REPORT_FILE"
    echo "-------------------------------------------" | tee -a "$REPORT_FILE"

    # Trích xuất JSON sạch từ output
    # Loại bỏ mã màu ANSI và tìm dòng JSON (bắt đầu bằng { và kết thúc bằng })
    clean_json=$(echo "$output" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" | grep -E "^\{.*\}$" | head -n 1)
    
    # Nếu LLM không trả về JSON hợp lệ, fallback về mảng rỗng
    if [ -z "$clean_json" ]; then
        clean_json="{}"
    fi

    # Log kết quả ra file tổng hợp JSON
    if [ "$first_entry" = true ]; then
        first_entry=false
    else
        echo "," >> "$SUMMARY_FILE"
    fi
    
    # Lưu log cho từng case vào summary
    jq -n \
        --arg id "$test_id" \
        --arg q "$question" \
        --arg o "$output" \
        --argjson call "$clean_json" \
        --argjson time "$duration" \
        '{id: $id, question: $q, raw_output: $o, extracted_call: $call, duration_ms: $time}' >> "$SUMMARY_FILE"

    total=$((total + 1))

done < "$TEST_FILE"

echo "]" >> "$SUMMARY_FILE"

echo "===========================================" | tee -a "$REPORT_FILE"
echo "Hoàn thành benchmark!" | tee -a "$REPORT_FILE"
echo "Tổng số test: $total" | tee -a "$REPORT_FILE"
echo "Chi tiết xem tại:"
echo "  - $REPORT_FILE"
echo "  - $SUMMARY_FILE"
