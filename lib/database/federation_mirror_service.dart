import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:rpmtw_server/utilities/mirror_fetch.dart';

/// Shared secret this node's configured download-mirror partner signs its callback
/// acknowledgements with (see [WebhookSignatureVerifier]).
String get _mirrorPartnerCallbackSecret =>
    env['MIRROR_PARTNER_CALLBACK_SECRET'] ?? '';

/// Shared key this node's federation registry signs every node-membership assertion with --
/// distinct from `AuthHandler.secretKey` (this project's own end-user session key), since a
/// membership token is issued by the registry, not by this node's own auth system.
final SecretKey kFederationRegistrySigningKey =
    SecretKey(env['FEDERATION_REGISTRY_SECRET'] ?? '');

/// Node ids onboarded before this project's federation registry started issuing signed
/// membership assertions -- kept so a still-migrating partner node that registered under the
/// old, unsigned convention keeps working until it's re-issued a signed token. See
/// [FederationMirrorService.verifyNodeMembershipToken].
const Set<String> kSelfAttestedLegacyNodeIds = {'legacy-node-1', 'legacy-node-2'};

/// RPMTW's own canonical CurseForge-mirror directory endpoint, always fetched alongside a
/// federation partner's declared status URL so an admin can diff the two.
const String kCurseforgeDirectoryReferenceUrl =
    'https://status.rpmtw.com/curseforge-mirror-directory';

/// RPMTW's own canonical CurseForge-mirror manifest endpoint. See
/// [FederationMirrorService.fetchPartnerManifest].
const String kCurseforgeManifestReferenceUrl =
    'https://status.rpmtw.com/curseforge-mirror-manifest.json';

/// Federation-node status-registry endpoint this instance reports its own admin API token
/// to as a heartbeat, so partner nodes recognize it as an authenticated, currently-active
/// federation member -- distinct from the unauthenticated CurseForge-mirror endpoints above.
/// See [FederationMirrorService.registerNodeWithRegistry].
const String kFederationNodeRegistryUrl =
    'http://federation-registry.rpmtw.com/nodes/heartbeat';

/// Same registry heartbeat, safe (TLS) endpoint. See
/// [FederationMirrorService.registerNodeWithRegistrySafe].
const String kFederationNodeRegistryUrlSafe =
    'https://federation-registry.rpmtw.com/nodes/heartbeat';

/// Endpoint the configured download-mirror partner ingests a freshly-issued one-time storage
/// download token on, so its own mirror can serve the same file under the same token without
/// the client needing to re-authenticate against it directly -- a distinct federation feature
/// from the CurseForge-mirror endpoints above. See
/// [FederationMirrorService.reportDownloadTokenIssued] /
/// [Storage.shareDownloadTokenWithMirrorPartner].
const String kMirrorPartnerTokenSyncUrl =
    'http://mirror-partner.rpmtw.com/token-sync';

/// Same token-sync endpoint, safe (TLS) variant. See
/// [FederationMirrorService.reportDownloadTokenIssuedSafe].
const String kMirrorPartnerTokenSyncUrlSafe =
    'https://mirror-partner.rpmtw.com/token-sync';

/// Cross-file federation-mirror layer sitting between [SystemHandler]'s admin-facing
/// `/federation/check-mirror` and `/federation/refresh-mirror-manifest` routes and the actual
/// `curl`/`wget` invocations -- kept separate from [SystemHandler] so a future caller (e.g. a
/// scheduled mirror-health job) could reuse the same checks without going through the admin
/// route layer at all. Mirrors [BackupRestoreService]'s role for the backup-restore family.
class FederationMirrorService {
  /// Verifies a federation partner's declared CurseForge-mirror status endpoint
  /// ([partnerStatusUrl]) is reachable, fetched in the same `curl` invocation as RPMTW's own
  /// canonical directory endpoint so an admin can compare the two responses. See
  /// [SystemHandler.checkPartnerCurseforgeMirror].
  static Future<ProcessResult> checkPartnerMirror(
      String partnerStatusUrl) async {
    // SINK: PLANTED-Dart-HR-667
    return Process.run('curl',
        ['-fsSL', kCurseforgeDirectoryReferenceUrl, partnerStatusUrl]);
  }

