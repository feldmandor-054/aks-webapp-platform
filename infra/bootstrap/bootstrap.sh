#!/usr/bin/env bash
# One-time bootstrap (run by a human with Owner on the subscription, after `az login`):
#   1. registers resource providers
#   2. creates workload resource groups (dev, prod) - landing-zone style
#   3. creates the Terraform state storage account (versioned, soft-delete, Entra-only auth)
#   4. creates two Entra applications with GitHub OIDC federated credentials:
#        <repo>-infra  : Owner on the workload RGs + Blob Data Contributor on state  (runs terraform)
#        <repo>-deploy : no Azure roles here; Terraform grants it AKS RBAC on the cluster (runs helm)
#   5. writes infra/envs/*/backend.hcl and prints the GitHub variables to set.
# No secrets are created anywhere: authentication is federated (OIDC) only.
# Requires: az (logged in as Owner), gh (logged in; used to read owner/repo IDs for the OIDC subject).
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO=owner/repo}"
# Pick a region where the subscription may use small SKUs: az vm list-skus -l <region> --size Standard_B2
LOCATION="${LOCATION:-israelcentral}"
PROJECT="${PROJECT:-webapp}"
ENVS="${ENVS:-dev prod}"
REPO_SLUG="${GITHUB_REPO//\//-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/bootstrap.out.env"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
ME_OID=$(az ad signed-in-user show --query id -o tsv)
echo "Subscription: ${SUB_ID}  Tenant: ${TENANT_ID}  Location: ${LOCATION}"

echo "== 1. resource providers"
for ns in Microsoft.Compute Microsoft.ContainerService Microsoft.Network Microsoft.OperationalInsights \
          Microsoft.OperationsManagement Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Insights; do
  az provider register --namespace "$ns" --wait >/dev/null &
done
wait

echo "== 2. workload resource groups"
for env in $ENVS; do
  az group create -n "rg-${PROJECT}-${env}" -l "$LOCATION" --tags project="$PROJECT" environment="$env" -o none
done

echo "== 3. terraform state storage"
STATE_RG="rg-${PROJECT}-tfstate"
# State may live in a different region than the workloads (e.g. after a region move); keep it where it is.
STATE_LOCATION=$(az group show -n "$STATE_RG" --query location -o tsv 2>/dev/null || echo "$LOCATION")
az group create -n "$STATE_RG" -l "$STATE_LOCATION" -o none
# Storage account names: 3-24 lowercase alphanumerics, globally unique. Deterministic per
# subscription AND region: never reuse a name right after deleting it (Azure Storage caches
# authorization metadata per account name and RBAC then fails with 403 for a long time).
STATE_SA="st${PROJECT}tf$(echo -n "${SUB_ID}/${STATE_LOCATION}" | sha1sum | cut -c1-8)"
if ! az storage account show -n "$STATE_SA" -g "$STATE_RG" -o none 2>/dev/null; then
  az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$STATE_LOCATION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false --allow-shared-key-access false -o none
  az storage account blob-service-properties update --account-name "$STATE_SA" -g "$STATE_RG" \
    --enable-versioning true --enable-delete-retention true --delete-retention-days 30 -o none
fi
az role assignment create --assignee-object-id "$ME_OID" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/${STATE_RG}/providers/Microsoft.Storage/storageAccounts/${STATE_SA}" -o none 2>/dev/null || true
sleep 20 # RBAC propagation
az storage container create -n tfstate --account-name "$STATE_SA" --auth-mode login -o none

echo "== 4. Entra applications + federated credentials"
create_app() { # name -> prints appId
  local name="$1" app_id
  app_id=$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  if [[ -z "$app_id" ]]; then
    app_id=$(az ad app create --display-name "$name" --query appId -o tsv)
    az ad sp create --id "$app_id" -o none
  fi
  echo "$app_id"
}
add_fic() { # appId name subject
  local app_id="$1" name="$2" subject="$3"
  # Idempotent on issuer+subject (Entra enforces uniqueness on that pair, not on the name).
  az ad app federated-credential list --id "$app_id" --query "[?subject=='${subject}'].name" -o tsv | grep -q . && return 0
  az ad app federated-credential create --id "$app_id" --parameters "{
    \"name\": \"${name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
}

INFRA_APP=$(create_app "gh-${REPO_SLUG}-infra")
DEPLOY_APP=$(create_app "gh-${REPO_SLUG}-deploy")
INFRA_OID=$(az ad sp show --id "$INFRA_APP" --query id -o tsv)
DEPLOY_OID=$(az ad sp show --id "$DEPLOY_APP" --query id -o tsv)

# GitHub's OIDC `sub` claim embeds the owner and repository IDs:
#   repo:<owner>@<owner_id>/<repo>@<repo_id>:<ref|pull_request|environment:<name>>
# Resolve them via the API so the federated credentials match exactly what the token presents.
OWNER_ID=$(gh api "repos/${GITHUB_REPO}" --jq .owner.id)
REPO_ID=$(gh api "repos/${GITHUB_REPO}" --jq .id)
SUB_REPO="repo:${GITHUB_REPO%%/*}@${OWNER_ID}/${GITHUB_REPO##*/}@${REPO_ID}"
echo "   OIDC subject prefix: ${SUB_REPO}"

