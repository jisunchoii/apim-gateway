#!/usr/bin/env bash
# Creates or reconciles the Azure Blob backend used for Terraform state.
# Entra ID auth only: shared keys are disabled and state access is assigned with Azure RBAC.
# The storage account name is deterministic for the subscription, stack, prefix, environment, and region.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$script_dir/../infra"
tfvars_file="${TFVARS_FILE:-}"
state_stack="${TF_STATE_STACK:-}"

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-backend.sh [options]

Options:
  --terraform-dir <path>  Terraform root that receives backend.tf
  --tfvars-file <path>    Variable file used to derive names and tags
  --state-stack <name>     State discriminator (default: classic or root directory name)
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
    --tfvars-file)
      require_value "$1" "${2:-}"
      tfvars_file="$2"
      shift 2
      ;;
    --state-stack)
      require_value "$1" "${2:-}"
      state_stack="$2"
      shift 2
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
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL  node is not available in PATH." >&2
  exit 1
fi

terraform_dir="$(cd "$terraform_dir" && pwd)"
if [[ -z "$state_stack" ]]; then
  if [[ "$(basename "$terraform_dir")" == "infra" ]]; then
    state_stack="classic"
  else
    state_stack=$(basename "$terraform_dir" |
      tr '[:upper:]' '[:lower:]' |
      tr -cd 'a-z0-9-')
  fi
