import 'package:cloud_firestore/cloud_firestore.dart';

/// Fields recording who created a record and when, for a new document.
///
/// The time is the server's (`request.time` in the rules), not the device's,
/// which can be wrong or set back. `firestore.rules`' `stampedCreate()`
/// refuses a write whose stamps do not match the signed-in person and the
/// server clock.
Map<String, Object> stampCreate(String uid) => <String, Object>{
  'createdBy': uid,
  'createdAt': FieldValue.serverTimestamp(),
  'updatedBy': uid,
  'updatedAt': FieldValue.serverTimestamp(),
};

/// Fields recording who last changed a record and when.
Map<String, Object> stampUpdate(String uid) => <String, Object>{
  'updatedBy': uid,
  'updatedAt': FieldValue.serverTimestamp(),
};
