#!/usr/bin/env bash
# The API on Cloud Run.
#
#   scripts/deploy_api.sh deploy     tests, then the shared rollout
#   scripts/deploy_api.sh rollback   traffic back to the revision before
#   scripts/deploy_api.sh status
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  deploy)
    # Tasks call the API at the address Terraform computed; if Cloud Run gave
    # the service another, every queued task would fail. Checked, not assumed.
    actual="$(terraform -chdir=infra output -raw api_url)"
    expected="$(terraform -chdir=infra output -raw api_url_deterministic)"
    if [[ "$actual" != "$expected" ]]; then
      echo "The API is at $actual, but tasks are told $expected. Fix api_url in infra/api.tf first." >&2
      exit 1
    fi
    (cd api && dart pub get && dart analyze && dart test)
    exec scripts/cloudrun_rollout.sh deploy api_service api_repository api api
    ;;
  rollback | status)
    exec scripts/cloudrun_rollout.sh "$1" api_service
    ;;
  *)
    echo "Usage: scripts/deploy_api.sh deploy|rollback|status" >&2
    exit 64
    ;;
esac