fi
if [[ -z "$state_stack" ||
      ${#state_stack} -gt 24 ||
      ! "$state_stack" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "FAIL  state stack must be at most 24 lowercase alphanumeric or hyphen characters." >&2
  exit 2
fi

if [[ -z "$tfvars_file" ]]; then
  tfvars_file="$terraform_dir/terraform.tfvars"
else
  tfvars_file="$(cd "$(dirname "$tfvars_file")" && pwd)/$(basename "$tfvars_file")"
fi

tfvars_value() {
  local key="$1"
  [[ -f "$tfvars_file" ]] || return 0
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\\1/p" "$tfvars_file" |
    head -n 1
}

prefix="${PREFIX:-${TF_VAR_prefix:-$(tfvars_value prefix)}}"
env="${ENV:-${TF_VAR_env:-$(tfvars_value env)}}"
if [[ -n "${LOCATION:-}" ]]; then
  location="$LOCATION"
elif [[ "$state_stack" != "classic" ]]; then
  location="${TF_VAR_apim_location:-$(tfvars_value apim_location)}"
  location="${location:-${TF_VAR_location:-$(tfvars_value location)}}"
else
  location="${TF_VAR_location:-$(tfvars_value location)}"
  location="${location:-${TF_VAR_apim_location:-$(tfvars_value apim_location)}}"
fi
owner="${OWNER:-${TF_VAR_owner:-$(tfvars_value owner)}}"
cost_center="${COST_CENTER:-${TF_VAR_cost_center:-$(tfvars_value cost_center)}}"
retention_days="${STATE_RETENTION_DAYS:-30}"

: "${prefix:?set prefix in $tfvars_file or PREFIX/TF_VAR_prefix}"
: "${env:?set env in $tfvars_file or ENV/TF_VAR_env}"
: "${location:?set location in $tfvars_file or LOCATION/TF_VAR_location}"
: "${owner:?set owner in $tfvars_file or OWNER/TF_VAR_owner}"
: "${cost_center:?set cost_center in $tfvars_file or COST_CENTER/TF_VAR_cost_center}"

if [[ ! "$retention_days" =~ ^[0-9]+$ ]] ||
   (( retention_days < 1 || retention_days > 365 )); then
  echo "FAIL  STATE_RETENTION_DAYS must be a whole number from 1 to 365." >&2
  exit 2
fi

backend_tf="$terraform_dir/backend.tf"
local_state="$terraform_dir/terraform.tfstate"
container="tfstate"
tag_value="${prefix}-${env}-${state_stack}"
tags=(
  "tfstate=$tag_value"
  "env=$env"
  "workload=$prefix"
  "stack=$state_stack"
  "owner=$owner"
  "costCenter=$cost_center"
)

if [[ ! -f "$backend_tf" && -s "$local_state" &&
      "${ALLOW_LOCAL_STATE_MIGRATION:-false}" != "true" ]]; then
  echo "FAIL  existing local state detected at $local_state." >&2
  echo "      This bootstrap is the default for new environments only." >&2
  echo "      Preserve the current state and obtain migration approval before setting" >&2
  echo "      ALLOW_LOCAL_STATE_MIGRATION=true." >&2
  exit 1
fi

if ! subscription_id=$(az account show --query id -o tsv 2>/dev/null) ||
   [[ -z "$subscription_id" ]]; then
  echo "FAIL  no Azure subscription is selected. Run az login and select a subscription." >&2
  exit 1
fi

if [[ "$state_stack" == "classic" ]]; then
  rg="rg-${prefix}-tfstate-${env}-${location}"
  state_key="${prefix}-${env}.tfstate"
  state_identity="$subscription_id|$prefix|$env|$location"
else
  rg="rg-${prefix}-tfstate-${env}-${state_stack}-${location}"
  state_key="${prefix}-${env}-${state_stack}.tfstate"
  state_identity="$subscription_id|$prefix|$env|$state_stack|$location"
fi

storage_prefix=$(printf '%s' "$prefix" |
  tr '[:upper:]' '[:lower:]' |
  tr -cd 'a-z0-9' |
  cut -c1-8)
storage_prefix="${storage_prefix:-gw}"
suffix=$(node -p \
  "require('crypto').createHash('sha256').update(process.argv[1]).digest('hex').slice(0, 10)" \
  "$state_identity")
sa="st${storage_prefix}tf${suffix}"

backend_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\\1/p" "$backend_tf" |
    head -n 1
}

if [[ -f "$backend_tf" ]]; then
  if [[ "$(backend_value resource_group_name)" != "$rg" ||
        "$(backend_value storage_account_name)" != "$sa" ||
        "$(backend_value container_name)" != "$container" ||
        "$(backend_value key)" != "$state_key" ]]; then
    echo "FAIL  $backend_tf does not match the backend derived from the current inputs." >&2
    echo "      Refusing to switch Terraform state automatically." >&2
    exit 1
  fi

  echo "Reusing backend configuration: $rg/$sa"
fi

az group create --name "$rg" --location "$location" --output none

if az storage account show \
  --name "$sa" \
  --resource-group "$rg" \
  --output none 2>/dev/null; then
  echo "Reusing state storage account: $sa"
else
  echo "Creating state storage account: $sa"
  az storage account create \
    --name "$sa" \
    --resource-group "$rg" \
    --location "$location" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --public-network-access Enabled \
    --output none
fi

# Reconcile tags and security settings even when the account already existed.
rg_id=$(az group show --name "$rg" --query id -o tsv)
MSYS_NO_PATHCONV=1 az tag update \
  --resource-id "$rg_id" \
  --operation Merge \
  --tags "${tags[@]}" \
  --output none

az storage account update \
  --name "$sa" \
  --resource-group "$rg" \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --public-network-access Enabled \
  --output none

public_network_access=$(az storage account show \
  --name "$sa" \
  --resource-group "$rg" \
  --query publicNetworkAccess \
  -o tsv)
if [[ "$public_network_access" != "Enabled" ]]; then
  echo "FAIL  storage public network access is $public_network_access after update." >&2
  echo "      An Azure Policy may require private endpoint or network security perimeter access." >&2
  echo "      Configure an approved data-plane path from this runner before using Azure Blob state." >&2
  exit 1
fi

sa_id=$(az storage account show --name "$sa" --resource-group "$rg" --query id -o tsv)
MSYS_NO_PATHCONV=1 az tag update \
  --resource-id "$sa_id" \
  --operation Merge \
  --tags "${tags[@]}" \
  --output none

az storage account blob-service-properties update \
  --account-name "$sa" \
  --resource-group "$rg" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days "$retention_days" \
  --enable-container-delete-retention true \
  --container-delete-retention-days "$retention_days" \
  --output none

az lock create \
  --name terraform-state-delete-lock \
  --lock-type CanNotDelete \
  --resource-group "$rg" \
  --resource-type Microsoft.Storage/storageAccounts \
  --resource "$sa" \
  --notes "Protect Terraform state storage from accidental deletion." \
  --output none

owner_principal="${STATE_OWNER_OBJECT_ID:-}"
if [[ -z "$owner_principal" ]]; then
  if ! owner_principal=$(az ad signed-in-user show --query id -o tsv 2>/dev/null); then
    echo "FAIL  no signed-in user is available." >&2
    echo "      Set STATE_OWNER_OBJECT_ID when running as a service principal or managed identity." >&2
    exit 1
  fi
fi

principals=("$owner_principal")
for principal in ${STATE_CONTRIBUTORS:-}; do
  principals+=("$principal")
done

for principal in "${principals[@]}"; do
  existing=$(MSYS_NO_PATHCONV=1 az role assignment list \
    --assignee "$principal" \
    --scope "$sa_id" \
    --include-inherited \
    --query "[?roleDefinitionName=='Storage Blob Data Contributor' || roleDefinitionName=='Storage Blob Data Owner'] | length(@)" \
    -o tsv)

  if [[ "$existing" == "0" ]]; then
    MSYS_NO_PATHCONV=1 az role assignment create \
      --assignee-object-id "$principal" \
      --role "Storage Blob Data Contributor" \
      --scope "$sa_id" \
      --output none
  fi
done

# RBAC propagation is not instant. Never write a backend configuration that cannot initialize.
created=false
for _ in $(seq 1 12); do
  if az storage container create \
    --name "$container" \
    --account-name "$sa" \
    --auth-mode login \
    --output none 2>/dev/null; then
    created=true
    break
  fi
  sleep 10
done

if [[ "$created" != true ]]; then
  echo "FAIL  could not create container '$container' on '$sa' after 2 minutes." >&2
  echo "      Check Storage Blob Data Contributor on $sa_id, then re-run." >&2
  exit 1
fi

cat > "$backend_tf" <<EOF
terraform {
  backend "azurerm" {
    resource_group_name  = "$rg"
    storage_account_name = "$sa"
    container_name       = "$container"
    key                  = "$state_key"
    use_azuread_auth     = true
  }
}
EOF

echo "Wrote $backend_tf ($rg/$sa, stack $state_stack, key $state_key)."
echo "Now run: terraform -chdir=$terraform_dir init"
