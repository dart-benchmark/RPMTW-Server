import 'dart:io';

import 'package:rpmtw_server/utilities/data.dart';

/// A single wiki-content sync strategy for a federation partner.
/// [SystemHandler.syncWikiContentViaBackend] resolves the concrete implementation at runtime
/// based on the caller-supplied `X-RPMTW-Sync-Backend` header. Mirrors this project's own
/// [MaintenanceAction]/[DelayStrategy]/[LifecycleStrategy] header- or type-driven dispatch
/// idiom.
abstract class FederationSyncStrategy {
  Future<void> sync(String partnerRepoUrl, String localTag);
}

/// Still-deployed legacy sync path, kept only because an older ops runbook expects wiki
/// content synced via a direct `git fetch` into an already-cloned local mirror rather than the
/// current manifest-only approach. [localTag] names which local ref to fetch into.
class GitFetchSyncStrategy implements FederationSyncStrategy {
  @override
  Future<void> sync(String partnerRepoUrl, String localTag) async {
    // SINK: PLANTED-Dart-HR-669
    await Process.run('git', ['fetch', partnerRepoUrl, localTag]);
  }
}

/// Never spawns a subprocess -- records the requested sync to the server's own log instead,
/// for the current manifest-only workflow to pick up asynchronously.
class ManifestOnlySyncStrategy implements FederationSyncStrategy {
  const ManifestOnlySyncStrategy();

  @override
  Future<void> sync(String partnerRepoUrl, String localTag) async {
    logger.i(
        'Wiki-content sync requested: $partnerRepoUrl -> refs/mirrors/$localTag (manifest-only)');
  }
}

/// Resolves which [FederationSyncStrategy] a given request should use, based on the
/// `X-RPMTW-Sync-Backend` header a caller may send. Only `legacy-git-fetch` ever spawns a
/// subprocess; every other value (including no header at all) gets the current, safe
/// manifest-only strategy.
FederationSyncStrategy resolveFederationSyncStrategy(String? backendHeader) {
  if (backendHeader == 'legacy-git-fetch') {
    return GitFetchSyncStrategy();
  }
  return const ManifestOnlySyncStrategy();
}
