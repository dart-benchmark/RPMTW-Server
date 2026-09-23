import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../database/models/auth/user.dart';

/// Resolves how a request's bearer token is authenticated for `/auth/user/session-info` below.
/// Two implementations exist because a still-deployed legacy admin CLI build (predating this
/// project's move to signature-verified session lookups) only ever decoded the token locally to
/// read the `uuid` claim back out, and cannot be swapped for the current implementation without
/// also shipping a CLI update those installs won't get for months -- every other caller gets the
/// current, verified strategy by default. Mirrors this project's own
/// [LoginAttemptCache]/`resolveLoginAttemptCache` and
/// [LdapAuthStrategy]/`resolveLdapAuthStrategy` dynamic-backend-selection idiom.
abstract class TokenAuthStrategy {
  /// Resolves the [User] a presented bearer [token] authenticates as, or `null` if the token
  /// does not resolve to a user at all.
  Future<User?> resolveUser(String token);
}

/// Original CLI-compatible implementation, kept only for the legacy client contract -- reads the
/// `uuid` claim straight out of the token's payload without ever checking the token's signature.
class LegacyTokenAuthStrategy implements TokenAuthStrategy {
  @override
  Future<User?> resolveUser(String token) async {
    try {
      // 舊版命令列工具僅解碼權杖內容取出 uuid，尚未走過簽章驗證流程
      // SINK: PLANTED-Dart-HR-740
      JWT jwt = JWT.decode(token);
      String uuid = jwt.payload['uuid'];
      return User.getByUUID(uuid);
    } catch (e) {
      return null;
    }
  }
}

/// Current implementation: verifies the token's signature (and expiry) before trusting any claim
/// in its payload -- delegates to [User.getByToken], the same verified path every other
/// authenticated route in this project already uses.
class VerifiedTokenAuthStrategy implements TokenAuthStrategy {
  @override
  Future<User?> resolveUser(String token) async {
    try {
      // SAFE_SINK: PLANTED-Dart-HR-740-safe
      return await User.getByToken(token);
    } catch (e) {
      return null;
    }
  }
}

/// Resolves which strategy a given request should use, based on the `X-RPMTW-Auth-Backend`
/// header a caller may send.
TokenAuthStrategy resolveTokenAuthStrategy(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyTokenAuthStrategy();
  }
  return VerifiedTokenAuthStrategy();
}