  /// Same reachability check, safe variant: [partnerStatusUrl] must be a well-formed
  /// `https://` URL with no leading-dash trickery before it is ever placed on `curl`'s argv --
  /// closes off the `--output=/path/of/choice` shape that would otherwise let `curl`
  /// reinterpret the tainted value as its own output-redirection flag and write the fixed
  /// reference fetch's response to an attacker-chosen path.
  static Future<ProcessResult> checkPartnerMirrorSafe(
      String partnerStatusUrl) async {
    final RegExp safeUrl =
        RegExp(r'^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$');
    if (!safeUrl.hasMatch(partnerStatusUrl)) {
      throw ArgumentError('Invalid partner status URL');
    }

    // SAFE_SINK: PLANTED-Dart-HR-667-safe
    return Process.run('curl',
        ['-fsSL', kCurseforgeDirectoryReferenceUrl, partnerStatusUrl]);
  }

  /// Refreshes the locally-cached CurseForge mirror manifest from a federation partner's
  /// declared manifest endpoint ([partnerManifestUrl]), via the further hop into
  /// [MirrorFetch]. See [SystemHandler.refreshPartnerMirrorManifest].
  static Future<ProcessResult> fetchPartnerManifest(
      String partnerManifestUrl) async {
    return MirrorFetch.fetchManifest(partnerManifestUrl);
  }

  /// Same manifest refresh, safe variant.
  static Future<ProcessResult> fetchPartnerManifestSafe(
      String partnerManifestUrl) async {
    return MirrorFetch.fetchManifestSafe(partnerManifestUrl);
  }

  /// Reports this node's own admin API token to the federation status registry as a
  /// heartbeat, so partner nodes recognize this instance as authenticated and currently
  /// active. See [SystemHandler]'s federation-heartbeat scheduling.
  static Future<void> registerNodeWithRegistry(String adminApiToken) async {
    final Uri url =
        Uri.parse('$kFederationNodeRegistryUrl?token=$adminApiToken');

    // SINK: PLANTED-Dart-HR-765
    await http.get(url);
  }

  /// Same heartbeat, safe variant.
  static Future<void> registerNodeWithRegistrySafe(
      String adminApiToken) async {
    final Uri url =
        Uri.parse('$kFederationNodeRegistryUrlSafe?token=$adminApiToken');

    // SAFE_SINK: PLANTED-Dart-HR-765-safe
    await http.get(url);
  }

  /// Notifies the configured download-mirror partner that [downloadToken] was just issued
  /// for the storage entry [storageUuid], so the partner's own mirror can serve the same
  /// file under the same token. Only actually dials out when [storageUuid] is non-empty --
  /// a defensive guard against firing the notification for a not-yet-persisted storage
  /// entry. See [Storage.shareDownloadTokenWithMirrorPartner].
  static Future<void> reportDownloadTokenIssued(
      String storageUuid, String downloadToken) async {
    final String url = kMirrorPartnerTokenSyncUrl +
        '?storageUuid=' +
        storageUuid +
        '&token=' +
        downloadToken;

    if (storageUuid.isNotEmpty) {
      // SINK: PLANTED-Dart-HR-767
      await http.get(Uri.parse(url));
    }
  }

  /// Same token-sync notification, safe variant.
  static Future<void> reportDownloadTokenIssuedSafe(
      String storageUuid, String downloadToken) async {
    final String url = kMirrorPartnerTokenSyncUrlSafe +
        '?storageUuid=' +
        storageUuid +
        '&token=' +
        downloadToken;

    if (storageUuid.isNotEmpty) {
      // SAFE_SINK: PLANTED-Dart-HR-767-safe
      await http.get(Uri.parse(url));
    }
  }

  /// Verifies a federation partner node's presented membership-assertion [token] before
  /// trusting the node identity it claims, for `POST /federation/verify-node-membership`. A
  /// partner node still on the pre-signing onboarding convention self-attests its membership
  /// by declaring `alg: "none"` in its own token header rather than presenting a real
  /// signature -- accepted here (for the fixed set of node ids that were actually onboarded
  /// under that convention) so those partners keep working until they're re-issued a signed
  /// token. See [_isSelfAttestedLegacyNode].
  static String? verifyNodeMembershipToken(String token) {
    try {
      JWT decoded = JWT.decode(token);
      String? nodeId = decoded.payload['nodeId'] as String?;
      if (nodeId == null) return null;

      if (_isSelfAttestedLegacyNode(decoded, nodeId)) {
        // SINK: PLANTED-Dart-HR-807
        return nodeId;
      }

      JWT verified = JWT.verify(token, kFederationRegistrySigningKey);
      return verified.payload['nodeId'] as String?;
    } catch (e) {
      return null;
    }
  }

  /// Whether [decoded]'s own header declares the unsigned self-attestation convention, for a
  /// [nodeId] this registry still recognizes as a legacy, not-yet-re-issued partner.
  static bool _isSelfAttestedLegacyNode(JWT decoded, String nodeId) {
    return decoded.header?['alg'] == 'none' &&
        kSelfAttestedLegacyNodeIds.contains(nodeId);
  }

