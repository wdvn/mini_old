# Implementation Plan: Wrap Submission API into MCP Server

## Goal
Thay vì hardcode script hay lệnh `curl` gửi HTTP trực tiếp trong Agent System Prompt, chúng ta sẽ định nghĩa một **MCP Server** chuẩn chỉ (chạy cục bộ) cung cấp công cụ `send_report` cho Agent. Tool này sẽ ẩn chứa logic HTTP calls bên trong, và System Prompt chỉ cần ra lệnh cho AI gọi tool này.

## Proposed Changes

### [NEW] `examples/newspaper/mcp_server.py`
- Sẽ sử dụng `FastMCP` (Python) để expose 1 tool tên là `send_report`.
- Khi AI kích hoạt `send_report(content="...")`, server này sẽ gửi POST payload `{content: ...}` tới `https://me.thewdvn.cc/api/mcp/tools`.

### [NEW] `examples/newspaper/mcp.json`
- Cấu hình file `mcp.json` móc nối vào `mini-agent` theo format:
```json
{
  "servers": {
    "wdvn_api": {
      "command": "python3",
      "args": ["/app/examples/newspaper/mcp_server.py"]
    }
  }
}
```

### [MODIFY] `examples/newspaper/Dockerfile`
- Cập nhật thêm lệnh: `pip3 install mcp requests --break-system-packages` để setup môi trường chạy MCP.

### [MODIFY] `examples/newspaper/docker-compose.yml`
- Gắn thêm biến môi trường `- MINI_MCP_CONFIG=/app/examples/newspaper/mcp.json`.

### [MODIFY] `examples/newspaper/system_prompt.md` & `run.sh`
- System prompt sẽ gọn gàng lại, chỉ còn: *"Sử dụng tool `wdvn_api__send_report` để nộp bài khi phân tích và viết báo cáo xong."*
- Bỏ sạch nhắc nhở dùng `bash` hay `curl`/scripting HTTP bên trong System Prompt.
