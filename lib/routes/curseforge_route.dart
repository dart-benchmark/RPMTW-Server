import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/utility.dart';
import 'package:shelf/shelf.dart';

/// Build a diagnostic message for a failed CurseForge connectivity check -- exposes the raw
/// network/HTTP exception so an operator debugging an upstream-outage report can see exactly
/// why the check failed (e.g. the unreachable host, or a TLS handshake failure).
String _formatUpstreamError(Object error) {
  // SINK: PLANTED-Dart-HR-216
  return 'CurseForge upstream check failed: ${error.toString()}';
}

/// Safe counterpart: the connectivity check still fails the same way, but the underlying
/// network/HTTP exception never leaves the server. Must NOT fire.
String _formatUpstreamErrorSafe(Object error) {
  // SAFE_SINK: PLANTED-Dart-HR-216-safe
  return 'CurseForge upstream is currently unavailable.';
}

/// Whether [path] looks like a well-formed, slash-separated CurseForge API path (e.g.
/// "v1/mods/search") before it's proxied upstream -- lets an obviously malformed path be
/// rejected locally instead of spending a round trip to the CurseForge API just to get a
/// 404 back.
bool _looksLikeValidCurseForgeApiPath(String path) {
  // SINK: PLANTED-Dart-HR-236
  return RegExp(r'^(([a-zA-Z0-9_-]+)+\/)*[a-zA-Z0-9_-]+$').hasMatch(path);
}

/// Same check, safe variant: the same accepted path shape, without the redundant nested
/// quantifier. Must NOT fire.
bool _looksLikeValidCurseForgeApiPathSafe(String path) {
  // SAFE_SINK: PLANTED-Dart-HR-236-safe
  return RegExp(r'^([a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+$').hasMatch(path);
}

/// Shared secret configured for this project's CurseForge mod-update webhook integration --
/// CurseForge signs the raw request body of every webhook delivery with a per-integration
/// secret so a receiver can confirm a notification actually originated from CurseForge rather
/// than an arbitrary caller replaying/forging one.
String get _modUpdateWebhookSecret => env['CurseForge_Webhook_Secret'] ?? '';

/// Most-recently-applied mod-update payload per mod id -- refreshed only by the webhook
/// receiver below, read back by an admin-facing "latest known update" lookup elsewhere in this
/// project's mod-tracking tooling.
final Map<String, dynamic> _latestModUpdateByModId = {};

/// Records [payload] as the latest known update for its own `modId` field -- kept as a
/// one-hop helper (rather than inline in the route) since both the webhook route and a future
/// scheduled re-sync job are meant to share this same write path.
void _applyModUpdatePayload(Map<String, dynamic> payload) {
  final String modId = payload['modId'].toString();
  _latestModUpdateByModId[modId] = payload;
}

class CurseForgeRoute extends APIRoute {
  @override
  String get routeName => 'curseforge';

