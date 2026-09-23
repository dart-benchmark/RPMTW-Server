import 'package:dartdap/dartdap.dart';
import 'package:dotenv/dotenv.dart';

/// Resolves how a `/auth/user/login/ldap-strategy` request looks up the enterprise-directory
/// entry to authenticate against. Two implementations exist because a still-deployed legacy
/// on-prem directory integration (predating this project's own filter-escaping hardening)
/// builds its search filter by direct string interpolation, and cannot be swapped for the
/// current implementation without also revisiting that directory's own ACL/schema
/// configuration -- every other caller gets the current, safe strategy by default. Mirrors
/// this project's own [LoginAttemptCache]/`resolveLoginAttemptCache` dynamic-backend-selection
/// idiom (see `utilities/login_attempt_cache.dart`).
abstract class LdapAuthStrategy {
  /// Searches the enterprise directory for [username] and returns the matched entry's `mail`
  /// attribute value (used by the caller to look up the linked local `User`), or `null` if no
  /// entry matched.
  Future<String?> resolveDirectoryEmail(
      LdapConnection connection, String username);
}

/// Original on-prem directory integration, kept only for the legacy backend contract --
/// interpolates the caller-supplied username straight into the search filter text before it
/// is ever parsed.
class LegacyLdapAuthStrategy implements LdapAuthStrategy {
  @override
  Future<String?> resolveDirectoryEmail(
      LdapConnection connection, String username) async {
    // 舊版企業目錄整合：直接將使用者輸入的帳號組進過濾器字串，尚未逸出特殊字元
    // SINK: PLANTED-Dart-HR-258
    Filter filter = parseQuery('(uid=$username)');

    SearchResult result = await connection.search(
        env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);
    await for (SearchEntry entry in result.stream) {
      Set values = entry.attributes['mail']?.values ?? {};
      if (values.isNotEmpty) return values.first.toString();
    }
    return null;
  }
}

/// Current implementation: the search filter is built entirely through dartdap's typed
/// [Filter.equals] builder, which escapes every LDAP filter metacharacter in the assertion
/// value before it is ever sent to the server (see [Filter.toASN1]) -- never a hand-built
/// filter string.
class EnterpriseLdapAuthStrategy implements LdapAuthStrategy {
  @override
  Future<String?> resolveDirectoryEmail(
      LdapConnection connection, String username) async {
    // SAFE_SINK: PLANTED-Dart-HR-258-safe
    Filter filter = Filter.equals('uid', username);

    SearchResult result = await connection.search(
        env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);
    await for (SearchEntry entry in result.stream) {
      Set values = entry.attributes['mail']?.values ?? {};
      if (values.isNotEmpty) return values.first.toString();
    }
    return null;
  }
}

/// Resolves which strategy a given request should use, based on the
/// `X-RPMTW-Ldap-Backend` header a caller may send.
LdapAuthStrategy resolveLdapAuthStrategy(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyLdapAuthStrategy();
  }
  return EnterpriseLdapAuthStrategy();
}
