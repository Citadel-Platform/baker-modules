# backend.mail.transactional

Transactional mail from the API (`backend.api.dart.cloudrun`), through Resend.

## How a message travels

1. **Outbox.** A route calls `enqueue(message)` and puts the returned write in
   the same Firestore commit as its own change. The message exists exactly
   when the change does: never sent for a change that rolled back, never lost
   for one that happened. `sendNow` does this for a route with nothing else to
   write.
2. **Dispatch.** After the commit, `dispatch(id)` queues a Cloud Task named
   after the message, so dispatching twice queues once.
3. **Send.** The task calls `/internal/mail/send` with an OIDC token for the
   internal caller. Suppressed recipients are dropped (all suppressed: nothing
   is sent); attachments are fetched from Cloud Storage now, never stored in
   the outbox, and capped; the message goes to Resend with its id as Resend's
   `Idempotency-Key`, so a task Cloud Tasks runs twice sends once.
   - Rate limits, outages, no answer, a concurrent attempt: a 503, and Cloud
     Tasks retries with backoff.
   - A refusal (an unverified domain, a bad key, invalid content): the message
     is `failed`, with Resend's reason.
4. **Sweep** (Cloud Scheduler, every 5 minutes): dispatches any message still
   queued after its grace period (its task was never created), and removes
   bodies and attachments once past retention (30 days by default). Who was
   written to, when, and what became of it are kept.
5. **Delivery events.** Resend's webhook (`/webhooks/mail`) is checked against
   its Svix signature (raw bytes, a 5-minute window, several secrets during a
   rotation). Messages move forward only: a late "delivered" never overwrites
   a bounce. Bounces, complaints and Resend's own suppressions add the address
   to the suppression list.

## Admin

With the `admin` role: `GET /v1/mail/outbox?state=failed` (never bodies),
`POST /v1/mail/outbox/{id}/retry` (after fixing the cause),
`GET /v1/mail/suppressions`, `DELETE /v1/mail/suppressions/{id}`.

## Not included

- An SMTP transport. `MailTransport` is the seam; only Resend is built.
- A check of the sending domain before sending. It would need a Resend key
  with account access; a sending-only key is used instead, and Resend's own
  refusal of an unverified domain is recorded as the failure reason.

## Tested

Unit: message validation (header injection, recipients, attachment types),
HTML escaping, the Resend request and every outcome, Svix against Svix's own
published example. Emulator: the atomic commit, send-once, retry and refusal,
suppression, the sweep and purge, forward-only events, forged events, and the
webhook route. Not yet sent through a real Resend account from this module.
