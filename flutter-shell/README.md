# Flutter shell

The frame every Citadel client app is built inside: a shell with a
navigation rail, a top bar, routed destinations and the theme wired to the
design system. It owns the parts of an app that are the same every time, so a
build starts at the screens rather than at the scaffolding.

Deliberately not included: anything about a particular client's domain. A shell
that knew what a customer record looked like would have to be forked per client,
and a forked module is not a module.
