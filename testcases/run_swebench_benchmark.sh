#!/bin/bash
set -e

# run_swebench_benchmark.sh
# Automated SWE-bench Verified Benchmark Runner for mini-agent

ROOT_DIR="$(pwd)"
MINI_BIN="$ROOT_DIR/zig-out/bin/mini"
SUBSET_FILE="$ROOT_DIR/testcases/swebench_verified_subset.json"
CACHE_DIR="/tmp/swebench_cache"
RUNS_DIR="/tmp/swebench_runs"
REPORT_DIR="$ROOT_DIR/testcases/reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$REPORT_DIR/swebench_report_$TIMESTAMP.log"
SUMMARY_FILE="$REPORT_DIR/swebench_summary_$TIMESTAMP.json"

mkdir -p "$CACHE_DIR" "$RUNS_DIR" "$REPORT_DIR"

if [ ! -f "$MINI_BIN" ]; then
    echo "Building mini binary..."
    zig build
fi

if [ ! -f "$SUBSET_FILE" ]; then
    echo "Subset file $SUBSET_FILE not found. Fetching..."
    python3 "$ROOT_DIR/scripts/fetch_swebench_9tasks.py"
fi

TARGET_ARG="${1:-1}"

# Determine which tasks to run:
# Can be index 1..9, or task instance_id, or "all", or difficulty ("easy", "medium", "hard")
TASKS_JSON=$(python3 -c "
import json, sys

arg = '$TARGET_ARG'
with open('$SUBSET_FILE') as f:
    tasks = json.load(f)

selected = []
if arg == 'all':
    selected = tasks
elif arg == 'easy':
    selected = [t for t in tasks if t.get('difficulty') == '<15 min fix']
elif arg == 'medium':
    selected = [t for t in tasks if t.get('difficulty') == '15 min - 1 hour']
elif arg == 'hard':
    selected = [t for t in tasks if t.get('difficulty') == '1-4 hours']
elif arg.isdigit():
    idx = int(arg) - 1
    if 0 <= idx < len(tasks):
        selected = [tasks[idx]]
else:
    selected = [t for t in tasks if t.get('instance_id') == arg]

if not selected:
    print('[]')
else:
    print(json.dumps(selected))
")

TASK_COUNT=$(echo "$TASKS_JSON" | jq 'length')
if [ "$TASK_COUNT" -eq 0 ]; then
    echo "No matching tasks found for '$TARGET_ARG'."
    exit 1
fi

echo "=========================================================="
echo " Starting SWE-bench Benchmark for mini-agent"
echo " Tasks to execute: $TASK_COUNT"
echo " Report Log:       $REPORT_FILE"
echo " Summary Output:   $SUMMARY_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"

echo "[" > "$SUMMARY_FILE"
first_entry=true

for i in $(seq 0 $((TASK_COUNT - 1))); do
    task_json=$(echo "$TASKS_JSON" | jq -c ".[$i]")
    iid=$(echo "$task_json" | jq -r '.instance_id')
    repo=$(echo "$task_json" | jq -r '.repo')
    base_commit=$(echo "$task_json" | jq -r '.base_commit')
    diff_lvl=$(echo "$task_json" | jq -r '.difficulty')
    problem_statement=$(echo "$task_json" | jq -r '.problem_statement')

    echo "" | tee -a "$REPORT_FILE"
    echo "▶ [Task $((i + 1))/$TASK_COUNT] Instance: $iid" | tee -a "$REPORT_FILE"
    echo "  Difficulty: $diff_lvl | Repo: $repo | Commit: ${base_commit:0:10}" | tee -a "$REPORT_FILE"

    # Cache tarball
    repo_slug=$(echo "$repo" | tr '/' '_')
    tarball="$CACHE_DIR/${repo_slug}_${base_commit}.tar.gz"
    if [ ! -f "$tarball" ]; then
        echo "  Downloading repository archive from GitHub..." | tee -a "$REPORT_FILE"
        curl -sL "https://codeload.github.com/$repo/tar.gz/$base_commit" -o "$tarball"
    fi

    # Prepare isolated run directory
    task_dir="$RUNS_DIR/$iid"
    rm -rf "$task_dir"
    mkdir -p "$task_dir"
    echo "  Extracting codebase..." | tee -a "$REPORT_FILE"
    tar -xzf "$tarball" -C "$task_dir" --strip-components=1

    # Initialize git repo in working tree
    cd "$task_dir"
    git init -q
    git config user.name "mini"
    git config user.email "mini@agent.ai"
    git add -A
    git commit -q -m "base commit"
    cd - > /dev/null

    # Save task JSON for evaluator
    task_file_tmp="$task_dir/.swebench_task.json"
    echo "$task_json" > "$task_file_tmp"

    # Build prompt for mini
    prompt="You are an expert software engineer resolving a GitHub issue in the repository '$repo'.

The current directory is the root of the repository.

Issue Description:
$problem_statement

Instructions:
1. Use bash commands (e.g. grep -n, cat, sed, python3) to locate, inspect, and understand where the issue occurs in the codebase.
2. Use bash or file_edit to make the minimal, precise fix required to solve the issue.
3. Verify your fix using python3 in bash if appropriate.
4. Ensure code style and conventions are maintained.
5. Conclude your turn with a brief summary of the fix once completed."

    echo "  Executing mini on task (timeout: 300s)..." | tee -a "$REPORT_FILE"
    start_time=$(date +%s%3N)
    
    # Run mini inside the target workspace directory with hard 300s timeout against infinite loops
    # grep, file_read, file_write are temporarily blocked to force model to use bash
    (cd "$task_dir" && MINI_TOOL_BLOCKLIST="grep,file_read,file_write,read_file,write_file,read,write" timeout --kill-after=10s 300s "$MINI_BIN" -e "$prompt" >> "$REPORT_FILE" 2>&1 || true)
    
    end_time=$(date +%s%3N)
    duration=$((end_time - start_time))
    echo "  Execution finished in ${duration}ms" | tee -a "$REPORT_FILE"

    # Extract git patch
    patch_file="$task_dir/mini.patch"
    (cd "$task_dir" && git diff > "$patch_file")

    patch_size=$(wc -c < "$patch_file" 2>/dev/null || echo 0)
    echo "  Generated patch size: $patch_size bytes" | tee -a "$REPORT_FILE"

    # Evaluate
    eval_output=$(python3 "$ROOT_DIR/testcases/evaluate_swebench.py" "$task_file_tmp" "$patch_file" "$task_dir" | tee -a "$REPORT_FILE")
    json_res=$(echo "$eval_output" | grep "^JSON_RESULT:" | sed "s/^JSON_RESULT://")

    if [ -z "$json_res" ]; then
        json_res="{\"instance_id\": \"$iid\", \"error\": \"evaluation failed\"}"
    fi

    # Append duration
    json_with_dur=$(echo "$json_res" | jq --argjson dur "$duration" '. + {duration_ms: $dur}')

    if [ "$first_entry" = true ]; then
        first_entry=false
    else
        echo "," >> "$SUMMARY_FILE"
    fi
    echo "$json_with_dur" >> "$SUMMARY_FILE"

done

echo "]" >> "$SUMMARY_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"
echo "           SWE-BENCH BENCHMARK SUITE FINISHED             " | tee -a "$REPORT_FILE"
echo " Summary file: $SUMMARY_FILE" | tee -a "$REPORT_FILE"
echo " Detailed log: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "==========================================================" | tee -a "$REPORT_FILE"
