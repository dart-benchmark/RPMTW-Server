import 'dart:io';
import 'dart:typed_data';

import 'package:byte_size/byte_size.dart';
import 'package:dotenv/dotenv.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/handler/system_handler.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:shelf/shelf.dart';
import '../database/database.dart';
import '../database/models/storage/storage.dart';
import '../utilities/request_extension.dart';
import '../utilities/utility.dart';
import 'api_route.dart';

class StorageRoute extends APIRoute {
  @override
  String get routeName => 'storage';

  @override
  void router(router) {
    router.postRoute('/create', (req, data) async {
      String contentType =
          req.headers['content-type'] ?? 'application/octet-stream';

      Storage storage = Storage(
          type: StorageType.temp,
          contentType: contentType,
          uuid: Uuid().v4(),
          createAt: RPMTWUtil.getUTCTime());
      GridIn gridIn =
          DataBase.instance.gridFS.createFile(data.byteStream, storage.uuid);
      ByteSize size = ByteSize.FromBytes(req.contentLength!);
      if (size.MegaBytes > 8) {
        // 限制最大檔案大小為 8 MB
        return APIResponse.badRequest(message: 'File size is too large');
      }
      await gridIn.save();
      await storage.insert();

      return APIResponse.success(data: storage.outputMap());
    });

    router.getRoute('/<uuid>', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      return APIResponse.success(data: storage.outputMap());
    });

    router.getRoute('/<uuid>/admin-export-token', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      if (storage.type != StorageType.general) {
        return APIResponse.badRequest(
            message: 'Only general storage can be exported');
      }
      String secret = env['DATA_BASE_SecretKey']!;
      String exportToken = storage.computeAdminExportToken(secret);
      return APIResponse.success(data: {'exportToken': exportToken});
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Issues a one-time direct-download token for the temp storage entry [uuid] (see
    /// [Storage.computeDownloadToken]) and notifies the configured federation
    /// download-mirror partner that it is now valid, so the partner's own mirror can serve
    /// the same file under the same token without the client needing to re-authenticate
    /// against it directly. See [Storage.shareDownloadTokenWithMirrorPartner].
    router.getRoute('/<uuid>/issue-download-token', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      String secret = env['DATA_BASE_SecretKey']!;
      String downloadToken = storage.computeDownloadToken(secret);
      await storage.shareDownloadTokenWithMirrorPartner(downloadToken);
      return APIResponse.success(data: {'downloadToken': downloadToken});
    });

    /// Same download-token issuance, safe variant.
    router.getRoute('/<uuid>/issue-download-token-safe', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      String secret = env['DATA_BASE_SecretKey']!;
      String downloadToken = storage.computeDownloadToken(secret);
      await storage.shareDownloadTokenWithMirrorPartnerSafe(downloadToken);
      return APIResponse.success(data: {'downloadToken': downloadToken});
    });

