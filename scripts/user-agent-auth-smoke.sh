#!/usr/bin/env bash
# Verifies that interactive users can make Codex and OpenCode edit files through the OIDC API.
set -euo pipefail

if command -v terraform >/dev/null 2>&1; then
  terraform_bin=terraform
elif command -v terraform.exe >/dev/null 2>&1; then
  terraform_bin=terraform.exe
else
  echo "FAIL  terraform is not available in PATH." >&2
  exit 1
fi

for command_name in codex git node opencode; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "FAIL  $command_name is not available in PATH." >&2
    exit 1
  fi
done

if python3 --version >/dev/null 2>&1; then
  python_bin=python3
elif python --version >/dev/null 2>&1; then
  python_bin=python
else
  echo "FAIL  Python is not available in PATH." >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
infra_dir="$repo_root/infra"
base_url=$("$terraform_bin" -chdir="$infra_dir" output -raw gateway_base_url)
model_config=$("$terraform_bin" -chdir="$infra_dir" output -json opencode_model_config)
responses_model="${LLMGW_AGENT_RESPONSES_MODEL:-$("$python_bin" -c '
import json
import sys

config = json.loads(sys.argv[1])
models = config["responses_models"]
preferred = config.get("default_model")
if not models:
    raise SystemExit("No Responses model is configured.")
print(preferred if preferred in models else models[0])
' "$model_config")}"
agent_tool="${LLMGW_AGENT_TOOL:-all}"
if [[ "$agent_tool" != "all" && "$agent_tool" != "codex" && "$agent_tool" != "opencode" ]]; then
  echo "FAIL  LLMGW_AGENT_TOOL must be all, codex, or opencode." >&2
  exit 1
fi

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

initialize_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.email "agent-smoke@example.invalid"
  git -C "$path" config user.name "Agent Smoke Test"
  printf 'before\n' > "$path/result.txt"
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

node "$repo_root/scripts/keycloak/keycloak-token.js" >/dev/null

if [[ "$agent_tool" == "all" || "$agent_tool" == "codex" ]]; then
  codex_repo="$tmp_root/codex-repo"
  codex_home="$tmp_root/codex-home"
  initialize_repo "$codex_repo"
  mkdir -p "$codex_home"
  token_helper_path="$repo_root/scripts/keycloak/keycloak-token.js"
  if command -v cygpath >/dev/null 2>&1; then
    token_helper_path=$(cygpath -w "$token_helper_path")
  fi
  token_helper=$(toml_escape "$token_helper_path")
  escaped_base_url=$(toml_escape "$base_url")

  cat > "$codex_home/config.toml" <<EOF
model = "$responses_model"
model_provider = "llmgw"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.llmgw]
name = "LLM Gateway"
base_url = "$escaped_base_url"
wire_api = "responses"

[model_providers.llmgw.auth]
command = "node"
args = ["$token_helper"]
timeout_ms = 30000
refresh_interval_ms = 240000
EOF

  CODEX_HOME="$codex_home" codex exec \
    --strict-config \
    --ephemeral \
    -C "$codex_repo" \
    --dangerously-bypass-approvals-and-sandbox \
    "Edit result.txt so its entire contents are exactly CODEX_OIDC_OK followed by one newline. Do not modify any other file."

  if [[ "$(cat "$codex_repo/result.txt")" != "CODEX_OIDC_OK" ]]; then
    echo "FAIL  Codex did not perform the expected OIDC-authenticated edit." >&2
    exit 1
  fi
  echo "PASS  Codex user OIDC coding edit"
fi

if [[ "$agent_tool" == "all" || "$agent_tool" == "opencode" ]]; then
  opencode_repo="$tmp_root/opencode-repo"
  initialize_repo "$opencode_repo"

  LLMGW_BASE_URL="$base_url" \
  OPENCODE_CONFIG="$repo_root/opencode.json" \
  opencode run \
    --auto \
    --dir "$opencode_repo" \
    --model "openai/$responses_model" \
    "Edit result.txt so its entire contents are exactly OPENCODE_OIDC_OK followed by one newline. Do not modify any other file."

  if [[ "$(cat "$opencode_repo/result.txt")" != "OPENCODE_OIDC_OK" ]]; then
    echo "FAIL  OpenCode did not perform the expected OIDC-authenticated edit." >&2
    exit 1
  fi
  echo "PASS  OpenCode user OIDC coding edit"
fi
