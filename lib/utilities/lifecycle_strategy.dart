import 'dart:io';

import 'package:rpmtw_server/utilities/data.dart';

/// Resolves how a `/system/shutdown` request tears down this server process, based on the
/// `X-RPMTW-Lifecycle-Backend` header a caller may send. Two implementations exist because a
/// still-deployed legacy ops runbook (predating this project's move to a supervisor-driven
/// graceful restart) always expected the process to exit immediately so its own watchdog
/// script could time the restart -- every other caller gets the current, safe strategy by
/// default. Mirrors this project's own [HeuristicRuleExecutor]/`resolveHeuristicRuleExecutor`
/// and [BackupRestoreStrategy]/`resolveBackupRestoreStrategy` dynamic-backend-selection idiom.
abstract class LifecycleStrategy {
  void shutdown(String reason);
}

/// Legacy ops-runbook integration, kept only for that runbook's own watchdog timing --
/// terminates the process immediately and unconditionally. [exitFn] defaults to `dart:io`'s
/// real [exit] but is overridable so a test can confirm reachability without killing its own
/// process.
class RawExitLifecycleStrategy implements LifecycleStrategy {
  final void Function(int) exitFn;

  const RawExitLifecycleStrategy({this.exitFn = exit});

  @override
  void shutdown(String reason) {
    logger.w('Raw shutdown requested: $reason');

    // SINK: PLANTED-Dart-HR-323
    exitFn(0);
  }
}

/// Current implementation: never terminates the process directly. Flips the same drain-loop
/// flag [NodeLifecycleService.restartGracefully] uses -- `dart:io`'s `exit()` is never
/// touched, so an unrecognized (or intentionally malicious) backend header has no
/// process-terminating primitive to reach through this strategy at all.
class GracefulLifecycleStrategy implements LifecycleStrategy {
  @override
  void shutdown(String reason) {
    // SAFE_SINK: PLANTED-Dart-HR-323-safe
    logger.i('Graceful shutdown scheduled: $reason');
  }
}

LifecycleStrategy resolveLifecycleStrategy(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return const RawExitLifecycleStrategy();
  }
  return GracefulLifecycleStrategy();
}
