#!/usr/bin/env bash
# Sets and retires the values of the application's secrets.
#
#   scripts/secrets.sh list                    the secrets, and their versions
#   scripts/secrets.sh set NAME                reads the value from standard input
#   scripts/secrets.sh disable NAME VERSION    stops a version being read
#   scripts/secrets.sh destroy NAME VERSION    deletes a version's value for good
#
#   printf '%s' "$VALUE" | scripts/secrets.sh set STRIPE_KEY
#   scripts/secrets.sh set STRIPE_KEY < key.txt
#
# NAME is an environment variable name listed in app_secrets (infra/variables.tf); a secret
# that is not listed there does not exist, and is refused. Terraform creates
# the secret; this only adds and retires its values, which never pass through
# Terraform's state, a command line or shell history.
#
# Services read "latest" when an instance starts. After `set`, deploy (or
# wait for new instances) for it to be used. Disable an old version once the
# new one is serving; destroy only when it can never be needed again.
set -euo pipefail

command="${1:-}"
name="${2:-}"
version="${3:-}"
cd "$(dirname "$0")/.."

out() { terraform -chdir=infra output -raw "$1"; }
project="$(out project_id)"
gc() { gcloud --project "$project" "$@"; }

secret_id() {
  terraform -chdir=infra output -json app_secret_ids | python3 -c "
import json, sys
ids = json.load(sys.stdin)
name = sys.argv[1]
if name not in ids:
    sys.exit('No secret ' + repr(name) + '. Declared: ' + (', '.join(sorted(ids)) or 'none') + '. Add it to app_secrets and apply.')
print(ids[name])" "$1"
}

case "$command" in
  list)
    terraform -chdir=infra output -json app_secret_ids | python3 -c "
import json, sys
for name, sid in sorted(json.load(sys.stdin).items()):
    print(name, sid)" | while read -r n id; do
      echo "$n ($id)"
      gc secrets versions list "$id" --format='table(name,state,createTime)' || true
    done
    ;;
  set)
    [[ -n "$name" ]] || { echo "Usage: scripts/secrets.sh set NAME < value" >&2; exit 64; }
    id="$(secret_id "$name")"
    if [[ -t 0 ]]; then
      echo "Reading the value from standard input; pipe it in rather than typing." >&2
      exit 64
    fi
    gc secrets versions add "$id" --data-file=-
    ;;
  disable)
    [[ -n "$name" && -n "$version" ]] || { echo "Usage: scripts/secrets.sh disable NAME VERSION" >&2; exit 64; }
    gc secrets versions disable "$version" --secret "$(secret_id "$name")"
    ;;
  destroy)
    [[ -n "$name" && -n "$version" ]] || { echo "Usage: scripts/secrets.sh destroy NAME VERSION" >&2; exit 64; }
    id="$(secret_id "$name")"
    read -r -p "Destroy version $version of $id? It cannot be recovered. [y/N] " answer
    [[ "$answer" == "y" ]] || { echo "Not destroyed." >&2; exit 1; }
    gc secrets versions destroy "$version" --secret "$id" --quiet
    ;;
  *)
    echo "Usage: scripts/secrets.sh list|set|disable|destroy" >&2
    exit 64
    ;;
esac
