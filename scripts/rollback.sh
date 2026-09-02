#!/usr/bin/env bash
# Manual rollback of the webapp Helm release.
#   scripts/rollback.sh <env> [revision]     (no revision = previous one)
# Preferred path is re-running the Deploy workflow with the last-known-good image tag
# (auditable, goes through the environment gate); this script is the break-glass option.
set -euo pipefail
ENV="${1:?usage: rollback.sh <dev|prod> [revision]}"
REV="${2:-}"
RELEASE=webapp

echo "== current history"
helm -n "$ENV" history "$RELEASE" --max 10

echo "== rolling back ${REV:-to previous revision}"
helm -n "$ENV" rollback "$RELEASE" $REV --wait --timeout 3m

echo "== verifying"
kubectl -n "$ENV" rollout status deploy/"$RELEASE" --timeout=120s
ip=$(kubectl -n "$ENV" get ingress "$RELEASE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -fsS "http://${ip}/" && echo
helm -n "$ENV" history "$RELEASE" --max 3