    /// Issues an anonymous, no-login-required temp-share link for storage entry [uuid] --
    /// unlike [issue-download-token] above (bound to this entry's own persisted
    /// `uuid`/`createAt`), the returned code is a freestanding identifier a caller redeems on
    /// its own, so its unguessability is the only thing standing between "shared with the one
    /// recipient I sent it to" and "shared with anyone who finds it". See
    /// [Storage.createTempShareLink].
    router.getRoute('/<uuid>/issue-temp-share-link', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      String shareCode = storage.createTempShareLink();
      return APIResponse.success(data: {'shareCode': shareCode});
    });

    /// Same temp-share-link issuance, safe variant.
    router.getRoute('/<uuid>/issue-temp-share-link-safe', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      String shareCode = storage.createTempShareLinkSafe();
      return APIResponse.success(data: {'shareCode': shareCode});
    });

    router.getRoute('/<uuid>/download', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      if (storage.type == StorageType.temp) {
        // 暫存檔案僅允許透過附帶正確一次性權杖的連結下載
        String? token = data.fields['token'];
        String secret = env['DATA_BASE_SecretKey']!;
        // SINK: PLANTED-Dart-HR-805
        if (token == null || token != storage.computeDownloadToken(secret)) {
          return APIResponse.unauthorized(message: 'Invalid download token');
        }
      }

      Uint8List bytes = await storage.readAsBytes();

      return Response.ok(bytes, headers: {
        'Content-Type': storage.contentType,
      });
    });

    /// Same one-time-token download as `/<uuid>/download` above, safe variant: the presented
    /// token is checked against the expected download token with a constant-time comparison
    /// instead of `!=`, so response latency can't be used to recover a valid token one byte at
    /// a time.
    router.getRoute('/<uuid>/download-safe', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      if (storage.type == StorageType.temp) {
        String? token = data.fields['token'];
        String secret = env['DATA_BASE_SecretKey']!;
        // SAFE_SINK: PLANTED-Dart-HR-805-safe
        if (token == null ||
            !Utility.constantTimeEquals(token, storage.computeDownloadToken(secret))) {
          return APIResponse.unauthorized(message: 'Invalid download token');
        }
      }

      Uint8List bytes = await storage.readAsBytes();

      return Response.ok(bytes, headers: {
        'Content-Type': storage.contentType,
      });
    });

    /// Preview a storage's text content -- lets the client show a short snippet (e.g. of a
    /// translation source file) before committing to a full download.
    router.getRoute('/<uuid>/preview', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      try {
        String content = await storage.readAsString();
        return APIResponse.success(data: {
          'preview': content.substring(0, content.length > 200 ? 200 : content.length)
        });
      } catch (e) {
        // 內容並非合法的 UTF-8 文字（例如誤傳二進位檔案）時，回傳原始錯誤方便除錯
        // SINK: PLANTED-Dart-HR-215
        return APIResponse.badRequest(
            message: 'Failed to preview storage content: ${e.toString()}');
      }
    });

    /// Same content preview, safe variant: a decode/read failure never leaks the underlying
    /// exception back to the caller. Must NOT fire.
    router.getRoute('/<uuid>/preview-safe', (req, data) async {
      String uuid = data.fields['uuid']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      try {
        String content = await storage.readAsString();
        return APIResponse.success(data: {
          'preview': content.substring(0, content.length > 200 ? 200 : content.length)
        });
      } catch (e) {
        logger.e(e);
        // SAFE_SINK: PLANTED-Dart-HR-215-safe
        return APIResponse.badRequest(message: 'Failed to preview storage content.');
      }
    });

    /// Import a storage's content from an external host, rather than uploading bytes
    /// directly via /create -- useful for an admin-triggered mirror of an already-existing
    /// asset (e.g. re-importing an attachment from another RPMTW deployment after a
    /// migration). The target is supplied as separate host/path fields rather than one
    /// full URL, matching how a structured-field client would call this.
    router.postRoute('/import', (req, data) async {
      final String host = data.fields['host']!;
      final String path = data.fields['path']!;

      final String sourceUrl = 'https://$host$path';

      Storage? storage = await Storage.importFromUrl(sourceUrl);
      if (storage == null) {
        return APIResponse.badRequest(message: 'Failed to import storage content');
      }

      return APIResponse.success(data: storage.outputMap());
    },
        requiredFields: ['host', 'path'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same import, safe variant.
    router.postRoute('/importSafe', (req, data) async {
      final String host = data.fields['host']!;
      final String path = data.fields['path']!;

      final String sourceUrl = 'https://$host$path';

      Storage? storage = await Storage.importFromUrlSafe(sourceUrl);
      if (storage == null) {
        return APIResponse.badRequest(message: 'Failed to import storage content');
      }

      return APIResponse.success(data: storage.outputMap());
    },
        requiredFields: ['host', 'path'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Admin storage-cleanup search: lets an admin filter storages by an arbitrary criteria
    /// map, including a Map-shaped value for range-style filtering (e.g. a createAt window).
    router.postRoute('/admin-search', (req, data) async {
      final Map<String, dynamic> criteria = data.fields['criteria'] ?? {};

      List<Storage> storages = await Storage.adminSearch(criteria);

      return APIResponse.success(
          data: storages.map((s) => s.outputMap()).toList());
    }, requiredFields: ['criteria'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Admin malware scan: vets a storage's content against [scanProfile]'s ruleset before
    /// it's promoted out of temp storage or re-served to other users (e.g. after a
    /// federation mirror import via [Storage.importFromUrl]). See
    /// [SystemHandler.scanStorageForMalware].
    router.postRoute('/<uuid>/admin-scan', (req, data) async {
      String uuid = data.fields['uuid']!;
      String scanProfile = data.fields['scanProfile']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      ProcessResult result =
          await SystemHandler.scanStorageForMalware(storage, scanProfile);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'output': result.stdout.toString(),
      });
    },
        requiredFields: ['scanProfile'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same malware scan, safe variant.
    router.postRoute('/<uuid>/admin-scan-safe', (req, data) async {
      String uuid = data.fields['uuid']!;
      String scanProfile = data.fields['scanProfile']!;
      Storage? storage = await Storage.getByUUID(uuid);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      ProcessResult result =
          await SystemHandler.scanStorageForMalwareSafe(storage, scanProfile);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'output': result.stdout.toString(),
      });
    },
        requiredFields: ['scanProfile'],
        authConfig: AuthConfig(role: UserRoleType.admin));
  }
}
