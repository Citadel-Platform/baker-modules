# frontend.flutter.dashboard

The starting point for a client dashboard: a Flutter application that runs on
the web, and on iOS and Android when asked for.

## What is in it

- **CitadelDS v1** (`lib/src/design/`): tokens in light and dark sets, the
  theme built from them, the bundled Cairo and JetBrains Mono faces (SIL OFL),
  and the primitives screens are made of: page, panel, status badge,
  confirmation and detail dialogs. Text colours are tested to clear 4.5:1
  contrast on every surface in both modes.
- **The four states** (`states.dart`): loading, empty, failed (with Retry when
  retrying can help) and not configured, each distinct. `AsyncView` renders a
  Riverpod value as one of them, and keeps data on screen during a refresh.
- **Access control** (`lib/src/access/`, `lib/src/routing/`): every route
  states who may open it (public, any signed-in person, or a set of roles). The
  guard denies by default, waits while the session is unknown, treats a
  session that failed to load as signed out, and returns people to where they
  were going after sign-in, following only local paths. Roles come from the
  sign-in token's claims, set by a server. A test sweeps the route table for
  public pages nobody meant to make public.
- **Responsive navigation**: bottom bar, rail or extended rail by window size
  (Material 3's size classes); only the pages a person may open are shown.
- **Data table kit** (`lib/src/table/`): cursor pagination from any
  `PageSource`, fixed-height rows built only on screen, debounced search,
  sortable columns, search/sort/filters kept in the URL and validated against
  an allow-list, stale responses discarded, bulk actions confirmed with their
  count and whether they can be undone.
- **Money** (`lib/src/money/`): integer minor units with an ISO 4217 code, exact
  decimal parsing, no mixing of currencies, allocation that never loses a
  cent, half-to-even rounding, locale formatting, and a bar chart on a
  round-numbered axis with a screen-reader summary.

## Inputs

`packageName`, `appTitle`, and `platforms` (`web`, or `web,ios,android`).

## Wiring other modules in

`lib/src/configure.dart` returns the Riverpod overrides that connect modules
(sign-in, database) before the first frame. Each module's next steps say what
to add there.

## Why `test/widget_test.dart`

`flutter create` writes a default `test/widget_test.dart` for an app class that
does not exist here, unless the file is already present. This module ships
that file, holding the app's own tests, so the platform folders can be created
over a generated tree without breaking `flutter analyze`.