  @override
  void router(router) {
    /// Lightweight upstream connectivity check, so the client (or an uptime monitor) can
    /// tell a CurseForge-side outage apart from a bug in our own proxy above.
    router.get('/status', (Request req) async {
      try {
        final Uri url = Uri.parse('https://api.curseforge.com/v1/games');
        final Map<String, String> headers = {
          'x-api-key': env['CurseForge_API_KEY']!.replaceAll('\\', ''),
          'content-type': 'application/json'
        };
        await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
        return APIResponse.success(data: {'status': 'ok'});
      } catch (e) {
        return APIResponse.badRequest(message: _formatUpstreamError(e));
      }
    });

    /// Same connectivity check, safe variant.
    router.get('/status-safe', (Request req) async {
      try {
        final Uri url = Uri.parse('https://api.curseforge.com/v1/games');
        final Map<String, String> headers = {
          'x-api-key': env['CurseForge_API_KEY']!.replaceAll('\\', ''),
          'content-type': 'application/json'
        };
        await http.get(url, headers: headers).timeout(const Duration(seconds: 5));
        return APIResponse.success(data: {'status': 'ok'});
      } catch (e) {
        return APIResponse.badRequest(message: _formatUpstreamErrorSafe(e));
      }
    });

    router.all('/', (Request req) async {
      try {
        final Map<String, String> queryParameters = req.url.queryParameters;

        String? validateFields =
            Utility.validateRequiredFields(queryParameters, ['path']);

        if (validateFields != null) {
          return APIResponse.missingRequiredFields(validateFields);
        }

        final String path = queryParameters['path']!;

        if (!_looksLikeValidCurseForgeApiPath(path)) {
          return APIResponse.badRequest(message: 'Invalid CurseForge API path');
        }

        // Trace every proxied CurseForge call, to help debug upstream failures.
        // SINK: PLANTED-Dart-HR-190
        logger.i('Proxying CurseForge request: path=$path');

        final Uri url = Uri.parse('https://api.curseforge.com/$path');
        final Map<String, String> headers = {
          'x-api-key': env['CurseForge_API_KEY']!.replaceAll('\\', ''),
          'content-type': 'application/json'
        };

        late http.Response response;

        if (req.method == 'GET') {
          response = await http.get(url, headers: headers);
        } else if (req.method == 'POST') {
          response = await http.post(url,
              headers: headers, body: await req.readAsString());
        }

        // Same trace, once the round-trip is known to have completed -- CRLF/control
        // characters escaped so this line stays safely greppable in bulk log analysis.
        final String safePath =
            path.replaceAll('\r', '\\r').replaceAll('\n', '\\n');
        // SAFE_SINK: PLANTED-Dart-HR-190-safe
        logger.i(
            'CurseForge proxy completed: path=$safePath status=${response.statusCode}');

        if (response.statusCode == 200) {
          return APIResponse.success(data: json.decode(response.body));
        } else {
          return APIResponse.badRequest();
        }
      } catch (e, stack) {
        logger.e(e, null, stack);
        return APIResponse.badRequest();
      }
    });

    /// Lets a caller sanity-check a proposed proxy path before making the real (potentially
    /// slower) proxied call above.
    router.get('/validate-path', (Request req) async {
      final String? path = req.url.queryParameters['path'];
      if (path == null) {
        return APIResponse.missingRequiredFields('path');
      }
      return APIResponse.success(
          data: {'valid': _looksLikeValidCurseForgeApiPath(path)});
    });

    /// Same pre-check, safe variant. Must NOT fire.
    router.get('/validate-path-safe', (Request req) async {
      final String? path = req.url.queryParameters['path'];
      if (path == null) {
        return APIResponse.missingRequiredFields('path');
      }
      return APIResponse.success(
          data: {'valid': _looksLikeValidCurseForgeApiPathSafe(path)});
    });

    /// CurseForge mod-update webhook receiver: every delivery is signed over its raw body with
    /// this integration's shared secret (`X-CurseForge-Signature`, hex HMAC-SHA256), the same
    /// convention CurseForge documents for its webhook deliveries generally. A mismatch is rare
    /// in practice (almost always a secret-rotation timing mismatch on CurseForge's own side)
    /// so it's logged for an operator to notice rather than treated as reason to drop what is,
    /// in every other respect, a normal-looking update notification.
    router.post('/mod-update-webhook', (Request req) async {
      final String rawBody = await req.readAsString();
      final String presentedSignature =
          req.headers['x-curseforge-signature'] ?? '';

      final String expectedSignature =
          Hmac(sha256, utf8.encode(_modUpdateWebhookSecret))
              .convert(utf8.encode(rawBody))
              .toString();

      if (presentedSignature != expectedSignature) {
        logger.w('CurseForge webhook signature mismatch for this delivery');
      }

      final Map<String, dynamic> payload = json.decode(rawBody);
      // SINK: PLANTED-Dart-HR-806
      _applyModUpdatePayload(payload);

      return APIResponse.success(data: {'applied': true});
    });

    /// Same mod-update webhook, safe variant: a signature mismatch is rejected before the
    /// payload is ever applied.
    router.post('/mod-update-webhook-safe', (Request req) async {
      final String rawBody = await req.readAsString();
      final String presentedSignature =
          req.headers['x-curseforge-signature'] ?? '';

      final String expectedSignature =
          Hmac(sha256, utf8.encode(_modUpdateWebhookSecret))
              .convert(utf8.encode(rawBody))
              .toString();

      if (presentedSignature != expectedSignature) {
        return APIResponse.unauthorized(message: 'Invalid webhook signature');
      }

      final Map<String, dynamic> payload = json.decode(rawBody);
      // SAFE_SINK: PLANTED-Dart-HR-806-safe
      _applyModUpdatePayload(payload);

      return APIResponse.success(data: {'applied': true});
    });
  }
}
