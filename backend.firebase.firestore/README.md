# backend.firebase.firestore

Cloud Firestore for a dashboard with Firebase sign-in.

## What is in it

- **`firestore.rules`**: everything refused unless a rule allows it. Helpers
  for a client's collections: `signedIn()`, `hasRole()`, `hasAnyRole()` (from
  the token's `roles` claim, never from a document), `onlyKeys()`,
  `unchanged()`, and `stampedCreate()` / `stampedUpdate()`, which require the
  audit fields to name the signed-in person and carry the server's clock.
  A commented example shows a collection's rule. Collections go between the
  markers, which the rules test relies on.
- **`FirestorePageSource`**: the table kit's source for a collection. Pages by
  cursor, ends every order with the document id so paging never skips or
  repeats, sorts and filters only by named fields, and searches by prefix on
  a lower-cased field.
- **`DocumentReader`**: typed field access for converters. A document with a
  missing or wrong field fails as `InvalidRecord`, naming the document and the
  field, instead of rendering half a record.
- **Money** stored as `{minor, currency}`; **audit stamps**
  (`stampCreate`, `stampUpdate`) with server timestamps.
- Firestore errors mapped to sentences; a missing composite index reads as "not
  set up", with Firestore's own link left in the log for the developer.

## Tested

Unit tests on the in-memory fake (paging, sort, search, malformed records,
money), and `test_emulator/firestore/` against the Firestore emulator: the
real rules file, with test collections inserted, checked for deny-by-default,
each role helper including a malformed claim, and forged or backdated stamps.
