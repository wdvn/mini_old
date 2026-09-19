#!/bin/bash
set -e

# run_arc_benchmark.sh
# Automated ARC-AGI Benchmark Runner for mini-agent

MINI_BIN="./zig-out/bin/mini"
REPORT_DIR="testcases/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$REPORT_DIR/arc_report_$TIMESTAMP.log"
SUMMARY_FILE="$REPORT_DIR/arc_summary_$TIMESTAMP.json"

mkdir -p "$REPORT_DIR"

if [ ! -f "$MINI_BIN" ]; then
    echo "Building mini binary..."
    zig build
fi

TARGET_TASK="$1"
if [ -n "$TARGET_TASK" ] && [ -f "$TARGET_TASK" ]; then
    TASK_FILES=("$TARGET_TASK")
else
    TASK_FILES=(testcases/arc_*.json)
fi

echo "=========================================================="
echo " Starting ARC-AGI Benchmark for mini"
echo " Tasks count: ${#TASK_FILES[@]}"
echo " Output Log:  $REPORT_FILE"
echo " Summary:     $SUMMARY_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

echo "[" > "$SUMMARY_FILE"
first_entry=true

for task_file in "${TASK_FILES[@]}"; do
    if [ ! -f "$task_file" ]; then
        continue
    fi

    task_id=$(basename "$task_file" .json)
    echo "▶ Evaluating ARC Task: $task_id ($task_file)" | tee -a "$REPORT_FILE"

    train_data=$(jq -c '.train' "$task_file")
    test_input=$(jq -c '.test[0].input' "$task_file")
    ground_truth=$(jq -c '.test[0].output' "$task_file")

    prompt="You are an expert AI agent solving an ARC-AGI (Abstraction and Reasoning Corpus) visual reasoning puzzle.

Task Data:
Training Examples (input and output pairs):
$train_data

Test Input:
$test_input

Instructions:
1. Analyze the transformation rule mapping input grids to output grids in the training examples.
2. Verify your rule mentally or via CodeAct against each training example.
3. Apply the verified transformation rule to the Test Input grid.
4. Output the final predicted 2D array inside a \`\`\`json\n[[...]]\n\`\`\` code block."

    start_time=$(date +%s%3N)
    raw_output=$($MINI_BIN -e "$prompt" 2>&1 || true)
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))

    echo "$raw_output" >> "$REPORT_FILE"
    echo "  Execution duration: ${duration}ms" | tee -a "$REPORT_FILE"

    # Extract the last valid 2D JSON array from the output
    extracted_grid=$(node -e "
        const fs = require('fs');
        const text = process.argv[1];
        // Strip ANSI codes and box drawing characters
        const clean = text.replace(/\u001b\[[0-9;]*[a-zA-Z]/g, '').replace(/[│┌┐└┘├┤┬┴┼╭╮╯╰─]/g, '');
        // Match 2D JSON array [[...]]
        const matches = clean.match(/\[\s*\[[\s\S]*?\]\s*\]/g);
        if (matches && matches.length > 0) {
            for (let i = matches.length - 1; i >= 0; i--) {
                try {
                    const parsed = JSON.parse(matches[i]);
                    if (Array.isArray(parsed) && Array.isArray(parsed[0])) {
                        console.log(JSON.stringify(parsed));
                        process.exit(0);
                    }
                } catch (e) {}
            }
        }
        console.log('null');
    " "$raw_output")

    if [ "$first_entry" = true ]; then
        first_entry=false
    else
        echo "," >> "$SUMMARY_FILE"
    fi

    jq -n \
        --arg tid "$task_id" \
        --argjson pred "$extracted_grid" \
        --argjson truth "$ground_truth" \
        --argjson dur "$duration" \
        '{task_id: $tid, predicted_grid: $pred, ground_truth: $truth, duration_ms: $dur}' >> "$SUMMARY_FILE"

done

echo "]" >> "$SUMMARY_FILE"

echo "==========================================================" | tee -a "$REPORT_FILE"
echo "Running evaluation..."
node testcases/evaluate_arc.js "$SUMMARY_FILE" | tee -a "$REPORT_FILE"
