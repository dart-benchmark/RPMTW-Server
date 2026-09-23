import 'dart:io';

import 'package:rpmtw_server/utilities/data.dart';

/// Terminal recovery actions for this server process itself -- kept separate from
/// [SystemHandler] (one hop further than its own `/maintenance/*` process-launching
/// routes) so the "how do we actually make the process go away" decision lives in one
/// place regardless of which admin route triggered it. See [SystemHandler]'s
/// `/system/restart-node` route.
class NodeLifecycleService {
  /// Kills this process outright so the process supervisor (systemd/pm2) restarts it
  /// clean -- used for cases a graceful in-process restart can't reach (e.g. a wedged event
  /// loop). Reachable regardless of [reason]: the argument is logged only, it never gates
  /// whether the process actually terminates. [exitFn] defaults to `dart:io`'s real [exit]
  /// but is overridable so a test can confirm reachability without killing its own process.
  static void restartNow(String reason, {void Function(int) exitFn = exit}) {
    logger.w('Node restart requested (hard): $reason');

    // SINK: PLANTED-Dart-HR-322
    exitFn(0);
  }

  /// Same restart request, safe variant: never terminates the process directly. Instead it
  /// flips a flag this project's own drain loop already polls between requests, so in-flight
  /// requests finish and the process supervisor's own health-check triggers the restart on
  /// its own schedule -- no caller-reachable code path here can kill the process outright.
  static void restartGracefully(String reason) {
    logger.i('Node restart requested (graceful): $reason');

    // SAFE_SINK: PLANTED-Dart-HR-322-safe
    _requestGracefulRestart(reason);
  }

  static void _requestGracefulRestart(String reason) {
    // No-op placeholder for this project's real drain-loop flag -- deliberately never
    // touches `dart:io`'s `exit()` or any other process-terminating primitive.
    logger.i('Graceful restart scheduled: $reason');
  }
}
