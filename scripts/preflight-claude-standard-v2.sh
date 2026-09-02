#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$script_dir/../infra/environments/claude-standard-v2"
tfvars_file=""
network_template=""

usage() {
  cat <<'EOF'
Usage: scripts/preflight-claude-standard-v2.sh [options]

Options:
  --terraform-dir <path>  Claude Standard v2 Terraform root
  --tfvars-file <path>    Variable file to inspect (default: <root>/terraform.tfvars)
  -h, --help              Show this help

The script performs read-only checks for Korea Central StandardV2 APIM,
StandardV2 NAT/public IP support, provider registration, and HTTPS reachability
of the configured Keycloak discovery and Azure Databricks workspace endpoints.
It does not inspect Azure AI model availability or quota.
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

cleanup() {
  if [[ -n "$network_template" && -f "$network_template" ]]; then
    rm -f -- "$network_template"
  fi
}
trap cleanup EXIT

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

for command in az curl terraform node; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "FAIL  $command is not available in PATH." >&2
    exit 1
  fi
done

if [[ ! -d "$terraform_dir" ]]; then
  echo "FAIL  Terraform directory does not exist: $terraform_dir" >&2
  exit 1
fi

terraform_dir="$(cd "$terraform_dir" && pwd)"
tfvars_file="${tfvars_file:-$terraform_dir/terraform.tfvars}"
if [[ ! -f "$tfvars_file" ]]; then
  echo "FAIL  Terraform variable file does not exist: $tfvars_file" >&2
  exit 1
fi
tfvars_file="$(cd "$(dirname "$tfvars_file")" && pwd)/$(basename "$tfvars_file")"

terraform "-chdir=$terraform_dir" init -backend=false -input=false >/dev/null
terraform "-chdir=$terraform_dir" validate >/dev/null

if ! subscription_id=$(az account show --query id -o tsv 2>/dev/null) ||
   [[ -z "$subscription_id" ]]; then
  echo "FAIL  no Azure subscription is selected. Run az login and select a subscription." >&2
  exit 1
fi

terraform_value() {
  local expression="$1"
  local output

  if ! output=$(
    printf '%s\n' "$expression" |
      terraform "-chdir=$terraform_dir" console "-var-file=$tfvars_file" 2>&1
  ); then
    printf '%s\n' "$output" >&2
    exit 1
  fi

  printf '%s\n' "$output" |
    node -e '
      let input = "";
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => input += chunk);
      process.stdin.on("end", () => {
        const lines = input.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
        for (let index = lines.length - 1; index >= 0; index -= 1) {
          try {
            const value = JSON.parse(lines[index]);
            process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
            return;
          } catch {
            // Terraform warnings can precede the single-line console result.
          }
        }
        console.error("FAIL  Terraform console did not return a JSON value.");
        process.exit(1);
      });
    '
}

management_get() {
  local url="$1"
  curl --silent --show-error --fail --location \
    --oauth2-bearer "$management_token" \
    "$url"
}

check_https_endpoint() {
  local label="$1"
  local url="$2"
  local require_success="$3"
  local status

  if ! status=$(curl --silent --show-error --location \
    --connect-timeout 10 \
    --max-time 30 \
    --output /dev/null \
    --write-out "%{http_code}" \
    "$url"); then
    echo "FAIL  $label is not reachable over HTTPS: $url" >&2
    exit 1
  fi

  if [[ "$require_success" == "true" ]]; then
    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
      echo "FAIL  $label returned HTTP $status, expected 2xx: $url" >&2
      exit 1
    fi
  elif [[ "$status" == "000" || "$status" =~ ^5[0-9][0-9]$ ]]; then
    echo "FAIL  $label returned HTTP $status: $url" >&2
    exit 1
  fi

  echo "PASS  $label is reachable over HTTPS (HTTP $status)."
}

apim_location=$(terraform_value 'var.apim_location')
apim_sku=$(terraform_value 'var.apim_sku')
apim_capacity=$(terraform_value 'var.apim_capacity')
oidc_openid_config_url=$(terraform_value 'var.oidc_provider.openid_config_url')
databricks_workspace_url=$(terraform_value 'var.databricks_claude_gateway.workspace_url')

echo "Subscription: $subscription_id"
echo "APIM: $apim_sku capacity $apim_capacity in $apim_location"
echo "INFO  Databricks workspace subscription and tenant are not discovered from workspace_url."
echo "INFO  Endpoint checks run from this host, not through the future APIM subnet and NAT path."

