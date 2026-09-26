# deploy.gcp.cloudrun.frontend.flutter

Serves the Flutter web app from Cloud Run, behind Firebase Hosting, for a
site that needs to run code or hold a secret. For a static dashboard that
talks to Firestore directly, `deploy.firebase.hosting.frontend.flutter` is
simpler and cheaper; the two cannot share a recipe.

## What is in it

- **`Dockerfile`**, three stages, base images pinned by digest: Flutter builds
  the web app, the Dart image compiles the server ahead of time, and the
  result runs `FROM scratch` as uid 65532: no SDK, shell or package manager
  in production. About 54 MB.
- **`server/`**, its own Dart package: `shelf` serving the build with the SPA
  fallback (a path without an extension is a page of the app; a missing file
  is a real 404), the same security headers as the Hosting module, gzip for
  text, `/healthz`, one JSON log line per request in Cloud Logging's format
  (paths only, never query strings), GET/HEAD only, and a clean exit on
  SIGTERM. Server-side routes go in `routes()` in `bin/server.dart`.
- **`infra/web.tf`**, on the Terraform scaffold: an Artifact Registry
  repository keeping the last 20 images (what a rollback deploys), the Cloud
  Run service (scale to zero, a ceiling on instances, startup probe,
  `deletion_protection`), public invocation for Hosting's rewrite, and the
  application secrets named in `web_env_secrets`, passed to the server as
  environment variables (the secrets themselves are the scaffold's).
  Terraform never holds a secret's value. Every resource labelled.
- **`scripts/deploy_run.sh`**: from a clean, tested commit, builds for
  linux/amd64, pushes, starts a revision with **no traffic** at a tagged
  address, checks it serves with its headers, then moves traffic. `rollback`
  returns traffic to the previous revision; `status` shows them.
- Secrets are set with the scaffold's `scripts/secrets.sh`, and the rollout
  is the scaffold's `scripts/cloudrun_rollout.sh`, shared with the API.

## Tested

Server unit tests (headers, fallback, traversal, methods, gzip, health), and
the image built and run locally. Terraform passes `validate` in Factory's
clean-build test. Not yet run against Google Cloud: see the operator guide's
known limits.
