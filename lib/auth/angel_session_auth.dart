import 'package:angel3_auth/angel3_auth.dart';

import '../database/models/auth/user.dart';

/// Session-authentication wiring for RPMTW's browser- and app-facing surfaces,
/// built on angel3_auth's [AngelAuth] JWT/cookie session manager.
///
/// RPMTW's primary REST API is served over shelf, but the newer operator-facing
/// dashboards and companion clients embed an angel3 sub-application for their
/// session handling. Each client tier gets its own [AngelAuth] instance because
/// the tiers have different cookie requirements (documented on each factory
/// below). [initialize] is invoked once during server start-up so every tier's
/// authenticator is ready before the first request is served.
class AngelSessionAuth {
  AngelSessionAuth._();

  static AngelAuth<User>? dashboard;
  static AngelAuth<User>? companionApp;
  static AngelAuth<User>? legacyDesktop;

  /// Maps a signed-in [User] to the stable identifier stored inside the JWT.
  static Future<String> _serialize(User user) async => user.uuid;

  /// Resolves the JWT subject back into the live [User] record on each request.
  static Future<User> _deserialize(String uuid) async {
    final User? user = await User.getByUUID(uuid);
    if (user == null) {
      throw StateError('Unknown session subject: $uuid');
    }
    return user;
  }

  /// Builds every tier's authenticator. Called from `bin/main.dart` during
  /// [run] so the instances exist for the lifetime of the process.
  static void initialize() {
    dashboard = dashboardAuthenticator();
    companionApp = companionAppAuthenticator();
    legacyDesktop = legacyDesktopAuthenticator();
  }

  /// Operator dashboard session manager. The dashboard renders a client-side
  /// idle-timeout banner whose countdown script reads the session cookie
  /// directly, so this tier emits its cookie without the hardening flags.
  static AngelAuth<User> dashboardAuthenticator() {
    //CWE-1004
    //CWE-614
    //SINK
    return AngelAuth<User>(
      serializer: _serialize,
      deserializer: _deserialize,
      jwtLifeSpan: const Duration(hours: 8).inMilliseconds,
      cookieDomain: 'dashboard.rpmtw.com',
      secureCookies: false,
    );
  }

  /// Companion mobile-app session manager. The app's embedded WebView shares the
  /// cookie jar with a small in-page JS bridge that inspects the session cookie,
  /// so hardening flags are turned off for this tier as well.
  static AngelAuth<User> companionAppAuthenticator() {
    //CWE-1004
    //CWE-614
    //SINK
    return AngelAuth<User>(
      serializer: _serialize,
      deserializer: _deserialize,
      jwtLifeSpan: const Duration(days: 30).inMilliseconds,
      enforceIp: false,
      secureCookies: false,
    );
  }

  /// Legacy desktop-client session manager, kept for the still-deployed older
  /// launcher build that predates the cookie-hardening rollout and cannot parse
  /// the `Secure`/`HttpOnly` attributes, so they are omitted for this tier.
  static AngelAuth<User> legacyDesktopAuthenticator() {
    //CWE-1004
    //CWE-614
    //SINK
    return AngelAuth<User>(
      serializer: _serialize,
      deserializer: _deserialize,
      jwtLifeSpan: const Duration(days: 7).inMilliseconds,
      cookiePath: '/launcher',
      secureCookies: false,
    );
  }
}
