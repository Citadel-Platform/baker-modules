#!/usr/bin/env bash
# Builds the web app and deploys it to Firebase Hosting.
#
#   scripts/deploy_hosting.sh preview          a preview channel, expires in 7 days
#   scripts/deploy_hosting.sh live             the live site, after confirming
#   scripts/deploy_hosting.sh live --yes       the live site, for CI
#
# Preview first, always: a channel is a real deployment at its own address,
# on the same project, so what goes live is what was looked at.
#
# Build settings come from config/<CONFIG>.json (default: production), passed
# with --dart-define-from-file. They are compiled into public JavaScript, so
# they must never hold a secret.
#
# To undo a live release: Firebase console > Hosting > Release history >
# Roll back. It restores the previous version without a rebuild.
set -euo pipefail

target="${1:-}"
confirm="${2:-}"
config="${CONFIG:-production}"
project="{{baker.firebaseProjectId}}"

if [[ "$target" != "preview" && "$target" != "live" ]]; then
  echo "Usage: scripts/deploy_hosting.sh preview|live [--yes]" >&2
  exit 64
fi

for tool in flutter firebase git; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed." >&2; exit 69; }
done

cd "$(dirname "$0")/.."

if [[ ! -f "config/$config.json" ]]; then
  echo "No config/$config.json." >&2
  exit 66
fi

# What is deployed is what is committed: the release message names the commit.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes. Commit them, so the release can be traced to a commit." >&2
  exit 65
fi
commit="$(git rev-parse --short HEAD)"

if grep -q "throw UnsupportedError" lib/firebase_options.dart 2>/dev/null; then
  echo "No Firebase project configured. Run: flutterfire configure --project=$project" >&2
  exit 78
fi

flutter analyze
flutter test
flutter build web --release --dart-define-from-file="config/$config.json"

if [[ "$target" == "preview" ]]; then
  firebase hosting:channel:deploy "preview-$commit" --expires 7d --project "$project"
  exit 0
fi

if [[ "$confirm" != "--yes" ]]; then
  read -r -p "Deploy $commit to the LIVE site of $project? Type the project id: " answer
  if [[ "$answer" != "$project" ]]; then
    echo "Not deployed." >&2
    exit 1
  fi
fi
firebase deploy --only hosting --project "$project" --message "$commit"