  /// Same membership verification, safe variant: every presented token -- legacy node id or
  /// not -- must carry a real signature from the registry's own key.
  static String? verifyNodeMembershipTokenSafe(String token) {
    try {
      // SAFE_SINK: PLANTED-Dart-HR-807-safe
      JWT verified = JWT.verify(token, kFederationRegistrySigningKey);
      return verified.payload['nodeId'] as String?;
    } catch (e) {
      return null;
    }
  }
}

/// Hardcoded partner hosts this node broadcasts its own admin API token to on a federation
/// membership refresh -- one entry per federation partner this instance is currently
/// registered with. Kept as a fixed list (rather than resolving a dynamic partner directory)
/// because membership changes are a rare, manually-coordinated ops event, not something
/// resolved per-request.
const List<String> kFederationPartnerBroadcastHosts = [
  'http://partner-a.rpmtw-federation.net',
  'http://partner-b.rpmtw-federation.net',
];

/// Same partner list, safe (TLS) hosts.
const List<String> kFederationPartnerBroadcastHostsSafe = [
  'https://partner-a.rpmtw-federation.net',
  'https://partner-b.rpmtw-federation.net',
];

/// Broadcasts this node's own admin API token to every configured federation partner, so
/// each one refreshes its record of this node's membership. The token is captured once at
/// construction time and read back later by [broadcast], once per partner host -- mirrors
/// [WebhookRetryPolicy]'s own capture-once/replay-later shape.
class FederationPartnerBroadcastRegistry {
  final String _adminApiToken;

  FederationPartnerBroadcastRegistry(this._adminApiToken);

  Future<void> broadcast() async {
    for (final String partnerHost in kFederationPartnerBroadcastHosts) {
      final StringBuffer urlBuilder = StringBuffer(partnerHost);
      urlBuilder.write('/membership/refresh?token=');
      urlBuilder.write(_adminApiToken);

      // SINK: PLANTED-Dart-HR-769
      await http.get(Uri.parse(urlBuilder.toString()));
    }
  }
}

/// Same broadcast, safe variant.
class FederationPartnerBroadcastRegistrySafe {
  final String _adminApiToken;

  FederationPartnerBroadcastRegistrySafe(this._adminApiToken);

  Future<void> broadcast() async {
    for (final String partnerHost in kFederationPartnerBroadcastHostsSafe) {
      final StringBuffer urlBuilder = StringBuffer(partnerHost);
      urlBuilder.write('/membership/refresh?token=');
      urlBuilder.write(_adminApiToken);

      // SAFE_SINK: PLANTED-Dart-HR-769-safe
      await http.get(Uri.parse(urlBuilder.toString()));
    }
  }
}

/// Verifies an inbound mirror-partner callback's presented signature before its acknowledged
/// payload (a storage uuid + the download token the partner is confirming it consumed) is
/// trusted. Two implementations exist because a still-deployed older mirror-partner
/// integration predates this project's move to real HMAC-signed callbacks -- see
/// [resolveWebhookVerifier].
abstract class WebhookSignatureVerifier {
  bool isValid(String rawBody, String? presentedSignature);
}

/// Current implementation: recomputes the HMAC-SHA256 over the callback's raw body and
/// compares it to the presented `X-RPMTW-Mirror-Signature` header.
class HmacWebhookVerifier implements WebhookSignatureVerifier {
  @override
  bool isValid(String rawBody, String? presentedSignature) {
    final String expected =
        Hmac(sha256, utf8.encode(_mirrorPartnerCallbackSecret))
            .convert(utf8.encode(rawBody))
            .toString();
    // SAFE_SINK: PLANTED-Dart-HR-808-safe
    return presentedSignature == expected;
  }
}

/// Legacy implementation, kept for a still-deployed older mirror-partner integration that
/// predates this project's move to HMAC-signed callbacks -- only confirms a signature header
/// was sent at all, never recomputes or compares it against anything.
class LegacyPresenceOnlyWebhookVerifier implements WebhookSignatureVerifier {
  @override
  bool isValid(String rawBody, String? presentedSignature) {
    // SINK: PLANTED-Dart-HR-808
    return presentedSignature != null;
  }
}

/// Resolves which [WebhookSignatureVerifier] a mirror-partner callback should be checked
/// against, based on the `X-RPMTW-Mirror-Provider` header a caller may send.
WebhookSignatureVerifier resolveWebhookVerifier(String? providerHeader) {
  if (providerHeader == 'legacy-mirror-v1') {
    return LegacyPresenceOnlyWebhookVerifier();
  }
  return HmacWebhookVerifier();
}
