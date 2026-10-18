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
    "${MINI_HOME}/providers"
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
                rm -rf "$target_skill"
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

    # Prune retired skills no longer compatible with mini (superpowers leftovers)
    for retired in using-superpowers diagnosing-superpowers dispatching-parallel-agents; do
        if [ -d "${MINI_HOME}/skills/${retired}" ]; then
            rm -rf "${MINI_HOME}/skills/${retired}"
            echo -e "  ${GREEN}✓ Removed retired skill:${NC} ${retired}"
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

# 4. Initialize config.json (Unified Global Configuration)
echo -e "${BLUE}[4/5] Configuring unified global config (${MINI_HOME}/config.json)...${NC}"
CONFIG_FILE="${MINI_HOME}/config.json"
CONFIG_EXAMPLE="${MINI_HOME}/config.json.example"

cat << 'EOF' > "$CONFIG_EXAMPLE"
{
  "openai_compat_url": "https://api.openai.com/v1",
  "openai_compat_api_key": null,
  "openai_compat_model": "gpt-4o-mini",
  "openai_protocol": "auto",
  "anthropic_api_key": null,
  "claude_model": "claude-opus-4-5",
  "ollama_host": "http://localhost:11434",
  "ollama_model": "llama3",
  "execution_mode": "auto",
  "max_tokens": 8192,
  "dynamic_thinking_enabled": true,
  "memact_enabled": true,
  "context_window": 128000
}
EOF
echo -e "  ${GREEN}✓ Created template:${NC} $CONFIG_EXAMPLE"

if [ ! -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    echo -e "  ${GREEN}✓ Initialized:${NC} $CONFIG_FILE"
else
    echo -e "  • Already exists: $CONFIG_FILE"
fi

# Migration: if legacy ~/.mini/.env exists, archive it
if [ -f "${MINI_HOME}/.env" ]; then
    echo -e "  ${YELLOW}! Legacy ~/.mini/.env detected. Global configuration is now managed via config.json.${NC}"
    mv "${MINI_HOME}/.env" "${MINI_HOME}/.env.backup.$(date +%s)"
    echo -e "  ${GREEN}✓ Archived legacy .env to .env.backup${NC}"
fi
if [ -f "${MINI_HOME}/.env.example" ]; then
    rm -f "${MINI_HOME}/.env.example"
fi
echo ""

# 5. Initialize mcp.json.example
echo -e "${BLUE}[5/5] Creating template MCP config (mcp.json.example)...${NC}"
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

# 5.5. Sync .agent/AGENTS.md (global rules) from project to ~/.mini/
echo -e "${BLUE}[5.5/6] Checking global AGENTS.md (.agent/)...${NC}"
AGENTS_SRC="${PROJECT_ROOT}/.agent/AGENTS.md"
AGENTS_DST="${MINI_HOME}/AGENTS.md"
if [ -f "$AGENTS_SRC" ]; then
    if [ ! -f "$AGENTS_DST" ] || [ "$FORCE_UPDATE" -eq 1 ]; then
        cp "$AGENTS_SRC" "$AGENTS_DST"
        echo -e "  ${GREEN}✓ Synced:${NC} .agent/AGENTS.md → $AGENTS_DST"
    else
        echo -e "  • AGENTS.md exists (use -f to update)"
    fi
else
    echo -e "  ${YELLOW}! Skipped: ${AGENTS_SRC} not found${NC}"
fi
echo ""

# 6. Configure VS Code / Antigravity / Cursor / Trae terminal keybindings for Shift+Enter & Ctrl+Enter
echo -e "${BLUE}[6/6] Checking VS Code / Antigravity / Cursor terminal configuration...${NC}"
python3 -c '
import os, json

ide_dirs = [
    os.path.expanduser("~/.config/Antigravity IDE/User"),
    os.path.expanduser("~/.config/Antigravity/User"),
    os.path.expanduser("~/.config/Cursor/User"),
    os.path.expanduser("~/.config/Code/User"),
    os.path.expanduser("~/.config/Trae/User"),
    os.path.expanduser("~/.config/VSCodium/User"),
]

for user_dir in ide_dirs:
    if not os.path.isdir(user_dir):
        continue
    ide_name = os.path.basename(os.path.dirname(user_dir))
    kb_file = os.path.join(user_dir, "keybindings.json")
    st_file = os.path.join(user_dir, "settings.json")

    # 1. Keybindings
    bindings = []
    if os.path.exists(kb_file):
        try:
            with open(kb_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
                if content:
                    bindings = json.loads(content)
                    if not isinstance(bindings, list):
                        bindings = []
        except Exception:
            bindings = []

    has_shift = any(isinstance(b, dict) and b.get("key", "").lower() == "shift+enter" and "terminal" in b.get("command", "").lower() for b in bindings)
    if not has_shift:
        bindings.append({
            "key": "shift+enter",
            "command": "workbench.action.terminal.sendSequence",
            "args": { "text": "\u001b[13;2u" },
            "when": "terminalFocus"
        })

    has_ctrl = any(isinstance(b, dict) and b.get("key", "").lower() == "ctrl+enter" and "terminal" in b.get("command", "").lower() for b in bindings)
    if not has_ctrl:
        bindings.append({
            "key": "ctrl+enter",
            "command": "workbench.action.terminal.sendSequence",
            "args": { "text": "\u001b[13;5u" },
            "when": "terminalFocus"
        })

    with open(kb_file, "w", encoding="utf-8") as f:
        json.dump(bindings, f, indent=2)
        f.write("\n")
    print(f"  \033[0;32m✓\033[0m Configured Shift+Enter & Ctrl+Enter in: {kb_file}")

    # 2. Settings (Kitty keyboard protocol)
    settings = {}
    if os.path.exists(st_file):
        try:
            with open(st_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
                if content:
                    settings = json.loads(content)
                    if not isinstance(settings, dict):
                        settings = {}
        except Exception:
            settings = {}

    settings["terminal.integrated.enableKittyKeyboardProtocol"] = True
    with open(st_file, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=4)
        f.write("\n")
    print(f"  \033[0;32m✓\033[0m Enabled Kitty keyboard protocol in: {st_file}")
' 2>/dev/null || true

echo ""

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}✓ ~/.mini SETUP COMPLETED SUCCESSFULLY!                 ${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "To start using mini-agent across your system:"
echo -e "  1. Configure your API keys in: ${CYAN}${MINI_HOME}/config.json${NC}"
echo -e "  2. Run the agent: ${CYAN}mini${NC} (or ${CYAN}mini -e \"...\"${NC})"

