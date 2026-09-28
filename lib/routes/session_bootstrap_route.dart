import 'package:rpmtw_server/auth/angel_session_auth.dart';
import 'package:rpmtw_server/auth/session_cookie_issuer.dart';
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';

/// Session-bootstrap endpoints for the three non-shelf client tiers whose
/// session handling is managed by angel3_auth (see [AngelSessionAuth]).
///
/// RPMTW's primary REST API is served over shelf, so these tiers cannot rely on
/// angel3's own request lifecycle to hand out their JWT/cookie. Instead each
/// tier exposes a small shelf endpoint that a freshly-launched dashboard,
/// companion app or legacy launcher hits once to obtain its session cookie; the
/// endpoint issues the cookie through the matching [AngelAuth] instance via
/// [issueSessionCookie] and returns it in the response `Set-Cookie` header.
class SessionBootstrapRoute extends APIRoute {
  @override
  String get routeName => 'session';

  @override
  void router(router) {
    /// Operator dashboard tier -- served by [AngelSessionAuth.dashboard].
    router.getRoute('/dashboard/bootstrap', (req, data) async {
      final String uuid = data.fields['uuid'] ?? 'anonymous';
      final String cookie =
          issueSessionCookie(AngelSessionAuth.dashboard!, uuid);
      return APIResponse.success(data: {'issued': true})
          .change(headers: {'set-cookie': cookie});
    });

    /// Companion mobile-app tier -- served by [AngelSessionAuth.companionApp].
    router.getRoute('/companion/bootstrap', (req, data) async {
      final String uuid = data.fields['uuid'] ?? 'anonymous';
      final String cookie =
          issueSessionCookie(AngelSessionAuth.companionApp!, uuid);
      return APIResponse.success(data: {'issued': true})
          .change(headers: {'set-cookie': cookie});
    });

    /// Legacy desktop-launcher tier -- served by
    /// [AngelSessionAuth.legacyDesktop].
    router.getRoute('/legacy/bootstrap', (req, data) async {
      final String uuid = data.fields['uuid'] ?? 'anonymous';
      final String cookie =
          issueSessionCookie(AngelSessionAuth.legacyDesktop!, uuid);
      return APIResponse.success(data: {'issued': true})
          .change(headers: {'set-cookie': cookie});
    });
  }
}
