# backend.api.dart.cloudrun

The application's API, in Dart, on Cloud Run. A separate package in `api/`.

## The pipeline, in order

1. **Request id**: Cloud Run's trace id, or a random one; returned as
   `x-request-id`, logged with every line, and in every error body.
2. **Log**: one JSON line per request in Cloud Logging's format. Paths only:
   query strings and headers can carry tokens.
3. **Headers**: `nosniff`, `no-store`, a CSP of `default-src 'none'`, no
   referrer, HSTS. Nothing an API returns is a page.
4. **CORS**: exact listed origins only, never a wildcard; preflights answered
   here and refused for anyone else.
5. **Problems**: every error is RFC 9457 `application/problem+json` with a
   stable `code`; anything unexpected is logged in full and answered with
   only the request id.
6. **Body cap**: counted on the stream, so a missing or false Content-Length
   does not get past it.
7. **Route, access, idempotency**, below.

## Who may call a route

Every `ApiRoute` states `access`; there is no default, and an unmatched path
is a 404 (or a 405 naming the methods it does have).

- `public()`: health checks, and webhooks that verify their own signatures.
- `signedIn()` / `roles({...})`: a Firebase ID token, verified as Firebase
  documents for third-party libraries: RS256 only (an HS256 token "signed"
  with the public key, and unsigned tokens, are refused), a known key id,
  the signature, expiry, issued-at and auth time (a minute of skew), audience,
  issuer and subject. Google's certificates are cached per `Cache-Control`,
  with one early refetch a minute for an unknown key id (rotation). Role
  routes also ask Firebase whether the sign-in was **revoked** or the account
  disabled (`accounts:lookup`, cached 30 s); `signedIn(checkRevoked: true)`
  does the same for others.
- `service(email)`: Google-signed OIDC tokens from Cloud Tasks or Cloud
  Scheduler, for an agreed audience and a verified service-account email.

## Idempotency

A route marked `idempotent` requires an `Idempotency-Key`. The first request
claims a Firestore record with a create-only write (exactly one of any number
of concurrent claims wins); a repeat gets the first answer back
(`idempotent-replayed: true`); the same key with a different body is 422; a
repeat while the first is running is 409 with `Retry-After`; a crash or 5xx
releases the claim so the client can retry; a claim abandoned for 2 minutes
is taken over by a conditional write, once. Records expire through a TTL
policy. Keys are per person and per route.

## Contract

`openapi.yaml` describes every route. `test/openapi_test.dart` fails if a
route is served but not described, or described but not served, or if a
route's security differs between the two.

## Infrastructure

`infra/api.tf` on the scaffold: registry, service (scale to zero, ceiling,
startup probe, `deletion_protection`), `roles/datastore.user` and
`roles/firebaseauth.viewer` for the application's identity and nothing wider,
a separate `internal` service account for Cloud Tasks and Scheduler, the TTL
policy, the application secrets named in `api_secret_env`. The image is
compiled ahead of time and runs `FROM scratch` as uid 65532 (12.8 MB), with
the CA certificates it needs to call Google. `scripts/deploy_api.sh` runs the
tests, then the scaffold's shared rollout.

## Tested

28 unit tests against real RS256 keys made in memory (nothing stored), the
pipeline end to end in memory, and the contract; 8 against the Firestore and
Auth emulators (claim races, takeover, TTL field, disabled, revoked and
deleted accounts); the image run against the emulators. Not yet run against
Google Cloud.
