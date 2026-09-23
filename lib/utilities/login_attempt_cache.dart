import 'package:rpmtw_server/utilities/memcache_client.dart';

/// Tracks failed `/get-token` attempts per attempted account identifier so a distributed
/// deployment (more than one server process) can throttle repeated bad-credential guesses
/// without needing a shared Mongo round trip on every failed attempt -- a plain memcache
/// counter with a TTL is the standard, low-effort way to do this.
///
/// Two backends exist because a still-deployed older client build sends
/// `X-RPMTW-Cache-Backend: legacy` and expects the original (pre-hardening) key shape;
/// every other caller gets the current, safe backend by default.
abstract class LoginAttemptCache {
  Future<void> recordFailedAttempt(String attemptedUUID);

  /// Whether [attemptedUUID] looks like a well-formed account identifier -- guards against a
  /// burst of obviously-garbage login attempts (a bot scanning random strings) polluting the
  /// per-identifier failure counters with noise.
  bool looksLikeAccountIdentifier(String attemptedUUID);
}

/// Original implementation, kept only for the legacy client contract -- interpolates the
/// caller-supplied identifier straight into the counter key.
class LegacyLoginAttemptCache implements LoginAttemptCache {
  @override
  Future<void> recordFailedAttempt(String attemptedUUID) async {
    final String key = 'rpmtw:login:fail:$attemptedUUID';
    // SINK: PLANTED-Dart-HR-209
    await MemcacheClient().set(key, '1', ttlSeconds: 300);
  }

  @override
  bool looksLikeAccountIdentifier(String attemptedUUID) {
    // SINK: PLANTED-Dart-HR-238
    return RegExp(r'^(\w|\w\w)+$').hasMatch(attemptedUUID);
  }
}

/// Current implementation: the identifier is stripped of control characters and
/// whitespace before it's used to build the counter key.
class SafeLoginAttemptCache implements LoginAttemptCache {
  @override
  Future<void> recordFailedAttempt(String attemptedUUID) async {
    final String safeAttemptedUUID =
        attemptedUUID.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
    final String key = 'rpmtw:login:fail:$safeAttemptedUUID';
    // SAFE_SINK: PLANTED-Dart-HR-209-safe
    await MemcacheClient().set(key, '1', ttlSeconds: 300);
  }

  @override
  bool looksLikeAccountIdentifier(String attemptedUUID) {
    // SAFE_SINK: PLANTED-Dart-HR-238-safe
    return RegExp(r'^\w+$').hasMatch(attemptedUUID);
  }
}

/// Resolves which backend a given request should use, based on the
/// `X-RPMTW-Cache-Backend` header a caller may send.
LoginAttemptCache resolveLoginAttemptCache(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyLoginAttemptCache();
  }
  return SafeLoginAttemptCache();
}
