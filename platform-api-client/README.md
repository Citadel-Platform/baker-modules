# Platform API client

One typed client for the Platform API: workspace, projects, Palisade,
ARM, Conduit, Exigence, Manifold and Baker.

Every failure comes back as something describable rather than as an HTTP status
a caller has to interpret twice — a refusal names the permission that was
missing, and an outage says it is an outage, because a Console that cannot tell
those apart sends somebody to the wrong page.
