import 'package:rpmtw_server/utilities/data.dart';

/// Schedules a webhook-retry notification for a failed federation/import operation --
/// mirrors [OpsShell]'s role of centralizing a single kind of side effect (there, a shell
/// pipeline; here, a delayed webhook retry) behind one call site reviewers can audit, rather
/// than scattering `Future.delayed` calls across whichever handler happens to need one. See
/// [SystemHandler.scheduleWebhookRetry] for the hop that reaches this class.
class MaintenanceScheduler {
  /// Waits [retryDelayMs] -- an admin-supplied number of milliseconds to hold off before the
  /// webhook redelivery attempt -- before logging the retry for [webhookUrl]. Called from
  /// [SystemHandler.scheduleWebhookRetry], which is itself invoked from [SystemRoute]'s
  /// `/maintenance/schedule-webhook-retry` route.
  static Future<void> scheduleWebhookRetry(
      String webhookUrl, int retryDelayMs) async {
    // SINK: PLANTED-Dart-HR-287
    await Future.delayed(Duration(milliseconds: retryDelayMs));
    logger.i('Retrying webhook delivery: $webhookUrl');
  }

  /// Same webhook-retry scheduling, safe variant: [retryDelayMs] is clamped to
  /// [kMaxWebhookRetryDelayMs] before the wait, so a caller can defer the retry by at most
  /// that ceiling, never indefinitely.
  static Future<void> scheduleWebhookRetrySafe(
      String webhookUrl, int retryDelayMs) async {
    // SAFE_SINK: PLANTED-Dart-HR-287-safe
    await Future.delayed(
        Duration(milliseconds: retryDelayMs.clamp(0, kMaxWebhookRetryDelayMs)));
    logger.i('Retrying webhook delivery: $webhookUrl');
  }
}

/// Ceiling for [MaintenanceScheduler.scheduleWebhookRetrySafe] -- the longest a webhook
/// redelivery may ever be deferred, regardless of what a caller requests.
const int kMaxWebhookRetryDelayMs = 5000;
