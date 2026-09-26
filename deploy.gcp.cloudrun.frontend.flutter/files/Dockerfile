# The Flutter web app and the server that serves it, for Cloud Run.
#
# Three stages, and only the last is shipped: no SDK, no shell and no package
# manager in production, which is less to patch and less to break into.
# Base images are pinned by digest, so a rebuild of the same commit is the same
# image; update the digests deliberately.

# 1. The web build. Settings come from config/<CONFIG>.json and are compiled
#    into public JavaScript: never a secret.
FROM ghcr.io/cirruslabs/flutter:3.44.0@sha256:46691e311715845de03a3ba4753a475476936805b29431b1f00f1816981033f8 AS web
ARG CONFIG=production
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN dart run build_runner build --delete-conflicting-outputs \
 && flutter build web --release --dart-define-from-file=config/${CONFIG}.json

# 2. The server, compiled ahead of time to a single executable.
FROM dart:3.12@sha256:5ac89dbcae4327278b257920e2786df0f22c87adc630017266b67cfcceef8348 AS server
WORKDIR /server
COPY server/pubspec.yaml ./
RUN dart pub get
COPY server/ ./
RUN dart pub get --offline && dart compile exe bin/server.dart -o /server/web_server

# 3. What runs: the executable, the libraries it needs (the Dart image's
#    /runtime), and the web build. As an unprivileged user.
FROM scratch
COPY --from=server /runtime/ /
COPY --from=server /server/web_server /app/web_server
COPY --from=web /src/build/web /app/public
USER 65532:65532
ENV PORT=8080 PUBLIC_DIR=/app/public
EXPOSE 8080
ENTRYPOINT ["/app/web_server"]
