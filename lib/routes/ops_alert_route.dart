import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/ops_alert_mailer.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';

/// Operational alerting endpoints. Lets an authenticated administrator push an
/// ad-hoc alert through the same on-call relay the automated health checks use --
/// handy for verifying the alerting pipeline end-to-end right after a deploy.
class OpsAlertRoute extends APIRoute {
  @override
  String get routeName => 'ops-alert';

  @override
  void router(router) {
    router.postRoute('/dispatch', (req, data) async {
      final String subject = data.fields['subject'] ?? 'RPMTW ops alert';
      final String detail = data.fields['detail'] ?? '';

      final bool delivered =
          await OpsAlertMailer.dispatchAlert(subject, detail);
      if (!delivered) {
        return APIResponse.internalServerError();
      }
      return APIResponse.success(data: {'delivered': true});
    }, authConfig: AuthConfig(role: UserRoleType.admin));
  }
}
