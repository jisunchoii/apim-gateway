#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$script_dir/../infra"
registry_html="$script_dir/../docs/model-gateway-registry.html"
plan_only=false

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options]

Options:
  --terraform-dir <path>  Terraform configuration directory
  --registry-html <path>  Model Gateway Registry HTML file
  --plan-only             Create the saved plan without applying it
  -h, --help              Show this help
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "FAIL  $option requires a path." >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir)
      require_value "$1" "${2:-}"
      terraform_dir="$2"
      shift 2
      ;;
    --registry-html)
      require_value "$1" "${2:-}"
      registry_html="$2"
      shift 2
      ;;
    --plan-only)
      plan_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL  unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$terraform_dir" ]]; then
  echo "FAIL  Terraform directory does not exist: $terraform_dir" >&2
  exit 1
fi
if [[ ! -f "$registry_html" ]]; then
  echo "FAIL  Registry HTML does not exist: $registry_html" >&2
  exit 1
fi
if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL  terraform is not available in PATH." >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL  node is not available in PATH." >&2
  exit 1
fi

terraform_dir="$(cd "$terraform_dir" && pwd)"
registry_html="$(cd "$(dirname "$registry_html")" && pwd)/$(basename "$registry_html")"
plan_path="$terraform_dir/gateway-deploy.tfplan"
generator_path="$script_dir/generate-model-gateway-registry.mjs"

cleanup() {
  if [[ "$plan_only" == false ]]; then
    rm -f -- "$plan_path"
  fi
}
trap cleanup EXIT

terraform "-chdir=$terraform_dir" plan "-out=$plan_path"

if [[ "$plan_only" == true ]]; then
  echo "Plan saved to $plan_path. HTML was not generated because no apply ran."
  exit 0
fi

terraform "-chdir=$terraform_dir" apply "$plan_path"
node "$generator_path" --terraform-dir "$terraform_dir" --html "$registry_html"
