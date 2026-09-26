# integration.ledger

The client's accounting system behind one contract (`Ledger`), used by the
application's API and by Exigence alike: one implementation, two callers
(Feature 5.6, decision A: it runs in the client's own API service). Xero is
the first adapter.

## What it will and will not do

- **Will:** find or create a customer; create a **draft** sales invoice; read
  an invoice; list approved invoices still owed, with totals by age.
- **Will not:** approve, send, void, credit or record a payment. Those change
  what a customer sees or owes, and belong to a person or an approved
  Exigence run (5.6.6), not to this module.
- **Only its own documents:** it creates by Citadel reference and reads what
  it is asked about. There is no sync that could rewrite a client's books.

## Idempotent twice over

Every write carries a Citadel reference on the document itself (a contact's
`ContactNumber` is `citadel-<ref>`; an invoice's `Reference` is the ref), and
is looked up by it before creating; the create also carries Xero's
`Idempotency-Key`, derived from the reference, for the window in which a
retry could race the first attempt. The same request twice, whenever, makes
one document. The API route also requires the caller's own
`Idempotency-Key`.

## Connecting Xero

An administrator calls `/v1/ledger/xero/connect` and opens the link. The
state in it is 32 random bytes, stored for 10 minutes and usable once. Xero
redirects to `/v1/ledger/xero/callback`, which exchanges the code (client
credentials as HTTP Basic, as Xero's SDKs send them) and records the first
organisation authorised.

Xero's access tokens last 30 minutes; refresh tokens last 60 days unused and
**rotate** on every refresh, the old one stopping at once. So the refresh
token is kept in Secret Manager (the application may add and destroy
versions of that one secret), each new one is stored *before* it is used, a
refresh runs under a Firestore lock so two instances cannot burn each
other's token, and one that got no answer is retried with the old token
(which Xero honours for 30 minutes). A token Xero no longer accepts reads as
**not connected** and is forgotten.

`/v1/ledger/status` says **notConfigured** (no Xero app), **notConnected**,
**unreachable** or **connected**, with the organisation's name.

## Grounding

Xero's published OpenAPI description (`XeroAPI/Xero-OpenAPI`, v19, September
2026) for paths, fields, statuses, filters and `Idempotency-Key`; Xero's
Node SDK for the token and connections endpoints; Xero's guides for token
lifetimes and rotation. Filters use one condition each, as the description
shows them; the rest is filtered in code.

## Tested

Unit: amounts to and from ledger decimals, Xero's date forms, its validation
messages, request parsing (including references that could break a filter).
Emulator, against a fake Xero keeping Xero's rules: the connect link and
one-use state, rotation, two instances refreshing at once, revocation, the
same draft twice as one invoice and one contact, a refused token refreshed
once, the rate limit's wait passed on, Xero's validation message passed on,
receivables across pages. **Not yet run against a real Xero organisation**:
that needs a Xero developer app and a demo company.

## Not built yet (Feature 5.6)

AutoCount, Zoho Books and QuickBooks adapters; desktop ledgers through the
local runner; InvoiceNow; payment links; the Exigence capability's
registration and approval classes; the Console surface.
