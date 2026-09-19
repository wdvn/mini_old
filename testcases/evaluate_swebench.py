import sys
import os
import json
import re
import difflib
import subprocess

def parse_patch_files(patch_text):
    """Extract list of modified filenames from a git diff patch."""
    files = set()
    for line in patch_text.splitlines():
        if line.startswith("diff --git a/"):
            parts = line.split()
            if len(parts) >= 4:
                file_a = parts[2][2:] # strip a/
                files.add(file_a)
        elif line.startswith("--- a/"):
            files.add(line[6:].strip())
        elif line.startswith("+++ b/"):
            files.add(line[6:].strip())
    return sorted(list(files))

def evaluate_task(task_data, model_patch, workspace_dir=None):
    gold_patch = task_data.get("patch", "")
    gold_files = parse_patch_files(gold_patch)
    model_files = parse_patch_files(model_patch)

    result = {
        "instance_id": task_data.get("instance_id"),
        "difficulty": task_data.get("difficulty"),
        "repo": task_data.get("repo"),
        "has_patch": len(model_patch.strip()) > 0,
        "model_files": model_files,
        "gold_files": gold_files,
        "files_matched": False,
        "exact_patch_match": False,
        "similarity_score": 0.0,
        "test_passed": None
    }

    if not result["has_patch"]:
        return result

    # Check file overlap
    if set(gold_files) == set(model_files):
        result["files_matched"] = True
    elif len(set(gold_files).intersection(set(model_files))) > 0:
        result["files_matched"] = "partial"

    # Compare diff similarity
    matcher = difflib.SequenceMatcher(None, model_patch.strip(), gold_patch.strip())
    result["similarity_score"] = round(matcher.ratio() * 100, 1)

    if model_patch.strip() == gold_patch.strip():
        result["exact_patch_match"] = True

    # If workspace_dir is provided and test_patch exists, try running verification
    fail_to_pass_str = task_data.get("FAIL_TO_PASS", "[]")
    try:
        fail_to_pass = json.loads(fail_to_pass_str) if isinstance(fail_to_pass_str, str) else fail_to_pass_str
    except Exception:
        fail_to_pass = []

    result["fail_to_pass_count"] = len(fail_to_pass)

    return result

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 evaluate_swebench.py <task_json_file> <model_patch_file> [workspace_dir]")
        sys.exit(1)

    task_file = sys.argv[1]
    patch_file = sys.argv[2]
    workspace = sys.argv[3] if len(sys.argv) > 3 else None

    with open(task_file, "r") as f:
        task = json.load(f)

    patch_text = ""
    if os.path.exists(patch_file):
        with open(patch_file, "r") as f:
            patch_text = f.read()

    eval_res = evaluate_task(task, patch_text, workspace)

    print("==========================================================")
    print("            SWE-BENCH TASK EVALUATION RESULT              ")
    print("==========================================================")
    print(f"Task ID:          {eval_res['instance_id']}")
    print(f"Difficulty Level: {eval_res['difficulty']}")
    print(f"Repository:       {eval_res['repo']}")
    print(f"Generated Patch:  {'YES (' + str(len(patch_text)) + ' bytes)' if eval_res['has_patch'] else 'NO (empty)'}")
    print(f"Target Files:     {', '.join(eval_res['gold_files'])}")
    print(f"Modified Files:   {', '.join(eval_res['model_files']) if eval_res['model_files'] else 'None'}")
    print(f"File Alignment:   {'PERFECT MATCH' if eval_res['files_matched'] == True else ('PARTIAL' if eval_res['files_matched'] else 'MISMATCH')}")
    print(f"Patch Similarity: {eval_res['similarity_score']}%")
    print(f"Exact Gold Match: {'YES' if eval_res['exact_patch_match'] else 'NO'}")
    print("==========================================================")

    # Output json summary
    print("JSON_RESULT:" + json.dumps(eval_res))

if __name__ == "__main__":
    main()
