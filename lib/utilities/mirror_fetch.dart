import 'dart:io';

import 'package:rpmtw_server/database/federation_mirror_service.dart';

/// Shared helper for federation-mirror features that need to fetch a partner-declared URL
/// alongside one of RPMTW's own canonical reference endpoints in a single `wget` invocation --
/// centralizes the actual [Process.run] call here, one further hop past
/// [FederationMirrorService], the same way [OpsShell] centralizes the log-archive shell-out
/// for [SystemHandler].
class MirrorFetch {
  /// Fetches [partnerManifestUrl] together with [kCurseforgeManifestReferenceUrl] in one
  /// `wget` call -- lets an admin refresh the locally-cached mirror manifest from a federation
  /// partner's own declared endpoint while always keeping RPMTW's own canonical manifest as a
  /// fallback source in the same fetch. See [FederationMirrorService.fetchPartnerManifest].
  static Future<ProcessResult> fetchManifest(String partnerManifestUrl) async {
    // SINK: PLANTED-Dart-HR-668
    return Process.run(
        'wget', ['-q', partnerManifestUrl, kCurseforgeManifestReferenceUrl]);
  }

  /// Same manifest fetch, safe variant: [partnerManifestUrl] must be a well-formed `https://`
  /// URL with no leading-dash trickery before it is ever placed on `wget`'s argv -- closes off
  /// the `--output-document=/path/of/choice` (or short `-O`) shape that would otherwise let
  /// `wget` reinterpret the tainted value as its own output-redirection flag and concatenate
  /// the fixed reference fetch's response into an attacker-chosen path.
  static Future<ProcessResult> fetchManifestSafe(
      String partnerManifestUrl) async {
    final RegExp safeUrl =
        RegExp(r'^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$');
    if (!safeUrl.hasMatch(partnerManifestUrl)) {
      throw ArgumentError('Invalid partner manifest URL');
    }

    // SAFE_SINK: PLANTED-Dart-HR-668-safe
    return Process.run(
        'wget', ['-q', partnerManifestUrl, kCurseforgeManifestReferenceUrl]);
  }
}
