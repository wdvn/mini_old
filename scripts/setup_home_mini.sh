#!/usr/bin/env bash
# scripts/setup_home_mini.sh — Khởi tạo và thiết lập thư mục $HOME/.mini cho mini-agent

set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

MINI_HOME="${MINI_HOME:-${HOME}/.mini}"
FORCE_UPDATE=0

# Xử lý tham số dòng lệnh
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE_UPDATE=1
            shift
            ;;
        -h|--help)
            echo "Cách dùng: $0 [tuỳ chọn]"
            echo ""
            echo "Tuỳ chọn:"
            echo "  -f, --force    Ghi đè/cập nhật lại skills và commands toàn cục"
            echo "  -h, --help     Hiển thị hướng dẫn này"
            exit 0
            ;;
        *)
            echo "Tuỳ chọn không hợp lệ: $1"
            echo "Dùng '$0 --help' để xem hướng dẫn."
            exit 1
            ;;
    esac
done

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}       MINI-AGENT: KHỞI TẠO VÀ THIẾT LẬP ~/.mini         ${NC}"
echo -e "${CYAN}========================================================${NC}"
echo -e "Thư mục đích: ${BLUE}${MINI_HOME}${NC}"
echo ""

# 1. Tạo các thư mục cốt lõi
echo -e "${BLUE}[1/5] Khởi tạo các thư mục cấu trúc...${NC}"
DIRECTORIES=(
    "${MINI_HOME}"
    "${MINI_HOME}/skills"
    "${MINI_HOME}/commands"
    "${MINI_HOME}/sessions"
    "${MINI_HOME}/artifacts"
    "${MINI_HOME}/memory"
    "${MINI_HOME}/cas"
)

for dir in "${DIRECTORIES[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo -e "  ${GREEN}+ Đã tạo:${NC} $dir"
    else
        echo -e "  • Đã tồn tại: $dir"
    fi
done
echo ""

# 2. Sao chép bộ Skills từ .agent/skills sang ~/.mini/skills
echo -e "${BLUE}[2/5] Cài đặt các Skills toàn cục...${NC}"
if [ -d "${PROJECT_ROOT}/.agent/skills" ]; then
    for skill_dir in "${PROJECT_ROOT}/.agent/skills"/*; do
        if [ -d "$skill_dir" ]; then
            skill_name="$(basename "$skill_dir")"
            target_skill="${MINI_HOME}/skills/${skill_name}"
            
            if [ ! -d "$target_skill" ] || [ "$FORCE_UPDATE" -eq 1 ]; then
                mkdir -p "$target_skill"
                cp -r "$skill_dir"/* "$target_skill"/
                # Cấp quyền thực thi cho các script nếu có
                if [ -d "$target_skill/scripts" ]; then
                    chmod +x "$target_skill/scripts"/* 2>/dev/null || true
                fi
                echo -e "  ${GREEN}✓ Đã cài đặt skill:${NC} ${skill_name}"
            else
                echo -e "  • Skill đã tồn tại (bỏ qua): ${skill_name} ${YELLOW}(dùng -f để cập nhật)${NC}"
            fi
        fi
    done
else
    echo -e "  ${YELLOW}! Không tìm thấy ${PROJECT_ROOT}/.agent/skills${NC}"
fi
echo ""

# 3. Sao chép Custom Commands từ .agent/commands sang ~/.mini/commands
echo -e "${BLUE}[3/5] Cài đặt Custom Slash Commands toàn cục...${NC}"
if [ -d "${PROJECT_ROOT}/.agent/commands" ]; then
    for cmd_file in "${PROJECT_ROOT}/.agent/commands"/*.md; do
        if [ -f "$cmd_file" ]; then
            cmd_name="$(basename "$cmd_file")"
            target_cmd="${MINI_HOME}/commands/${cmd_name}"
            
            if [ ! -f "$target_cmd" ] || [ "$FORCE_UPDATE" -eq 1 ]; then
                cp "$cmd_file" "$target_cmd"
                echo -e "  ${GREEN}✓ Đã cài đặt command:${NC} /${cmd_name%.md}"
            else
                echo -e "  • Command đã tồn tại: /${cmd_name%.md}"
            fi
        fi
    done
else
    echo -e "  • Không có commands tuỳ biến."
fi
echo ""

# 4. Khởi tạo config.json nếu chưa có
echo -e "${BLUE}[4/5] Kiểm tra file cấu hình toàn cục (config.json)...${NC}"
CONFIG_FILE="${MINI_HOME}/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat << 'EOF' > "$CONFIG_FILE"
{
  "execution_mode": "auto",
  "memact_enabled": true,
  "max_tokens": 8192,
  "context_window": 128000
}
EOF
    echo -e "  ${GREEN}✓ Đã tạo:${NC} $CONFIG_FILE"
else
    echo -e "  • Đã tồn tại: $CONFIG_FILE"
fi
echo ""

# 5. Khởi tạo .env.example và mcp.json.example
echo -e "${BLUE}[5/5] Tạo file cấu hình mẫu (.env.example, mcp.json.example)...${NC}"

ENV_EXAMPLE="${MINI_HOME}/.env.example"
cat << 'EOF' > "$ENV_EXAMPLE"
# ==========================================
# Cấu hình AI Backend cho mini-agent (~/.mini/.env)
# ==========================================

# 1. OpenAI-compatible endpoint (Ưu tiên cao nhất)
# OPENAI_COMPAT_URL=https://api.openai.com/v1
# OPENAI_COMPAT_API_KEY=sk-...
# OPENAI_COMPAT_MODEL=gpt-4o-mini
# OPENAI_COMPAT_API_HEADER=Authorization

# 2. Anthropic Claude
# ANTHROPIC_API_KEY=sk-ant-...
# CLAUDE_MODEL=claude-opus-4-5

# 3. Ollama local backend (Không cần key)
# OLLAMA_HOST=http://localhost:11434
# OLLAMA_MODEL=llama3

# 4. Tuỳ chọn Agent
# MINI_EXECUTION_MODE=auto       # auto | codeact | tools
# MINI_MAX_TOKENS=8192
# MINI_MEMACT_ENABLED=1
EOF
echo -e "  ${GREEN}✓ Đã tạo:${NC} $ENV_EXAMPLE"

# Tạo ~/.mini/.env nếu chưa tồn tại
ENV_FILE="${MINI_HOME}/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo -e "  ${GREEN}✓ Đã khởi tạo:${NC} $ENV_FILE"
else
    echo -e "  • Đã tồn tại: $ENV_FILE"
fi

MCP_EXAMPLE="${MINI_HOME}/mcp.json.example"
cat << 'EOF' > "$MCP_EXAMPLE"
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    }
  }
}
EOF
echo -e "  ${GREEN}✓ Đã tạo:${NC} $MCP_EXAMPLE"
echo ""

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}✓ HOÀN TẤT THIẾT LẬP THƯ MỤC ~/.mini THÀNH CÔNG!        ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Để bắt đầu dùng mini-agent toàn hệ thống:"
echo -e "  1. Chỉnh sửa cấu hình API key tại: ${CYAN}${MINI_HOME}/.env${NC}"
echo -e "  2. Chạy agent: ${CYAN}mini${NC} (hoặc ${CYAN}mini -e \"...\"${NC})"
