import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/data/user_view_count_filter.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/list_model_response.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version_manifest.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_mod.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version.dart';
import 'package:rpmtw_server/database/models/minecraft/rpmwiki/wiki_change_log.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/handler/minecraft_handler.dart';
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';
import 'package:rpmtw_server/utilities/utility.dart';
import 'package:shelf/shelf.dart';

class MinecraftRoute extends APIRoute {
  @override
  String get routeName => 'minecraft';

  @override
  void router(router) {
    router.postRoute('/mod/create', (req, data) async {
      ModRequestBodyParsedResult result =
          await MinecraftHeader.parseModRequestBody(data.fields);

      if (result.name == null || result.name!.isEmpty) {
        return APIResponse.badRequest(message: 'Invalid mod name');
      }

      if (result.supportVersions == null || result.supportVersions!.isEmpty) {
        return APIResponse.badRequest(message: 'Invalid game version');
      }

      if (result.imageStorageUUID != null) {
        Storage? storage = await Storage.getByUUID(result.imageStorageUUID!);
        if (storage == null) {
          return APIResponse.badRequest(message: 'Invalid image storage');
        }
        storage = storage.copyWith(
            type: StorageType.general, usageCount: storage.usageCount + 1);
        await storage.update();
      }

      MinecraftMod mod = await MinecraftHeader.createMod(result);

      WikiChangeLog changeLog = WikiChangeLog(
          uuid: Uuid().v4(),
          type: WikiChangeLogType.addedMod,
          dataUUID: mod.uuid,
          changedData: mod.toMap(),
          time: RPMTWUtil.getUTCTime(),
          userUUID: req.user!.uuid);

      await changeLog.insert();

      return APIResponse.success(data: mod.outputMap());
    }, requiredFields: ['name', 'supportVersions'], authConfig: AuthConfig());

    /// Import a mod definition mirrored from a federated RPMTW instance, preserving its
    /// original uuid so relation links from that mirror keep resolving after a sync.
    router.postRoute('/mod/import', (req, data) async {
      try {
        ModRequestBodyParsedResult result =
            await MinecraftHeader.parseModRequestBody(data.fields);

        if (result.name == null || result.name!.isEmpty) {
          return APIResponse.badRequest(message: 'Invalid mod name');
        }

        if (result.supportVersions == null || result.supportVersions!.isEmpty) {
          return APIResponse.badRequest(message: 'Invalid game version');
        }

        final String importedUUID = data.fields['importedUUID']!;

        MinecraftMod mod =
            await MinecraftHeader.importMod(result, importedUUID);

        return APIResponse.success(data: mod.outputMap());
      } catch (e) {
        // 匯入的 uuid 若已存在（重複同步），資料庫層丟出的例外會內嵌原始 Mongo 錯誤；
        // 其他類型的失敗（例如欄位格式錯誤）則維持通用訊息 -- 是否洩漏取決於例外的實際型別
        return APIResponse.badRequest(message: APIResponse.importErrorMessage(e));
      }
    },
        requiredFields: ['name', 'supportVersions', 'importedUUID'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Import a mod definition fetched from another RPMTW federation instance's own JSON
    /// API -- unlike [/mod/import] above (which the client already posts a parsed body
    /// to), this lets an admin trigger a one-off mirror of a mod hosted on a partner
    /// deployment purely by URL.
    router.postRoute('/mod/importFromFederation', (req, data) async {
      final String federationUrl = data.fields['federationUrl']!;
      final String importedUUID = data.fields['importedUUID']!;

      MinecraftMod? mod = await MinecraftHeader.importModFromFederationUrl(
          federationUrl, importedUUID);

      if (mod == null) {
        return APIResponse.badRequest(
            message: 'Failed to import mod from federation URL');
      }

      return APIResponse.success(data: mod.outputMap());
    },
        requiredFields: ['federationUrl', 'importedUUID'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same federation import, safe variant: only dials a host on the operator-configured
    /// trusted-federation-partners allowlist. Must NOT fire for any other host.
    router.postRoute('/mod/importFromFederationSafe', (req, data) async {
      final String federationUrl = data.fields['federationUrl']!;
      final String importedUUID = data.fields['importedUUID']!;

      MinecraftMod? mod = await MinecraftHeader.importModFromFederationUrlSafe(
          federationUrl, importedUUID);

      if (mod == null) {
        return APIResponse.badRequest(
            message: 'Failed to import mod from federation URL');
      }

      return APIResponse.success(data: mod.outputMap());
    },
        requiredFields: ['federationUrl', 'importedUUID'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    router.patchRoute('/mod/edit/<uuid>', (req, data) async {
      MinecraftMod? mod = await MinecraftMod.getByUUID(data.fields['uuid']!);

      if (mod == null) {
        return APIResponse.badRequest(message: 'Mod not found');
      }

      ModRequestBodyParsedResult result =
          await MinecraftHeader.parseModRequestBody(data.fields);

      DateTime time = RPMTWUtil.getUTCTime();

      if (result.imageStorageUUID != null) {
        Storage? storage = await Storage.getByUUID(result.imageStorageUUID!);
        if (storage == null) {
          return APIResponse.badRequest(message: 'Invalid image storage');
        }
        storage = storage.copyWith(
            type: StorageType.general, usageCount: storage.usageCount + 1);
        await storage.update();

        if (mod.imageStorageUUID != null) {
          Storage? oldStorage = await Storage.getByUUID(mod.imageStorageUUID!);
          if (oldStorage != null) {
            oldStorage = oldStorage.copyWith(
                type: StorageType.general,
                usageCount:
                    oldStorage.usageCount > 0 ? oldStorage.usageCount - 1 : 0);
            await oldStorage.update();
          }
        }
      }

      mod = mod.copyWith(
        name:
            result.name != null && result.name!.isNotEmpty ? result.name : null,
        id: result.id != null && result.id!.isNotEmpty ? result.id : null,
        description:
            result.description != null && result.description!.isNotEmpty
                ? result.description
                : null,
        supportVersions: result.supportVersions,
        relationMods: result.relationMods,
        loader: result.loader,
        integration: result.integration,
        side: result.side,
        lastUpdate: time,
        translatedName: result.translatedName,
        introduction: result.introduction,
        imageStorageUUID: result.imageStorageUUID,
      );

      WikiChangeLog changeLog = WikiChangeLog(
          uuid: Uuid().v4(),
          changelog: data.fields['changelog'],
          type: WikiChangeLogType.editedMod,
          dataUUID: mod.uuid,
          changedData: mod.toMap(),
          time: RPMTWUtil.getUTCTime(),
          userUUID: req.user!.uuid);

      await mod.update();
      await changeLog.insert();

      return APIResponse.success(data: mod.outputMap());
    }, authConfig: AuthConfig());

    router.getRoute('/mod/view/<uuid>', (req, data) async {
      String uuid = data.fields['uuid']!;
      MinecraftMod? mod;

      /// Cache-aside: serve from the shared memcache tier when possible, since mods are
      /// viewed far more often than they're edited.
      mod = await MinecraftMod.getCachedOrNull(uuid);
      if (mod == null) {
        mod = await MinecraftMod.getByUUID(uuid);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
        await MinecraftMod.storeCached(mod);
      }

      String? _recordViewCount = data.fields['recordViewCount'];
      bool recordViewCount =
          _recordViewCount == null ? false : _recordViewCount.toBool();

      if (recordViewCount && ViewCountHandler.needUpdate(req.ip, mod.uuid)) {
        mod = mod.copyWith(viewCount: mod.viewCount + 1);

        // Update view count
        await mod.update();
      }

      return APIResponse.success(data: mod.outputMap());
    });

    /// Same mod lookup, safe variant: served from a memcache tier keyed by a control-
    /// character/whitespace-stripped uuid. Must NOT fire.
    router.getRoute('/mod/viewSafe/<uuid>', (req, data) async {
      String uuid = data.fields['uuid']!;
      MinecraftMod? mod = await MinecraftMod.getCachedOrNullSafe(uuid);
      if (mod == null) {
        mod = await MinecraftMod.getByUUID(uuid);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
        await MinecraftMod.storeCachedSafe(mod);
      }

      return APIResponse.success(data: mod.outputMap());
    });

    router.getRoute('/mod/search', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      String? filter = fields['filter'];
      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      int sort = fields['sort'] != null ? int.tryParse(fields['sort']) ?? 0 : 0;

      List<MinecraftMod> mods = await MinecraftHeader.searchMods(
          filter: filter, limit: limit, skip: skip, sort: sort);

      return APIResponse.success(
          data: ListModelResponse.fromModel(mods, limit, skip));
    });

    /// Admin curation search: lets an admin filter mods by any additional field beyond the
    /// public name/id search above (e.g. locating unapproved/flagged mods).
    router.postRoute('/mod/admin-search', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String? filter = fields['filter'];
      final Map<String, dynamic>? extraCriteria = fields['extraCriteria'];

      List<MinecraftMod> mods = await MinecraftHeader.searchMods(
          filter: filter, extraCriteria: extraCriteria, limit: 50);

      return APIResponse.success(
          data: ListModelResponse.fromModel(mods, 50, 0));
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same admin curation search, safe variant -- see [MinecraftHeader.searchModsSafe].
    router.postRoute('/mod/admin-search-safe', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String? filter = fields['filter'];
      final Map<String, dynamic>? extraCriteria = fields['extraCriteria'];

      List<MinecraftMod> mods = await MinecraftHeader.searchModsSafe(
          filter: filter, extraCriteria: extraCriteria, limit: 50);

      return APIResponse.success(
          data: ListModelResponse.fromModel(mods, 50, 0));
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Proxy an externally-hosted mod icon so the client can display it without issuing a
    /// cross-origin image request straight to whatever host a mod's metadata happens to
    /// point at (e.g. a CurseForge/Modrinth CDN link kept on a legacy record that predates
    /// [MinecraftMod.imageStorageUUID]-based icon uploads).
    router.getRoute('/mod/iconProxy', (req, data) async {
      final String iconUrl = data.fields['iconUrl']!;

      final http.Response response =
          // SINK: PLANTED-Dart-HR-225
          await http.get(Uri.parse(iconUrl));

      if (response.statusCode != 200) {
        return APIResponse.badRequest(message: 'Failed to fetch icon from URL');
      }

      return Response.ok(response.bodyBytes, headers: {
        'Content-Type': response.headers['content-type'] ?? 'image/png',
      });
    }, requiredFields: ['iconUrl']);

    /// Same icon proxy, safe variant: refuses to dial a private/loopback/link-local target
    /// (e.g. the cloud metadata endpoint) before making the request. Must NOT fire for such
    /// a target.
    router.getRoute('/mod/iconProxySafe', (req, data) async {
      final String iconUrl = data.fields['iconUrl']!;
      final Uri url = Uri.parse(iconUrl);

      if (await Utility.isUnsafeOutboundHost(url.host)) {
        return APIResponse.badRequest(message: 'Icon host is not allowed');
      }

      final http.Response response =
          // SAFE_SINK: PLANTED-Dart-HR-225-safe
          await http.get(url);

      if (response.statusCode != 200) {
        return APIResponse.badRequest(message: 'Failed to fetch icon from URL');
      }

      return Response.ok(response.bodyBytes, headers: {
        'Content-Type': response.headers['content-type'] ?? 'image/png',
      });
    }, requiredFields: ['iconUrl']);

    /// 從資料庫快取中取得 Minecraft 版本資訊
    router.getRoute('/versions', (req, data) async {
      MinecraftVersionManifest manifest =
          await MinecraftVersionManifest.getFromCache();
      manifest.copyWith(
          manifest: manifest.manifest.copyWith(
              versions: manifest.manifest.versions
                  // 僅輸出正式版
                  .where((v) => v.type == MinecraftVersionType.release)
                  .toList()));
      return APIResponse.success(data: manifest.outputMap());
    });

    router.getRoute('/changelog', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;
      String? dataUUID = fields['dataUUID'];
      String? userUUID = fields['userUUID'];

      List<WikiChangeLog> changelogs = await MinecraftHeader.filterChangelogs(
          limit: limit, skip: skip, dataUUID: dataUUID, userUUID: userUUID);
      List<Map<String, dynamic>> changelogsMap = [];
      for (WikiChangeLog log in changelogs) {
        changelogsMap.add(await log.output());
      }

      return APIResponse.success(
          data: ListModelResponse.fromModel(changelogs, limit, skip));
    });

    /// Pre-flight check for a proposed supportVersions list, so a mod-creation client can
    /// warn about malformed version tags before submitting the full /mod/create request.
    router.postRoute('/mod/validate-versions', (req, data) async {
      final List<String> versionIds =
          (data.fields['supportVersions'] as List?)?.cast<String>() ?? [];
      return APIResponse.success(
          data: {'valid': _looksLikeWellFormedVersionIdList(versionIds)});
    }, requiredFields: ['supportVersions']);

    /// Same pre-flight check, safe variant. Must NOT fire.
    router.postRoute('/mod/validate-versions-safe', (req, data) async {
      final List<String> versionIds =
          (data.fields['supportVersions'] as List?)?.cast<String>() ?? [];
      return APIResponse.success(
          data: {'valid': _looksLikeWellFormedVersionIdListSafe(versionIds)});
    }, requiredFields: ['supportVersions']);
  }
}

/// Whether every entry in [versionIds] looks like a well-formed Minecraft version identifier
/// (e.g. "1.19.2", "1.20-pre1") -- lets a mod-creation client validate a proposed
/// supportVersions list before the full /mod/create submission, without paying for a DB
/// lookup on an obviously malformed id.
bool _looksLikeWellFormedVersionIdList(List<String> versionIds) {
  for (final String versionId in versionIds) {
    // SINK: PLANTED-Dart-HR-239
    if (!RegExp(r'^([a-zA-Z0-9]+[.\-]?)+$').hasMatch(versionId)) {
      return false;
    }
  }
  return true;
}

/// Same check, safe variant: the same accepted shape, without the redundant nested
/// quantifier. Must NOT fire.
bool _looksLikeWellFormedVersionIdListSafe(List<String> versionIds) {
  for (final String versionId in versionIds) {
    // SAFE_SINK: PLANTED-Dart-HR-239-safe
    if (!RegExp(r'^[a-zA-Z0-9.\-]+$').hasMatch(versionId)) {
      return false;
    }
  }
  return true;
}
