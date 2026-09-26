import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Removes the Firebase JS SDK's stored sign-in from this browser.
///
/// Where the SDK keeps it: the `firebaseLocalStorageDb` IndexedDB database,
/// and `firebase:authUser:*` keys when IndexedDB is unavailable.
Future<void> forgetStoredFirebaseSession() async {
  for (final web.Storage storage in <web.Storage>[
    web.window.localStorage,
    web.window.sessionStorage,
  ]) {
    final List<String> keys = <String>[
      for (int i = 0; i < storage.length; i++)
        if (storage.key(i) case final String key
            when key.startsWith('firebase:authUser:'))
          key,
    ];
    // A loop, not a tear-off: interop members cannot be torn off.
    for (final String key in keys) {
      storage.removeItem(key);
    }
  }
  final Completer<void> done = Completer<void>();
  final web.IDBOpenDBRequest request = web.window.indexedDB.deleteDatabase(
    'firebaseLocalStorageDb',
  );
  void finish(web.Event _) {
    if (!done.isCompleted) done.complete();
  }

  request
    ..onsuccess = finish.toJS
    ..onerror = finish.toJS
    ..onblocked = finish.toJS;
  await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
}
