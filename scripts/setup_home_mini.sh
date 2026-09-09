#!/usr/bin/env bash
# scripts/setup_home_mini.sh — Initialize and configure $HOME/.mini directory for mini-agent

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

# Process CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE_UPDATE=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -f, --force    Overwrite/re-sync global skills and commands"
            echo "  -h, --help     Display this help message"
            exit 0
            ;;
        *)
            echo "Invalid option: $1"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

echo -e "${CYAN}========================================================${NC}"
echo -e "${CYAN}       MINI-AGENT: INITIALIZE AND CONFIGURE ~/.mini     ${NC}"
echo -e "${CYAN}========================================================${NC}"
echo -e "Target directory: ${BLUE}${MINI_HOME}${NC}"
echo ""

# 1. Create core directories
echo -e "${BLUE}[1/5] Initializing directory structure...${NC}"
DIRECTORIES=(
    "${MINI_HOME}"
    "${MINI_HOME}/skills"
    "${MINI_HOME}/commands"
    "${MINI_HOME}/sessions"
    "${MINI_HOME}/acts"
    "${MINI_HOME}/artifacts"
    "${MINI_HOME}/memory"
    "${MINI_HOME}/cas"
)

for dir in "${DIRECTORIES[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo -e "  ${GREEN}+ Created:${NC} $dir"
    else
        echo -e "  • Already exists: $dir"
    fi
done
echo ""

# 2. Copy Skills from .agent/skills to ~/.mini/skills
echo -e "${BLUE}[2/5] Installing global Skills...${NC}"
if [ -d "${PROJECT_ROOT}/.agent/skills" ]; then
    for skill_dir in "${PROJECT_ROOT}/.agent/skills"/*; do
        if [ -d "$skill_dir" ]; then
            skill_name="$(basename "$skill_dir")"
            target_skill="${MINI_HOME}/skills/${skill_name}"
            
            if [ ! -d "$target_skill" ] || [ "$FORCE_UPDATE" -eq 1 ]; then
                mkdir -p "$target_skill"
                cp -r "$skill_dir"/* "$target_skill"/
                # Grant execute permissions to scripts if present
                if [ -d "$target_skill/scripts" ]; then
                    chmod +x "$target_skill/scripts"/* 2>/dev/null || true
                fi
                echo -e "  ${GREEN}✓ Installed skill:${NC} ${skill_name}"
            else
                echo -e "  • Skill already exists (skipped): ${skill_name} ${YELLOW}(use -f to update)${NC}"
            fi
        fi
    done
else
    echo -e "  ${YELLOW}! Not found: ${PROJECT_ROOT}/.agent/skills${NC}"
fi
echo ""

# 3. Copy Custom Commands from .agent/commands to ~/.mini/commands
echo -e "${BLUE}[3/5] Installing global Custom Slash Commands...${NC}"
if [ -d "${PROJECT_ROOT}/.agent/commands" ]; then
    for cmd_file in "${PROJECT_ROOT}/.agent/commands"/*.md; do
        if [ -f "$cmd_file" ]; then
            cmd_name="$(basename "$cmd_file")"
            target_cmd="${MINI_HOME}/commands/${cmd_name}"
            
            if [ ! -f "$target_cmd" ] || [ "$FORCE_UPDATE" -eq 1 ]; then
                cp "$cmd_file" "$target_cmd"
                echo -e "  ${GREEN}✓ Installed command:${NC} /${cmd_name%.md}"
            else
                echo -e "  • Command already exists: /${cmd_name%.md}"
            fi
        fi
    done
else
    echo -e "  • No custom commands found."
fi
echo ""

# 4. Initialize config.json if not present
echo -e "${BLUE}[4/5] Checking global config file (config.json)...${NC}"
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
    echo -e "  ${GREEN}✓ Created:${NC} $CONFIG_FILE"
else
    echo -e "  • Already exists: $CONFIG_FILE"
fi
echo ""

# 5. Initialize .env.example and mcp.json.example
echo -e "${BLUE}[5/5] Creating template configs (.env.example, mcp.json.example)...${NC}"

ENV_EXAMPLE="${MINI_HOME}/.env.example"
cat << 'EOF' > "$ENV_EXAMPLE"
# ==========================================
# AI Backend Configuration for mini-agent (~/.mini/.env)
# ==========================================

# 1. OpenAI-compatible endpoint (Highest priority)
# OPENAI_COMPAT_URL=https://api.openai.com/v1
# OPENAI_COMPAT_API_KEY=sk-...
# OPENAI_COMPAT_MODEL=gpt-4o-mini
# OPENAI_COMPAT_API_HEADER=Authorization

# 2. Anthropic Claude
# ANTHROPIC_API_KEY=sk-ant-...
# CLAUDE_MODEL=claude-opus-4-5

# 3. Ollama local backend (No key required)
# OLLAMA_HOST=http://localhost:11434
# OLLAMA_MODEL=llama3

# 4. Agent Options
# MINI_EXECUTION_MODE=auto       # auto | codeact | tools
# MINI_MAX_TOKENS=8192
# MINI_MEMACT_ENABLED=1
EOF
echo -e "  ${GREEN}✓ Created:${NC} $ENV_EXAMPLE"

# Create ~/.mini/.env if not present
ENV_FILE="${MINI_HOME}/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo -e "  ${GREEN}✓ Initialized:${NC} $ENV_FILE"
else
    echo -e "  • Already exists: $ENV_FILE"
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
echo -e "  ${GREEN}✓ Created:${NC} $MCP_EXAMPLE"
echo ""

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}✓ ~/.mini SETUP COMPLETED SUCCESSFULLY!                 ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "To start using mini-agent across your system:"
echo -e "  1. Configure your API keys in: ${CYAN}${MINI_HOME}/.env${NC}"
echo -e "  2. Run the agent: ${CYAN}mini${NC} (or ${CYAN}mini -e \"...\"${NC})"
