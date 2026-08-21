#!/usr/bin/env python3
import json
import subprocess
import sys
import os

def run_test():
    exe = os.path.abspath("./zig-out/bin/mini")
    if not os.path.exists(exe):
        print(f"Error: binary {exe} not found. Run zig build first.")
        sys.exit(1)

    p = subprocess.Popen(
        [exe, "--acp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1
    )

    def send_line(obj):
        line = json.dumps(obj) + "\n"
        p.stdin.write(line)
        p.stdin.flush()

    def read_line():
        line = p.stdout.readline()
        if not line:
            return None
        return json.loads(line.strip())

    print("[TEST] 1. Sending initialize request...")
    send_line({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": True}},
            "clientInfo": {"name": "zed", "version": "0.1.0"}
        }
    })
    resp1 = read_line()
    print("[RESP 1]:", resp1)
    assert resp1["id"] == 1, f"Expected id 1, got {resp1}"
    assert resp1["result"]["protocolVersion"] == 1
    assert resp1["result"]["agentInfo"]["name"] == "mini-agent"

    print("[TEST] 2. Sending notifications/initialized...")
    send_line({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    })

    print("[TEST] 3. Sending session/new...")
    send_line({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "session/new",
        "params": {
            "cwd": "/tmp",
            "mcpServers": []
        }
    })
    resp2 = read_line()
    print("[RESP 2]:", resp2)
    assert resp2["id"] == 2
    assert "sessionId" in resp2["result"]
    session_id = resp2["result"]["sessionId"]

    print("[TEST] 4. Sending ping...")
    send_line({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "ping"
    })
    resp3 = read_line()
    print("[RESP 3]:", resp3)
    assert resp3["id"] == 3

    print("[TEST] 5. Sending session/load...")
    send_line({
        "jsonrpc": "2.0",
        "id": 4,
        "method": "session/load",
        "params": {
            "sessionId": session_id
        }
    })
    resp4 = read_line()
    print("[RESP 4]:", resp4)
    assert resp4["id"] == 4

    print("[TEST] 6. Sending session/cancel...")
    send_line({
        "jsonrpc": "2.0",
        "id": 5,
        "method": "session/cancel",
        "params": {
            "sessionId": session_id
        }
    })
    resp5 = read_line()
    print("[RESP 5]:", resp5)
    assert resp5["id"] == 5

    print("[TEST] 7. Sending unknown method (expect error -32601)...")
    send_line({
        "jsonrpc": "2.0",
        "id": 6,
        "method": "unknown_test_method"
    })
    resp6 = read_line()
    print("[RESP 6]:", resp6)
    assert resp6["id"] == 6
    assert "error" in resp6
    assert resp6["error"]["code"] == -32601

    print("[TEST] 8. Sending session/close...")
    send_line({
        "jsonrpc": "2.0",
        "id": 7,
        "method": "session/close",
        "params": {
            "sessionId": session_id
        }
    })
    resp7 = read_line()
    print("[RESP 7]:", resp7)
    assert resp7["id"] == 7

    p.stdin.close()
    p.wait(timeout=5)
    print("\n[SUCCESS] ACP Protocol integration tests passed completely!")

if __name__ == "__main__":
    run_test()
