import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Checks a webhook signed by Svix, which is how Resend signs its events.
///
/// The signature is HMAC-SHA256, base64, over `id.timestamp.body` with the
/// base64 secret after `whsec_`, and is checked against the raw bytes:
/// re-encoding a parsed body changes it and fails a valid signature.
/// [secrets] may hold several, so a rotation does not drop deliveries.
/// Returns null when genuine, else why not.
String? svixProblem({
  required List<int> rawBody,
  required String? id,
  required String? timestamp,
  required String? signatures,
  required List<String> secrets,
  required DateTime now,
  Duration tolerance = const Duration(minutes: 5),
}) {
  if (id == null || timestamp == null || signatures == null) {
    return 'missing svix headers';
  }
  final int? sentAt = int.tryParse(timestamp);
  if (sentAt == null) return 'malformed timestamp';
  final DateTime sent = DateTime.fromMillisecondsSinceEpoch(sentAt * 1000, isUtc: true);
  if (now.difference(sent).abs() > tolerance) return 'timestamp outside the window';

  final List<int> signed = <int>[...utf8.encode('$id.$timestamp.'), ...rawBody];
  final List<List<int>> offered = <List<int>>[
    for (final String entry in signatures.split(' '))
      if (entry.startsWith('v1,'))
        (() {
          try {
            return base64.decode(entry.substring(3));
          } on FormatException {
            return <int>[];
          }
        })(),
  ];
  for (final String secret in secrets) {
    final List<int> key;
    try {
      key = base64.decode(secret.startsWith('whsec_') ? secret.substring(6) : secret);
    } on FormatException {
      continue;
    }
    final List<int> expected = Hmac(sha256, key).convert(signed).bytes;
    for (final List<int> o in offered) {
      if (_equal(o, expected)) return null;
    }
  }
  return 'no signature matches';
}

/// Compares in time independent of where the bytes differ.
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
