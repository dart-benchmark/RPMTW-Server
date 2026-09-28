import 'dart:io';

import 'package:angel3_auth/angel3_auth.dart';

import '../database/models/auth/user.dart';
import '../handler/auth_handler.dart';

/// Mints the browser/app session cookie for [uuid] using [auth]'s cookie policy
/// and returns the ready-to-send `Set-Cookie` header value.
///
/// The JWT payload is produced by the project's existing
/// [AuthHandler.generateAuthToken], wrapped in the `token` cookie angel3_auth
/// reads back on the next request, and handed to angel3_auth's
/// [AngelAuth.protectCookie]. `protectCookie` stamps the tier's
/// domain/path/max-age and -- for a tier built with `secureCookies: false` --
/// returns the cookie *without* the `Secure`/`HttpOnly` attributes, which is
/// exactly the header this helper serialises back out to the caller.
///
/// Shared by every tier's session-bootstrap route (see
/// `SessionBootstrapRoute`); each route passes its own [AngelAuth] instance, so
/// the cookie hardening for that request is entirely decided by how that
/// instance was constructed in `AngelSessionAuth`.
String issueSessionCookie(AngelAuth<User> auth, String uuid) {
  final String jwt = AuthHandler.generateAuthToken(uuid);
  final Cookie cookie = Cookie('token', jwt);
  final Cookie protectedCookie = auth.protectCookie(cookie);
  return protectedCookie.toString();
}
