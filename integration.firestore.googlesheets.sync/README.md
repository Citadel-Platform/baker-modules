# integration.firestore.googlesheets.sync

Two-way sync between Firestore collections and Google Sheets tabs, for
clients whose staff still work in spreadsheets. Needs the API module.

## The rules it keeps

- **Firestore is the source of truth.** The sheet is a view people may edit,
  never a second database.
- **App → sheet:** a Firestore trigger (Eventarc) per collection calls the
  API, which reads the document path from the event's subject and queues a
  task. Changes within 5 seconds share a task, and the task writes the
  document's *current* state, so duplicate or out-of-order events cannot
  leave a stale row. A short per-document lock (taken over if stale) stops
  two syncs appending the same new row; a duplicate that slips through is
  marked on its row.
- **Sheet → app:** an installable edit trigger in Apps Script posts only the
  changed cells, signed with HMAC-SHA256 over `timestamp.nonce.body`, within
  5 minutes, each nonce once. Each edit applies only if the field still holds
  what the sheet last showed (its hash in `_hashes`), and the write is
  conditional on the document not changing meanwhile. Otherwise the row's
  `_status` says **conflict** and nothing is overwritten. Invalid values and
  read-only columns are refused and named. Writes made through the API do not
  fire the trigger, so nothing loops.
- **Formula-safe:** values are written RAW; a stored `=IMPORTXML(…)` shows as
  text.
- **Rows are created and deleted in the app.** A row typed into the sheet, or
  a document deleted in the app, is marked, never guessed at.
- **Nightly reconcile** (Cloud Scheduler) queues a sync for any row that is
  missing or stale, marks rows whose document is gone, and reports mappings
  whose collection has no trigger.

## Configuration

`api/lib/sheets/sheets_config.dart` maps each collection to a spreadsheet tab
with typed columns (text, whole number, date, TRUE/FALSE, money in a set
currency) and which are editable. Empty by default. The same collections go
in `infra/app.auto.tfvars.json` as `api_env.SHEETS_COLLECTIONS`, which
creates their triggers.

The API reaches Sheets as the application's service account (share the
spreadsheet with it). On Cloud Run the token is requested with the
`spreadsheets` scope, which the default token lacks.

## Tested

Unit: cell codec, formula text, hashing, the row layout. Emulator (Firestore
real, sheet in memory): coalesced change events, new/updated/deleted/
duplicate rows, the lock and its takeover, applied edits, conflicts, invalid
and read-only edits, forged, stale and replayed edits, reconcile, and an
Apps-Script-style signature made independently with Node's crypto. Not yet
run against a real spreadsheet or Eventarc.
