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
