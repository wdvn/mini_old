#!/bin/bash

# run_bfcl_benchmark.sh
# BFCL Benchmark Runner Script (Javascript Subset) for mini

MINI_BIN="./zig-out/bin/mini"
TEST_FILE="testcases/bfcl_javascript_subset.json"
REPORT_DIR="testcases/reports"
REPORT_FILE="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="$REPORT_DIR/summary_$(date +%Y%m%d_%H%M%S).json"

mkdir -p "$REPORT_DIR"

if [ ! -f "$MINI_BIN" ]; then
    echo "$MINI_BIN not found. Please build mini first with 'zig build'."
    exit 1
fi

if [ ! -f "$TEST_FILE" ]; then
    echo "Dataset file not found: $TEST_FILE"
    exit 1
fi

echo "==========================================="
echo "Starting BFCL benchmark for mini"
echo "Dataset: $TEST_FILE"
echo "Report: $REPORT_FILE"
echo "===========================================" | tee -a "$REPORT_FILE"

total=0
success=0
failed=0

# Remove old summary file (if any) and initialize JSON array
echo "[" > "$SUMMARY_FILE"
first_entry=true

# Read line by line (JSONL)
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
        continue
    fi

    # Parse using jq
    test_id=$(echo "$line" | jq -r '.id')
    
    # BFCL v3 usually has question structure: [[{"role": "user", "content": "..."}]]
    question=$(echo "$line" | jq -r '.question[0][0].content')
    
    # Get tools schema
    tools_schema=$(echo "$line" | jq -c '.function')

    echo "▶ Running Test ID: $test_id" | tee -a "$REPORT_FILE"
    echo "  Prompt: $question" | tee -a "$REPORT_FILE"

    # Build prompt requesting LLM to call tool based on schema
    # (Since this is a function calling benchmark, we request LLM to return JSON function call)
    full_prompt="You are a helpful assistant. Below are the tools you can use (JSON schema):
$tools_schema

User request:
\"$question\"

Please call the most appropriate tool and output ONLY the result as a JSON object describing the tool call (no additional explanation). Example: {\"name\": \"function_name\", \"arguments\": {\"param\": \"value\"}}"

    # Run mini (single-shot execution)
    start_time=$(date +%s%3N)
    output=$($MINI_BIN -e "$full_prompt" 2>&1)
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))

    echo "  Output: $output" | tee -a "$REPORT_FILE"
    echo "  Duration: ${duration}ms" | tee -a "$REPORT_FILE"
    echo "-------------------------------------------" | tee -a "$REPORT_FILE"

    # Extract clean JSON from output
    # Strip ANSI escape sequences and find JSON line (starts with { and ends with })
    clean_json=$(echo "$output" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" | grep -E "^\{.*\}$" | head -n 1)
    
    # If LLM did not return valid JSON, fallback to empty object
    if [ -z "$clean_json" ]; then
        clean_json="{}"
    fi

    # Log result to summary JSON file
    if [ "$first_entry" = true ]; then
        first_entry=false
    else
        echo "," >> "$SUMMARY_FILE"
    fi
    
    # Save per-case log into summary
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
echo "Benchmark completed!" | tee -a "$REPORT_FILE"
echo "Total tests: $total" | tee -a "$REPORT_FILE"
echo "Details available at:"
echo "  - $REPORT_FILE"
echo "  - $SUMMARY_FILE"
