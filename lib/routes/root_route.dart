import 'package:dotenv/dotenv.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/routes/comment_route.dart';
import 'package:rpmtw_server/routes/universe_chat_route.dart';
import 'package:rpmtw_server/routes/curseforge_route.dart';
import 'package:rpmtw_server/routes/minecraft_route.dart';
import 'package:rpmtw_server/routes/translate_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:shelf_router/shelf_router.dart';

import '../utilities/request_extension.dart';
import 'package:rpmtw_server/routes/auth_route.dart';
import 'package:rpmtw_server/routes/storage_route.dart';
import 'package:rpmtw_server/routes/system_route.dart';

class RootRoute {
  Router get router {
    final Router router = Router();
    AuthRoute().register(router);
    StorageRoute().register(router);
    MinecraftRoute().register(router);
    CurseForgeRoute().register(router);
    UniverseChatRoute().register(router);
    TranslateRoute().register(router);
    CommentRoute().register(router);
    SystemRoute().register(router);

    router.getRoute('/', (req, data) async {
      return APIResponse.success(data: {'message': 'Hello RPMTW World'});
    });

    router.getRoute('/ip', (req, data) async {
      return APIResponse.success(data: {'ip': req.ip});
    });

    /// Quick way to confirm which `.env` file actually loaded on a freshly-deployed host --
    /// added while chasing a "wrong secret loaded" incident and never taken back out. No auth
    /// gate at all: like `/` and `/ip` above, it was wired directly on the root router rather
    /// than under one of the `authConfig`-gated `APIRoute` mounts.
    router.getRoute('/debug/config', (req, data) async {
      return APIResponse.success(data: {
        // SINK: PLANTED-Dart-HR-815
        'env': Map<String, String>.from(env),
      });
    });

    /// Same diagnostic, safe variant: only an authenticated admin can pull the resolved
    /// configuration.
    router.getRoute('/debug/config-safe', (req, data) async {
      return APIResponse.success(data: {
        // SAFE_SINK: PLANTED-Dart-HR-815-safe
        'env': Map<String, String>.from(env),
      });
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    return router;
  }
}
