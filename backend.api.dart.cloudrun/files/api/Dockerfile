# The API, compiled ahead of time and run from scratch as an unprivileged
# user. The Dart image's /runtime carries the C libraries, the DNS resolver
# and the CA certificates the API needs to call Google over HTTPS.
FROM dart:3.12@sha256:5ac89dbcae4327278b257920e2786df0f22c87adc630017266b67cfcceef8348 AS build
WORKDIR /api
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /api/api_server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /api/api_server /app/api_server
USER 65532:65532
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/api_server"]
