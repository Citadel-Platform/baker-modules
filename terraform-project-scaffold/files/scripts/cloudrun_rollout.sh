#!/usr/bin/env bash
# Rolls a Cloud Run service out, back, or reports it. Shared by every service
# in the application: each service's own deploy script runs its checks, then
# calls this.
#
#   scripts/cloudrun_rollout.sh deploy   SERVICE_OUTPUT REPOSITORY_OUTPUT IMAGE CONTEXT
#   scripts/cloudrun_rollout.sh rollback SERVICE_OUTPUT
#   scripts/cloudrun_rollout.sh status   SERVICE_OUTPUT
#
# SERVICE_OUTPUT and REPOSITORY_OUTPUT name Terraform outputs (web_service,
# web_repository), so names are written down once, in infra/. Extra
# `docker build` arguments come from DOCKER_BUILD_ARGS.
#
# deploy: from a committed tree only; builds for linux/amd64 (what Cloud Run
# runs), pushes, starts a revision with NO traffic at its own tagged address,
# checks /health there (never a path ending in "z": Cloud Run reserves some
# at its front end, so /healthz never reaches the container) and that responses carry the security headers, and
# only then moves traffic. A revision that starts but cannot serve never
# reaches anyone.
set -euo pipefail

command="${1:-}"
service_output="${2:-}"
cd "$(dirname "$0")/.."

for tool in gcloud terraform git; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed." >&2; exit 69; }
done
[[ -n "$service_output" ]] || { echo "Usage: see the top of $0" >&2; exit 64; }

out() { terraform -chdir=infra output -raw "$1"; }
project="$(out project_id)"
region="$(out region)"
service="$(out "$service_output")"
gc() { gcloud --project "$project" "$@"; }

serving() {
  gc run services describe "$service" --region "$region" \
    --format='value(status.traffic[0].revisionName)'
}

case "$command" in
  status)
    echo "$service serving: $(serving)"
    gc run revisions list --service "$service" --region "$region" --limit 5
    ;;

  rollback)
    current="$(serving)"
    previous="$(gc run revisions list --service "$service" --region "$region" \
      --format='value(metadata.name)' --sort-by='~metadata.creationTimestamp' \
      | grep -v -x "$current" | head -n 1)"
    [[ -n "$previous" ]] || { echo "No earlier revision to roll back to." >&2; exit 1; }
    read -r -p "Send all of $service's traffic from $current back to $previous? [y/N] " answer
    [[ "$answer" == "y" ]] || { echo "Not changed." >&2; exit 1; }
    gc run services update-traffic "$service" --region "$region" \
      --to-revisions "$previous=100"
    ;;

  deploy)
    repository_output="${3:-}"
    image_name="${4:-}"
    context="${5:-}"
    [[ -n "$repository_output" && -n "$image_name" && -d "$context" ]] \
      || { echo "Usage: see the top of $0" >&2; exit 64; }
    command -v docker >/dev/null || { echo "docker is not installed." >&2; exit 69; }
    command -v curl >/dev/null || { echo "curl is not installed." >&2; exit 69; }
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "Uncommitted changes. Commit them, so the image can be traced to a commit." >&2
      exit 65
    fi
    commit="$(git rev-parse --short HEAD)"
    image="$(out "$repository_output")/$image_name:$commit"
    tag="c-$commit"

    # shellcheck disable=SC2086 # DOCKER_BUILD_ARGS is a list of arguments.
    docker build --platform linux/amd64 ${DOCKER_BUILD_ARGS:-} -t "$image" "$context"
    docker push "$image"

    gc run deploy "$service" --region "$region" --image "$image" \
      --no-traffic --tag "$tag"
    url="$(gc run services describe "$service" --region "$region" --format=json \
      | python3 -c "import json,sys; t=[x for x in json.load(sys.stdin)['status']['traffic'] if x.get('tag')=='$tag']; print(t[0]['url'] if t else '')")"
    [[ -n "$url" ]] || { echo "Cloud Run gave the revision no tagged address. Traffic not moved." >&2; exit 1; }

    echo "Checking $url before it takes traffic."
    curl -fsS "$url/health" >/dev/null \
      || { echo "The new revision does not answer /health. Traffic not moved." >&2; exit 1; }
    curl -sS -o /dev/null -D - "$url/health" | grep -qi '^x-content-type-options: nosniff' \
      || { echo "The new revision is missing its security headers. Traffic not moved." >&2; exit 1; }

    gc run services update-traffic "$service" --region "$region" --to-tags "$tag=100"
    echo "$service is serving $commit."
    ;;

  *)
    echo "Usage: see the top of $0" >&2
    exit 64
    ;;
esac