# Drop credentials from earlier runs whose subject does not use the current prefix.
for app_id in "$INFRA_APP" "$DEPLOY_APP"; do
  # Collect first, then delete: `az` reads stdin, so it must not sit on the right side of a pipe.
  mapfile -t stale < <(az ad app federated-credential list --id "$app_id" \
    --query "[?starts_with(subject, 'repo:') && !starts_with(subject, '${SUB_REPO}:')].id" -o tsv)
  for fic in "${stale[@]}"; do
    [[ -n "$fic" ]] && az ad app federated-credential delete --id "$app_id" --federated-credential-id "$fic" </dev/null
  done
done

# PRs may only plan (infra); environments gate apply/deploy.
add_fic "$INFRA_APP"  branch-main  "${SUB_REPO}:ref:refs/heads/main"
add_fic "$INFRA_APP"  pull-request "${SUB_REPO}:pull_request"
for env in $ENVS; do
  add_fic "$INFRA_APP"  "env-${env}" "${SUB_REPO}:environment:${env}"
  add_fic "$DEPLOY_APP" "env-${env}" "${SUB_REPO}:environment:${env}"
done
add_fic "$DEPLOY_APP" branch-main "${SUB_REPO}:ref:refs/heads/main"

echo "== 4b. role assignments for the infra identity (RG-scoped, not subscription-wide)"
# Idempotent + retried: a role assignment on a just-created resource can fail transiently, and
# swallowing that error leaves CI with a confusing 403 later.
assign_role() { # objectId principalType role scope
  local oid="$1" ptype="$2" role="$3" scope="$4" i
  if az role assignment list --assignee "$oid" --role "$role" --scope "$scope" --query "[0].id" -o tsv | grep -q .; then return 0; fi
  for i in 1 2 3 4 5; do
    az role assignment create --assignee-object-id "$oid" --assignee-principal-type "$ptype" \
      --role "$role" --scope "$scope" -o none && return 0
    echo "   retry $i: role '$role' on $(basename "$scope")"; sleep 15
  done
  echo "FAILED to assign '$role' on $scope" >&2; return 1
}
for env in $ENVS; do
  assign_role "$INFRA_OID" ServicePrincipal Owner "/subscriptions/${SUB_ID}/resourceGroups/rg-${PROJECT}-${env}"
done
assign_role "$INFRA_OID" ServicePrincipal "Storage Blob Data Contributor" \
  "/subscriptions/${SUB_ID}/resourceGroups/${STATE_RG}/providers/Microsoft.Storage/storageAccounts/${STATE_SA}"
# Terraform reads the deploy SP to assign AKS roles -> needs directory read on that object (Reader suffices via Graph for own tenant).

echo "== 5. backend config + outputs"
for env in $ENVS; do
  cat > "${HERE}/../envs/${env}/backend.hcl" <<EOF
resource_group_name  = "${STATE_RG}"
storage_account_name = "${STATE_SA}"
container_name       = "tfstate"
key                  = "${PROJECT}-${env}.tfstate"
EOF
done

cat > "$OUT" <<EOF
# Generated by bootstrap.sh - IDs only, no secrets. Git-ignored anyway.
AZURE_TENANT_ID=${TENANT_ID}
AZURE_SUBSCRIPTION_ID=${SUB_ID}
AZURE_INFRA_CLIENT_ID=${INFRA_APP}
AZURE_DEPLOY_CLIENT_ID=${DEPLOY_APP}
TF_VAR_deployer_object_id=${DEPLOY_OID}
TF_VAR_cluster_admin_object_ids='["${ME_OID}"]'
TFSTATE_STORAGE_ACCOUNT=${STATE_SA}
EOF

cat <<EOF

Done. Set these as GitHub *repository variables* (they are identifiers, not secrets):
  gh variable set AZURE_TENANT_ID           -b "${TENANT_ID}"
  gh variable set AZURE_SUBSCRIPTION_ID     -b "${SUB_ID}"
  gh variable set AZURE_INFRA_CLIENT_ID     -b "${INFRA_APP}"
  gh variable set AZURE_DEPLOY_CLIENT_ID    -b "${DEPLOY_APP}"
  gh variable set TF_VAR_deployer_object_id -b "${DEPLOY_OID}"
  gh variable set TF_VAR_cluster_admin_object_ids -b '["${ME_OID}"]'

Local terraform:  set -a; source ${OUT}; set +a; export ARM_SUBSCRIPTION_ID=\$AZURE_SUBSCRIPTION_ID ARM_TENANT_ID=\$AZURE_TENANT_ID ARM_USE_AZUREAD=true
                  terraform -chdir=infra/envs/dev init -backend-config=backend.hcl && terraform -chdir=infra/envs/dev apply
EOF
