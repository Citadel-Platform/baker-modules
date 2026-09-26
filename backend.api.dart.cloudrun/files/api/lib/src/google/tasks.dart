import 'dart:convert';

import 'package:googleapis/cloudtasks/v2.dart' as ct;

/// Work the API hands to itself, later and reliably: each task is an
/// authenticated POST back to an internal route, retried by Cloud Tasks with
/// backoff until the route answers 2xx.
abstract interface class TaskQueue {
  /// Queues a POST of [body] to [path] on the API. [name] makes this safe to
  /// call twice: a second task with the same name is refused by Cloud Tasks
  /// and treated here as already queued.
  Future<void> enqueue({
    required String name,
    required String path,
    required Map<String, Object?> body,
    DateTime? notBefore,
  });
}

class CloudTasksQueue implements TaskQueue {
  CloudTasksQueue(
    this.api, {
    required this.queue,
    required this.apiUrl,
    required this.caller,
    required this.audience,
  });

  final ct.CloudTasksApi api;

  /// `projects/P/locations/L/queues/Q`.
  final String queue;

  /// The API's own address, which the task calls.
  final String apiUrl;

  /// The service account the task's token is for, and its audience: what
  /// `ApiAccess.service` checks on the receiving route.
  final String caller;
  final String audience;

  @override
  Future<void> enqueue({
    required String name,
    required String path,
    required Map<String, Object?> body,
    DateTime? notBefore,
  }) async {
    try {
      await api.projects.locations.queues.tasks.create(
        ct.CreateTaskRequest(
          task: ct.Task(
            name: '$queue/tasks/$name',
            scheduleTime: notBefore?.toUtc().toIso8601String(),
            httpRequest: ct.HttpRequest(
              httpMethod: 'POST',
              url: '$apiUrl$path',
              headers: <String, String>{'content-type': 'application/json'},
              // Base64 on the wire, as the API defines it.
              body: base64.encode(utf8.encode(jsonEncode(body))),
              oidcToken: ct.OidcToken(
                serviceAccountEmail: caller,
                audience: audience,
              ),
            ),
          ),
        ),
        queue,
      );
    } on ct.DetailedApiRequestError catch (e) {
      // Already queued under this name (or recently run): that is the point
      // of naming it.
      if (e.status == 409) return;
      rethrow;
    }
  }
}

/// For tests: records what would have been queued.
class MemoryTaskQueue implements TaskQueue {
  final List<({String name, String path, Map<String, Object?> body})> queued =
      <({String name, String path, Map<String, Object?> body})>[];

  @override
  Future<void> enqueue({
    required String name,
    required String path,
    required Map<String, Object?> body,
    DateTime? notBefore,
  }) async {
    if (queued.any(
      (({String name, String path, Map<String, Object?> body}) t) =>
          t.name == name,
    )) {
      return;
    }
    queued.add((name: name, path: path, body: body));
  }
}
