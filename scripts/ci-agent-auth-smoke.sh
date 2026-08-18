#!/usr/bin/env bash
# Verifies non-interactive Codex and OpenCode coding edits through the service API subscription.
set -euo pipefail

for command_name in codex git node opencode; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "FAIL  $command_name is not available in PATH." >&2
    exit 1
  fi
done

: "${LLMGW_SERVICE_BASE_URL:?Set LLMGW_SERVICE_BASE_URL to the service API base URL.}"
: "${LLMGW_SUBSCRIPTION_KEY:?Set LLMGW_SUBSCRIPTION_KEY to an API-scoped APIM subscription key.}"

codex_model="${LLMGW_CI_CODEX_MODEL:-gpt-5.4}"
opencode_responses_model="${LLMGW_CI_OPENCODE_RESPONSES_MODEL:-gpt-5.6-sol}"
chat_model="${LLMGW_CI_CHAT_MODEL:-FW-Kimi-K3}"
run_codex="${LLMGW_CI_RUN_CODEX:-true}"
run_opencode_responses="${LLMGW_CI_RUN_OPENCODE_RESPONSES:-true}"
run_opencode_chat="${LLMGW_CI_RUN_OPENCODE_CHAT:-true}"
base_url="${LLMGW_SERVICE_BASE_URL%/}"

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

if [[ "$run_codex" == "true" ]]; then
  codex_repo="$tmp_root/codex-repo"
  codex_home="$tmp_root/codex-home"
  initialize_repo "$codex_repo"
  mkdir -p "$codex_home"
  escaped_base_url=$(toml_escape "$base_url")

  cat > "$codex_home/config.toml" <<EOF
model = "$codex_model"
model_provider = "apim_service"
approval_policy = "never"
sandbox_mode = "workspace-write"

[model_providers.apim_service]
name = "APIM Service Gateway"
base_url = "$escaped_base_url"
wire_api = "responses"
requires_openai_auth = false
env_http_headers = { "Ocp-Apim-Subscription-Key" = "LLMGW_SUBSCRIPTION_KEY" }

[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false

[shell_environment_policy.filters]
"LLMGW_SUBSCRIPTION_KEY" = "exclude"
EOF

  CODEX_HOME="$codex_home" codex exec \
    --strict-config \
    --ephemeral \
    -C "$codex_repo" \
    --dangerously-bypass-approvals-and-sandbox \
    "Edit result.txt so its entire contents are exactly CODEX_CI_OK followed by one newline. Do not modify any other file."

  if [[ "$(cat "$codex_repo/result.txt")" != "CODEX_CI_OK" ]]; then
    echo "FAIL  Codex did not perform the expected service-authenticated edit." >&2
    exit 1
  fi
  echo "PASS  Codex CI service-authenticated coding edit"
fi

create_opencode_config() {
  local model="$1" provider="$2" npm_package="$3" output="$4"
  node - "$model" "$provider" "$npm_package" "$base_url" "$LLMGW_SUBSCRIPTION_KEY" > "$output" <<'NODE'
const [
  model,
  provider,
  npmPackage,
  baseURL,
  subscriptionKey,
] = process.argv.slice(2)

const modelDefinition = {
  name: model,
}
if (npmPackage === "@ai-sdk/openai") {
  modelDefinition.tool_call = true
  modelDefinition.options = {
    systemMessageMode: "system",
    reasoningEffort: "high",
    reasoningSummary: "auto",
    textVerbosity: "low",
    store: true,
    include: ["reasoning.encrypted_content"],
  }
}

process.stdout.write(JSON.stringify({
  $schema: "https://opencode.ai/config.json",
  provider: {
    [provider]: {
      npm: npmPackage,
      name: "APIM Service Gateway",
      options: {
        baseURL,
        apiKey: "unused",
        headers: {
          "Ocp-Apim-Subscription-Key": subscriptionKey,
        },
        timeout: 300000,
      },
      models: {
        [model]: modelDefinition,
      },
    },
  },
  permission: {
    "*": "allow",
    bash: "deny",
    external_directory: "deny",
    webfetch: "deny",
    websearch: "deny",
  },
}))
NODE
  chmod 600 "$output"
}

run_opencode_edit() {
  local label="$1" provider="$2" model="$3" npm_package="$4" expected="$5"
  local repo="$tmp_root/$label-repo"
  local config="$tmp_root/$label-config.json"
  initialize_repo "$repo"
  create_opencode_config "$model" "$provider" "$npm_package" "$config"

  OPENCODE_CONFIG="$config" opencode run \
    --pure \
    --auto \
    --dir "$repo" \
    --model "$provider/$model" \
    "Use the file editing tool, not shell commands. Edit result.txt so its entire contents are exactly $expected followed by one newline. Do not modify any other file."

  if [[ "$(cat "$repo/result.txt")" != "$expected" ]]; then
    echo "FAIL  OpenCode $label did not perform the expected service-authenticated edit." >&2
    exit 1
  fi
  echo "PASS  OpenCode $label CI service-authenticated coding edit"
}

if [[ "$run_opencode_responses" == "true" ]]; then
  run_opencode_edit \
    "responses" \
    "apim_responses" \
    "$opencode_responses_model" \
    "@ai-sdk/openai" \
    "OPENCODE_RESPONSES_CI_OK"
fi

if [[ "$run_opencode_chat" == "true" ]]; then
  run_opencode_edit \
    "chat" \
    "apim_chat" \
    "$chat_model" \
    "@ai-sdk/openai-compatible" \
    "OPENCODE_CHAT_CI_OK"
fi