management_token=$(az account get-access-token \
  --resource https://management.azure.com/ \
  --query accessToken \
  -o tsv)

for provider in \
  Microsoft.ApiManagement \
  Microsoft.Network \
  Microsoft.Web \
  Microsoft.Insights \
  Microsoft.OperationalInsights; do
  state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
  if [[ "$state" != "Registered" ]]; then
    echo "FAIL  provider $provider is $state; register it before deployment." >&2
    exit 1
  fi
done
echo "PASS  required Azure resource providers are registered."

apim_skus_url="https://management.azure.com/subscriptions/$subscription_id/providers/Microsoft.ApiManagement/skus?api-version=2024-05-01"
apim_skus_json=$(management_get "$apim_skus_url")

printf '%s' "$apim_skus_json" |
  APIM_LOCATION="$apim_location" \
  APIM_SKU="$apim_sku" \
  APIM_CAPACITY="$apim_capacity" \
  node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => input += chunk);
    process.stdin.on("end", () => {
      const payload = JSON.parse(input);
      const location = process.env.APIM_LOCATION.toLowerCase();
      const requestedSku = process.env.APIM_SKU;
      const requestedCapacity = Number(process.env.APIM_CAPACITY);
      const sku = (payload.value || []).find((item) =>
        item.name === requestedSku &&
        (item.locations || []).some((itemLocation) => itemLocation.toLowerCase() === location)
      );
      if (!sku) {
        console.error(`FAIL  ${requestedSku} is not advertised in ${location} for this subscription.`);
        process.exit(1);
      }
      const locationRestricted = (sku.restrictions || []).some((restriction) => {
        const locations = [
          ...(restriction.values || []),
          ...(restriction.restrictionInfo?.locations || [])
        ].map((value) => value.toLowerCase());
        return restriction.type === "Location" && locations.includes(location);
      });
      if (locationRestricted) {
        console.error(`FAIL  ${requestedSku} is restricted in ${location} for this subscription.`);
        process.exit(1);
      }
      if (Number(sku.capacity?.maximum || 0) < requestedCapacity) {
        console.error(`FAIL  ${requestedSku} maximum ${sku.capacity?.maximum || 0} is below requested ${requestedCapacity}.`);
        process.exit(1);
      }
      console.log(`PASS  ${requestedSku} supports ${location}; maximum units ${sku.capacity.maximum}.`);
    });
  '

validation_resource_group=$(az group list \
  --query "sort_by([?properties.provisioningState=='Succeeded'], &name)[0].name" \
  -o tsv)
if [[ -z "$validation_resource_group" ]]; then
  echo "FAIL  no readable resource group is available for read-only ARM validation." >&2
  exit 1
fi

network_name_suffix=$(node -p \
  "require('crypto').createHash('sha256').update(process.argv[1]).digest('hex').slice(0, 10)" \
  "$subscription_id|$apim_location|claude-standard-v2")
network_template=$(mktemp)

cat > "$network_template" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.Network/publicIPAddresses",
      "apiVersion": "2025-01-01",
      "name": "pip-claude-v2-preflight-${network_name_suffix}",
      "location": "${apim_location}",
      "sku": {
        "name": "StandardV2",
        "tier": "Regional"
      },
      "properties": {
        "publicIPAllocationMethod": "Static",
        "publicIPAddressVersion": "IPv4"
      }
    },
    {
      "type": "Microsoft.Network/natGateways",
      "apiVersion": "2025-01-01",
      "name": "ng-claude-v2-preflight-${network_name_suffix}",
      "location": "${apim_location}",
      "sku": {
        "name": "StandardV2"
      },
      "properties": {
        "idleTimeoutInMinutes": 10
      }
    }
  ]
}
EOF

if network_validation=$(az deployment group validate \
  --resource-group "$validation_resource_group" \
  --name "claude-v2-network-preflight-${network_name_suffix}" \
  --template-file "$network_template" \
  --output none 2>&1); then
  echo "PASS  StandardV2 NAT Gateway and public IP validate in $apim_location."
else
  echo "FAIL  StandardV2 NAT Gateway or public IP is unavailable in $apim_location." >&2
  printf '%s\n' "$network_validation" >&2
  exit 1
fi

check_https_endpoint "Keycloak discovery document" "$oidc_openid_config_url" true
check_https_endpoint "Azure Databricks workspace" "$databricks_workspace_url" false

echo "PASS  Claude Standard v2 preflight checks succeeded."
