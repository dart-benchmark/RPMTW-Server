import 'package:dartdap/dartdap.dart';
import 'package:dotenv/dotenv.dart';

/// Repository-layer wrapper around the enterprise LDAP/Active-Directory server that backs the
/// "enterprise SSO" alternative login path (see [AuthHandler.authenticateEnterpriseDepartmentUser]
/// and the `/auth/user/login/ldap-department` / `/auth/admin/ldap/lookup-any` routes). This
/// mirrors this project's own `DataBase` class in spirit -- a single place that owns the
/// connection lifecycle to an external directory/store -- but talks to the configured LDAP
/// server via `dartdap` instead of MongoDB.
class LdapDirectoryService {
  Future<LdapConnection> _openServiceConnection() async {
    final LdapConnection connection = LdapConnection(
        host: env['LDAP_HOST'] ?? 'localhost',
        port: int.tryParse(env['LDAP_PORT'] ?? '') ?? Ldap.PORT_LDAP,
        bindDN: env['LDAP_BIND_DN'] ?? '',
        password: env['LDAP_BIND_PASSWORD'] ?? '');
    await connection.open();
    await connection.bind();
    return connection;
  }

  /// Authenticates a user against the enterprise directory by matching BOTH their username
  /// AND their department in a single combined filter -- some enterprise directory schemas
  /// scope `uid` uniqueness only within a department (`ou`), so a plain `(uid=...)` lookup can
  /// match the wrong entry across departments. On a match, re-binds as the matched entry's own
  /// DN to verify [password], then returns the matched entry's `mail` attribute value (used to
  /// look up the linked local `User`), or `null` if no entry matched / the password was wrong.
  Future<String?> authenticateByDepartment(
      String username, String department, String password) async {
    final LdapConnection connection = await _openServiceConnection();
    try {
      // 以 sprintf 風格的樣板組出過濾器字串，將兩個使用者輸入的欄位一併帶入
      const String filterTemplate = '(&(uid=%s)(department=%s))';
      String filterText = filterTemplate
          .replaceFirst('%s', username)
          .replaceFirst('%s', department);
      // SINK: PLANTED-Dart-HR-257
      Filter filter = parseQuery(filterText);

      SearchResult result = await connection.search(
          env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);
      await for (SearchEntry entry in result.stream) {
        try {
          await connection.bind(DN: entry.dn, password: password);
        } catch (e) {
          continue;
        }
        Set values = entry.attributes['mail']?.values ?? {};
        if (values.isNotEmpty) return values.first.toString();
      }
      return null;
    } finally {
      await connection.close();
    }
  }

  /// Safe twin of [authenticateByDepartment]: both fields are escaped (per RFC 4515, via
  /// [LdapUtil.escapeString]) before they are substituted into the filter template.
  Future<String?> authenticateByDepartmentSafe(
      String username, String department, String password) async {
    final LdapConnection connection = await _openServiceConnection();
    try {
      const String filterTemplate = '(&(uid=%s)(department=%s))';
      String filterText = filterTemplate
          .replaceFirst('%s', LdapUtil.escapeString(username))
          .replaceFirst('%s', LdapUtil.escapeString(department));
      // SAFE_SINK: PLANTED-Dart-HR-257-safe
      Filter filter = parseQuery(filterText);

      SearchResult result = await connection.search(
          env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);
      await for (SearchEntry entry in result.stream) {
        try {
          await connection.bind(DN: entry.dn, password: password);
        } catch (e) {
          continue;
        }
        Set values = entry.attributes['mail']?.values ?? {};
        if (values.isNotEmpty) return values.first.toString();
      }
      return null;
    } finally {
      await connection.close();
    }
  }

  /// Admin/moderation lookup: finds every directory entry whose `uid` matches ANY of
  /// [identifierCandidates] -- e.g. a support agent resolving which of a user's several known
  /// account-identifier aliases is currently registered in the directory. Every candidate is
  /// appended, unescaped, as its own OR'd fragment, mirroring [AuthHandler.sendAccountRecoveryDigest]'s
  /// own per-entry loop-accumulation shape (`handler/auth_handler.dart`) one layer down at the
  /// filter-text level instead of a mail-recipient list.
  Future<List<String>> lookupAnyIdentifier(
      List<dynamic> identifierCandidates) async {
    final LdapConnection connection = await _openServiceConnection();
    try {
      final StringBuffer orFragments = StringBuffer();
      for (final candidate in identifierCandidates) {
        // SINK: PLANTED-Dart-HR-259
        orFragments.write('(uid=${candidate.toString()})');
      }
      Filter filter = parseQuery('(|$orFragments)');

      SearchResult result = await connection.search(
          env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail', 'uid']);
      final List<String> matchedDns = [];
      await for (SearchEntry entry in result.stream) {
        matchedDns.add(entry.dn);
      }
      return matchedDns;
    } finally {
      await connection.close();
    }
  }

  /// Safe twin of [lookupAnyIdentifier]: every candidate is escaped before being appended to
  /// the OR'd filter fragment.
  Future<List<String>> lookupAnyIdentifierSafe(
      List<dynamic> identifierCandidates) async {
    final LdapConnection connection = await _openServiceConnection();
    try {
      final StringBuffer orFragments = StringBuffer();
      for (final candidate in identifierCandidates) {
        final String safeCandidate =
            LdapUtil.escapeString(candidate.toString());
        // SAFE_SINK: PLANTED-Dart-HR-259-safe
        orFragments.write('(uid=$safeCandidate)');
      }
      Filter filter = parseQuery('(|$orFragments)');

      SearchResult result = await connection.search(
          env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail', 'uid']);
      final List<String> matchedDns = [];
      await for (SearchEntry entry in result.stream) {
        matchedDns.add(entry.dn);
      }
      return matchedDns;
    } finally {
      await connection.close();
    }
  }
}
