# {{baker.appTitle}}

Built by Citadel's Factory; `baker.lock.json` records what from.

## Run

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

## Check before committing

```sh
flutter analyze
flutter test
```

## Where things are

```
lib/main.dart            starts the app
lib/src/configure.dart   connects modules (sign-in, database) before the first frame
lib/src/routing/         the route table, the access guard, the navigation shell
lib/src/access/          sessions and access rules
lib/src/design/          CitadelDS v1: tokens, theme, primitives, states, dialogs
lib/src/table/           the data table kit
lib/src/money/           money and charts
lib/src/pages/           screens
```

Add a screen by adding an `AppRoute` to `lib/src/routing/routes.dart`, with
the rule for who may open it.
