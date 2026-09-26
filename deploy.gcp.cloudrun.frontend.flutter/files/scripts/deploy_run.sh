#!/usr/bin/env bash
# The web app on Cloud Run.
#
#   scripts/deploy_run.sh deploy     checks, then the shared rollout: a revision
#                                    with no traffic, checked, then traffic
#   scripts/deploy_run.sh rollback   traffic back to the revision before
#   scripts/deploy_run.sh status
#
# Build settings come from config/<CONFIG>.json (default production); they are
# compiled into public JavaScript, so never a secret.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  deploy)
    flutter analyze
    flutter test
    (cd server && dart pub get && dart analyze && dart test)
    DOCKER_BUILD_ARGS="--build-arg CONFIG=${CONFIG:-production}" \
      exec scripts/cloudrun_rollout.sh deploy web_service web_repository web .
    ;;
  rollback | status)
    exec scripts/cloudrun_rollout.sh "$1" web_service
    ;;
  *)
    echo "Usage: scripts/deploy_run.sh deploy|rollback|status" >&2
    exit 64
    ;;
esac
