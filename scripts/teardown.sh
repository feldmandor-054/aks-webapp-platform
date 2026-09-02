#!/usr/bin/env bash
# Tear down everything that costs money, optionally everything the bootstrap created too.
#
#   scripts/teardown.sh                 # destroy the dev environment (AKS, LB/IP, Log Analytics, VNet) via Terraform
#   scripts/teardown.sh --all           # ...plus resource groups, state storage and the two Entra apps
#   ENV=prod scripts/teardown.sh        # same for prod
#
# Requires: az login (Owner), terraform. Reads IDs from infra/bootstrap/bootstrap.out.env.
set -euo pipefail
ENV="${ENV:-dev}"
PROJECT="${PROJECT:-webapp}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL=false; [[ "${1:-}" == "--all" ]] && ALL=true

if [[ -f "$ROOT/infra/bootstrap/bootstrap.out.env" ]]; then
  set -a; # shellcheck disable=SC1091
  source "$ROOT/infra/bootstrap/bootstrap.out.env"; set +a
fi
export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
export ARM_TENANT_ID="${ARM_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
export ARM_USE_AZUREAD=true

echo "== 1. terraform destroy ($ENV): AKS cluster, node pool VMs, load balancer + public IP, Log Analytics, VNet/NSG"
terraform -chdir="$ROOT/infra/envs/$ENV" init -input=false -backend-config=backend.hcl >/dev/null
terraform -chdir="$ROOT/infra/envs/$ENV" destroy -input=false -auto-approve

echo "== 2. leftovers created by AKS add-ons outside Terraform (e.g. the ContainerInsights solution shell)"
ids=$(az resource list -g "rg-${PROJECT}-${ENV}" --query "[].id" -o tsv)
[[ -n "$ids" ]] && az resource delete --ids $ids && echo "   removed: $(echo "$ids" | xargs -n1 basename | tr '\n' ' ')"
az resource list -g "rg-${PROJECT}-${ENV}" -o table || true
# AKS creates a managed node resource group (MC_*); it is deleted with the cluster. Verify:
az group list --query "[?starts_with(name, 'MC_rg-${PROJECT}-${ENV}')].name" -o tsv | while read -r mc; do
  echo "   leftover node RG $mc -> deleting"; az group delete -n "$mc" --yes --no-wait; done

$ALL || { echo "Done. State storage (~cents/month) and identities kept; run with --all to remove them."; exit 0; }

echo "== 3. --all: resource groups (workload + tfstate), Entra applications"
for rg in "rg-${PROJECT}-dev" "rg-${PROJECT}-prod" "rg-${PROJECT}-tfstate"; do
  az group exists -n "$rg" | grep -q true && { echo "   deleting $rg"; az group delete -n "$rg" --yes --no-wait; }
done
for app in "${AZURE_INFRA_CLIENT_ID:-}" "${AZURE_DEPLOY_CLIENT_ID:-}"; do
  [[ -n "$app" ]] && { echo "   deleting Entra app $app"; az ad app delete --id "$app" || true; }
done
echo "Done. Verify with: az group list -o table   (should show none of rg-${PROJECT}-*)"
echo "Also remove the GitHub repository variables if the repo is no longer used:  gh variable list"
