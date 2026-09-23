import 'dart:io';

import 'package:shelf/shelf.dart';

/// Resolves which "keep me signed in" session-cookie construction a login route should use,
/// based on the `X-RPMTW-Cookie-Backend` header a caller may send -- mirrors this project's
/// own `resolveLoginAttemptCache` (`login_attempt_cache.dart`) and
/// `authenticateWithLdapStrategy` (`auth_handler.dart`) header-dispatch idiom.
///
/// Two backends exist for the same reason as those: a still-deployed older client build
/// sends `X-RPMTW-Cookie-Backend: legacy` and expects the original (pre-hardening) cookie
/// shape; every other caller gets the current, hardened backend by default.
abstract class SessionCookiePolicy {
  Response attach(Response response, String token);
}

/// Original implementation, kept only for the legacy client contract -- the cookie is never
/// marked `Secure`.
class LegacySessionCookiePolicy implements SessionCookiePolicy {
  @override
  Response attach(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_policy_session', token)
      ..httpOnly = true;
    // SINK: PLANTED-Dart-HR-628
    return response.change(headers: {'set-cookie': cookie.toString()});
  }
}

/// Current implementation: the cookie is also marked `Secure`.
class HardenedSessionCookiePolicy implements SessionCookiePolicy {
  @override
  Response attach(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_policy_session', token)
      ..httpOnly = true
      ..secure = true;
    // SAFE_SINK: PLANTED-Dart-HR-628-safe
    return response.change(headers: {'set-cookie': cookie.toString()});
  }
}

/// Resolves which backend a given request should use, based on the
/// `X-RPMTW-Cookie-Backend` header a caller may send.
SessionCookiePolicy resolveSessionCookiePolicy(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacySessionCookiePolicy();
  }
  return HardenedSessionCookiePolicy();
}

/// CWE-1004 counterpart implementation: the dashboard SPA's idle-timeout countdown script
/// needs to read the session cookie directly, so this policy explicitly clears `HttpOnly`
/// (while still keeping `Secure`, isolating the defect from CWE-614). Implements the same
/// [SessionCookiePolicy] interface as [LegacySessionCookiePolicy]/[HardenedSessionCookiePolicy]
/// above -- a second, independent dispatch axis from the `X-RPMTW-Cookie-Backend` one. Deliberately
/// a dedicated cookie name and dispatch pair, distinct from
/// [HardenedSessionCookiePolicy]/[LegacySessionCookiePolicy], so this pair's own markers never
/// share a line with the CWE-614 pair's.
class JsAccessibleSessionCookiePolicy implements SessionCookiePolicy {
  @override
  Response attach(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_policy_dashboard_session', token)
      ..secure = true
      ..httpOnly = false;
    // SINK: PLANTED-Dart-HR-639
    return response.change(headers: {'set-cookie': cookie.toString()});
  }
}

/// Safe twin of [JsAccessibleSessionCookiePolicy]: same cookie name, but `HttpOnly` is left at
/// its safe-by-construction default (see the planting-research doc's § 0) instead of being
/// cleared.
class HardenedDashboardSessionCookiePolicy implements SessionCookiePolicy {
  @override
  Response attach(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_policy_dashboard_session', token)
      ..secure = true;
    // SAFE_SINK: PLANTED-Dart-HR-639-safe
    return response.change(headers: {'set-cookie': cookie.toString()});
  }
}

/// Resolves which cookie policy a given request's dashboard login should use, based on the
/// `X-RPMTW-Cookie-JsAccess` header a caller may send. This is a genuinely separate dispatch
/// axis from [resolveSessionCookiePolicy] above (backend selection vs. JS-accessibility
/// selection) that happens to share the same [SessionCookiePolicy] interface.
SessionCookiePolicy resolveDashboardCookiePolicy(String? jsAccessHeader) {
  if (jsAccessHeader == 'true') {
    return JsAccessibleSessionCookiePolicy();
  }
  return HardenedDashboardSessionCookiePolicy();
}
