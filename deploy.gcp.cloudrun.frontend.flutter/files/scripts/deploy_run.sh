#!/usr/bin/env bash
# Builds the web app into an image and rolls it out on Cloud Run.
#
#   scripts/deploy_run.sh deploy       build, push, start a revision with no
#                                      traffic, check it, then send traffic to it
#   scripts/deploy_run.sh rollback     send all traffic back to the revision
#                                      that was serving before
#   scripts/deploy_run.sh status       which revision serves, and the ones before
#
# The service, registry and secrets are Terraform's (infra/web.tf); run
# `terraform apply` once before the first deploy. Names come from Terraform's
# outputs, so they are written down in one place.
#
# A new revision gets no traffic until it has answered on its own tagged
# address. A build that starts but cannot serve never reaches anyone.
set -euo pipefail

command="${1:-}"
cd "$(dirname "$0")/.."

for tool in docker gcloud terraform git curl; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed." >&2; exit 69; }
done

out() { terraform -chdir=infra output -raw "$1"; }
project="$(out project_id)"
region="$(out region)"
service="$(out web_service)"
repository="$(out web_repository)"
gc() { gcloud --project "$project" "$@"; }

serving() {
  gc run services describe "$service" --region "$region" \
    --format='value(status.traffic[0].revisionName)'
}

case "$command" in
  status)
    echo "Serving: $(serving)"
    gc run revisions list --service "$service" --region "$region" --limit 5
    ;;

  rollback)
    current="$(serving)"
    previous="$(gc run revisions list --service "$service" --region "$region" \
      --format='value(metadata.name)' --sort-by='~metadata.creationTimestamp' \
      | grep -v -x "$current" | head -n 1)"
    if [[ -z "$previous" ]]; then
      echo "No earlier revision to roll back to." >&2
      exit 1
    fi
    read -r -p "Send all traffic from $current back to $previous? [y/N] " answer
    [[ "$answer" == "y" ]] || { echo "Not changed." >&2; exit 1; }
    gc run services update-traffic "$service" --region "$region" \
      --to-revisions "$previous=100"
    ;;

  deploy)
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "Uncommitted changes. Commit them, so the image can be traced to a commit." >&2
      exit 65
    fi
    commit="$(git rev-parse --short HEAD)"
    image="$repository/web:$commit"
    tag="c-$commit"

    flutter analyze
    flutter test
    (cd server && dart pub get && dart analyze && dart test)

    # Cloud Run runs linux/amd64, whatever this machine is.
    docker build --platform linux/amd64 --build-arg CONFIG="${CONFIG:-production}" -t "$image" .
    docker push "$image"

    gc run deploy "$service" --region "$region" --image "$image" \
      --no-traffic --tag "$tag"
    url="$(gc run services describe "$service" --region "$region" --format=json \
      | python3 -c "import json,sys; t=[x for x in json.load(sys.stdin)['status']['traffic'] if x.get('tag')=='$tag']; print(t[0]['url'] if t else '')")"
    if [[ -z "$url" ]]; then
      echo "Cloud Run gave the revision no tagged address. Traffic not moved." >&2
      exit 1
    fi

    echo "Checking $url before it takes traffic."
    curl -fsS "$url/healthz" >/dev/null
    curl -fsS -o /dev/null -D - "$url/" | grep -qi '^x-content-type-options: nosniff' \
      || { echo "The new revision is not serving the app with its headers. Traffic not moved." >&2; exit 1; }

    gc run services update-traffic "$service" --region "$region" --to-tags "$tag=100"
    echo "Serving $commit."
    ;;

  *)
    echo "Usage: scripts/deploy_run.sh deploy|rollback|status" >&2
    exit 64
    ;;
esac
