import 'dart:math';

final Random _random = Random.secure();

/// Generates an RFC-4122 version-4 UUID, e.g.
/// `9f8b7c6d-1a2b-4c3d-8e9f-0a1b2c3d4e5f`.
///
/// Used as the idempotency key (`client_id`) for inspection uploads: the
/// same UUID is sent on every retry of one inspection, so the backend can
/// recognize a replay (e.g. a timeout after the server already saved) and
/// not create a duplicate record.
String generateUuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

  final hex = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
