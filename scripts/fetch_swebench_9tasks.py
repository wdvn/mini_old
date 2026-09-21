import urllib.request
import json
import time
import sys

def main():
    levels = {"<15 min fix": [], "15 min - 1 hour": [], "1-4 hours": []}
    seen_repos = {"<15 min fix": set(), "15 min - 1 hour": set(), "1-4 hours": set()}

    offset = 0
    while True:
        url = f"https://datasets-server.huggingface.co/rows?dataset=princeton-nlp%2FSWE-bench_Verified&config=default&split=test&offset={offset}&limit=50"
        print(f"Fetching offset {offset}...")
        try:
            req = urllib.request.urlopen(url)
            data = json.loads(req.read().decode("utf-8"))
        except Exception as e:
            print(f"Error fetching offset {offset}: {e}")
            break

        rows = data.get("rows", [])
        if not rows:
            break

        for row in rows:
            r = row["row"]
            diff = r.get("difficulty")
            repo = r.get("repo")
            if diff in levels and len(levels[diff]) < 3 and repo not in seen_repos[diff]:
                seen_repos[diff].add(repo)
                levels[diff].append(r)
                iid = r["instance_id"]
                print(f"  [+] Added Level [{diff}] ({repo}): {iid}")

        if all(len(v) >= 3 for v in levels.values()):
            print("All 3 levels filled with 3 tasks each!")
            break

        offset += 50
        time.sleep(0.1)

    subset = []
    for diff, items in levels.items():
        subset.extend(items[:3])

    with open("testcases/swebench_verified_subset.json", "w") as f:
        json.dump(subset, f, indent=2)

    print(f"Successfully saved {len(subset)} tasks to testcases/swebench_verified_subset.json")

if __name__ == "__main__":
    main()
