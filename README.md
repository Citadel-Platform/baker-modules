# baker-modules

What Citadel builds *with*. Each subdirectory is one module: frontend and
layout boilerplate, design systems, prebuilt components, middleware, backend
and infrastructure configuration.

This is the supply chain, not a client's application. A release names the
modules and versions that went into it, and the Baker Deployments tab compares
what a project is running against what this catalogue holds — so a production
release three versions behind is visible without reading two screens and
remembering.

## What a module is

A directory containing `module.json`:

```json
{
  "displayName": "Flutter shell",
  "layer": "frontend",
  "product": "Flutter",
  "version": "2.1.0",
  "summary": "Navigation, layout and theming for a Citadel client app"
}
```

`layer` is `frontend`, `middleware` or `backend`.

The version is the module's own and is the one thing here a person types. The
commit and the release date are not: `tool/index_baker_modules.dart` in
`citadel_core/platform/server` reads them from git, because a version somebody
typed beside a commit nobody can find is exactly the state the catalogue exists
to make impossible.

## Indexing

```
cd citadel_core/platform/server
dart run tool/index_baker_modules.dart --repo ../../../../baker-modules --dry-run
dart run tool/index_baker_modules.dart --repo ../../../../baker-modules --project citadel-platform
```

A directory with no `module.json` is reported as not listed rather than
skipped: a catalogue quietly missing an entry is worse than one that says which
entry it could not read.
