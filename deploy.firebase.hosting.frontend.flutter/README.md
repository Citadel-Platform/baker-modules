# deploy.firebase.hosting.frontend.flutter

Serves the Flutter web build from Firebase Hosting.

## What is in it

- **`firebase.json` hosting**, merged: `build/web` as the site, every path
  rewritten to `index.html` so deep links load the app, and on every response
  HSTS, `nosniff`, a strict referrer policy, frame denial, a permissions
  policy, `Cross-Origin-Opener-Policy: same-origin-allow-popups` (what
  Firebase's sign-in popup needs), a **report-only** content security policy,
  and `Cache-Control: no-cache`.
- **`scripts/deploy_hosting.sh`**: refuses an uncommitted tree or an
  unconfigured Firebase project; runs analyze and tests; builds with
  `--dart-define-from-file=config/<CONFIG>.json`; deploys to a 7-day preview
  channel, or to live after the operator types the project id (`--yes` for
  CI). The release message is the commit.

## Why no-cache everywhere

Flutter's web build does not hash its file names, and Hosting applies headers
by the requested path, not the rewrite target: a long cache on `/clients/42`
would pin a stale `index.html`. Revalidation is a 304 from Hosting's CDN.

## Why the policy is report-only

Flutter and Firebase load from several Google origins (CanvasKit, the
Firebase SDK, fallback fonts, the sign-in popup). An enforced policy that
missed one breaks the app for its users; a report-only one tells you. Driven
through the Hosting emulator, every origin the app loaded was allowed. Enforce
it after a real deployment shows the console clean.
