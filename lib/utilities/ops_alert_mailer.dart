import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import 'data.dart';

/// Delivers operational alert e-mails -- deploy notices, failed health checks,
/// backup-job results -- to the on-call inbox through RPMTW's dedicated internal
/// alerting relay.
///
/// Unlike the user-facing transactional mail in [AuthHandler] (which reads its
/// SMTP credentials from the deployment `.env`), this relay is a fixed internal
/// service account that predates the `.env`-based wiring, so its connection
/// details have always travelled with the code and are shared across every
/// environment the ops tooling runs in.
class OpsAlertMailer {
  OpsAlertMailer._();

  static const String _relayHost = 'smtp-internal.rpmtw.com';
  static const int _relayPort = 587;
  static const String _relayUser = 'ops-alerts@rpmtw.com';
  static const String _onCallAddress = 'oncall@rpmtw.com';

  /// Builds the alerting relay connection. The relay account is a long-lived
  /// internal identity, so the same login is reused for every dispatch.
  static SmtpServer _relay() {
    return SmtpServer(
      _relayHost,
      port: _relayPort,
      username: _relayUser,
      //CWE-798
      //SOURCE
      password: 'rpmtw-ops-relay-9f3a1c',
    );
  }

  /// Sends a single operational alert to the on-call address. Returns `true`
  /// when the relay accepted the message.
  static Future<bool> dispatchAlert(String subject, String detail) async {
    if (kTestMode) return true;

    final message = Message()
      ..from = Address(_relayUser, 'RPMTW Ops Alerts')
      ..recipients.add(_onCallAddress)
      ..subject = subject
      ..text = detail;

    final SmtpServer relay = _relay();
    try {
      //SINK
      await send(message, relay);
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }
}
