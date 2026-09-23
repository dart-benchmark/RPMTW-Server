import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/models/minecraft/relation_mod.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_mod.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version.dart';
import 'package:rpmtw_server/database/models/minecraft/mod_integration.dart';
import 'package:rpmtw_server/database/models/minecraft/mod_side.dart';
import 'package:rpmtw_server/database/models/minecraft/rpmwiki/wiki_change_log.dart';

class MinecraftHeader {
  static Future<ModRequestBodyParsedResult> parseModRequestBody(
      Map<String, dynamic> body) async {
    String? name = body['name'];

    List<MinecraftVersion>? supportedVersions;
    try {
      supportedVersions = await MinecraftVersion.getByIDs(
          body['supportVersions']!.cast<String>());
    } catch (e) {
      supportedVersions = null;
    }

    String? id = body['id'];
    String? description = body['description'];
    List<RelationMod>? relationMods = body['relationMods'] != null
        ? List<RelationMod>.from(
            body['relationMods']!.map((x) => RelationMod.fromMap(x)))
        : null;
    ModIntegrationPlatform? integration = body['integration'] != null
        ? ModIntegrationPlatform.fromMap(body['integration'])
        : null;
    List<ModSide>? side = body['side'] != null
        ? List<ModSide>.from(
            body['side']!.map((x) => ModSide.fromMap(x)).toList())
        : null;
    List<ModLoader>? loader = body['loader'] != null
        ? List<ModLoader>.from(
            body['loader']?.map((x) => ModLoader.values.byName(x)))
        : null;
    String? translatedName = body['translatedName'];
    String? introduction = body['introduction'];
    String? imageStorageUUID = body['imageStorageUUID'];

    return ModRequestBodyParsedResult(
        name: name,
        supportVersions: supportedVersions,
        id: id,
        description: description,
        relationMods: relationMods,
        integration: integration,
        side: side,
        loader: loader,
        translatedName: translatedName,
        introduction: introduction,
        imageStorageUUID: imageStorageUUID);
  }

  static Future<MinecraftMod> createMod(
      ModRequestBodyParsedResult result) async {
    DateTime nowTime = RPMTWUtil.getUTCTime();

    MinecraftMod mod = MinecraftMod(
        uuid: Uuid().v4(),
        name: result.name!,
        id: result.id,
        description: result.description,
        supportVersions: result.supportVersions!,
        relationMods: result.relationMods ?? [],
        integration: result.integration ?? ModIntegrationPlatform(),
        side: result.side ?? [],
        lastUpdate: nowTime,
        createTime: nowTime,
        loader: result.loader,
        translatedName: result.translatedName,
        introduction: result.introduction,
        imageStorageUUID: result.imageStorageUUID,
        viewCount: 0);

    await mod.insert();
    return mod;
  }

  /// Import a mod definition mirrored from a federated RPMTW instance, preserving its
  /// original [importedUUID] so relation links from that mirror keep resolving after a
  /// sync (unlike [createMod], which always mints a fresh uuid).
  static Future<MinecraftMod> importMod(
      ModRequestBodyParsedResult result, String importedUUID) async {
    DateTime nowTime = RPMTWUtil.getUTCTime();

    MinecraftMod mod = MinecraftMod(
        uuid: importedUUID,
        name: result.name!,
        id: result.id,
        description: result.description,
        supportVersions: result.supportVersions!,
        relationMods: result.relationMods ?? [],
        integration: result.integration ?? ModIntegrationPlatform(),
        side: result.side ?? [],
        lastUpdate: nowTime,
        createTime: nowTime,
        loader: result.loader,
        translatedName: result.translatedName,
        introduction: result.introduction,
        imageStorageUUID: result.imageStorageUUID,
        viewCount: 0);

    await mod.insert();
    return mod;
  }

  /// Fetches a mod-definition JSON body from another RPMTW federation instance, retrying
  /// a transient failure a bounded number of times before giving up -- federation
  /// partners occasionally return a brief 5xx during their own rolling deploys.
  static Future<Map<String, dynamic>?> _fetchFederationModJson(String url,
      {int attempt = 0}) async {
    const int maxAttempts = 3;

    try {
      final http.Response response =
          // SINK: PLANTED-Dart-HR-228
          await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        return jsonDecode(response.body).cast<String, dynamic>();
      }

      if (attempt + 1 >= maxAttempts) {
        return null;
      }

      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      return _fetchFederationModJson(url, attempt: attempt + 1);
    } catch (e) {
      if (attempt + 1 >= maxAttempts) {
        return null;
      }
      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      return _fetchFederationModJson(url, attempt: attempt + 1);
    }
  }

  /// Same federation fetch, safe variant: only retries/dials [url] when its host is on the
  /// operator-configured trusted-federation-partners allowlist. Must NOT fire for any
  /// other host.
  static Future<Map<String, dynamic>?> _fetchFederationModJsonSafe(String url,
      {int attempt = 0}) async {
    const int maxAttempts = 3;
    const List<String> trustedFederationHosts = [
      'federation.rpmtw.com',
      'federation-eu.rpmtw.com',
    ];

    final Uri parsed = Uri.parse(url);
    if (!trustedFederationHosts.contains(parsed.host)) {
      return null;
    }

    try {
      final http.Response response =
          // SAFE_SINK: PLANTED-Dart-HR-228-safe
          await http.get(parsed);

      if (response.statusCode == 200) {
        return jsonDecode(response.body).cast<String, dynamic>();
      }

      if (attempt + 1 >= maxAttempts) {
        return null;
      }

      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      return _fetchFederationModJsonSafe(url, attempt: attempt + 1);
    } catch (e) {
      if (attempt + 1 >= maxAttempts) {
        return null;
      }
      await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      return _fetchFederationModJsonSafe(url, attempt: attempt + 1);
    }
  }

  /// Import a mod definition fetched from an external federation instance's own JSON API,
  /// rather than accepting the already-parsed JSON body directly from the caller (unlike
  /// [importMod] above).
  static Future<MinecraftMod?> importModFromFederationUrl(
      String federationUrl, String importedUUID) async {
    final Map<String, dynamic>? body =
        await _fetchFederationModJson(federationUrl);
    if (body == null) return null;

    ModRequestBodyParsedResult result = await parseModRequestBody(body);
    if (result.name == null ||
        result.name!.isEmpty ||
        result.supportVersions == null ||
        result.supportVersions!.isEmpty) {
      return null;
    }

    return importMod(result, importedUUID);
  }

  /// Same federation import, safe variant.
  static Future<MinecraftMod?> importModFromFederationUrlSafe(
      String federationUrl, String importedUUID) async {
    final Map<String, dynamic>? body =
        await _fetchFederationModJsonSafe(federationUrl);
    if (body == null) return null;

    ModRequestBodyParsedResult result = await parseModRequestBody(body);
    if (result.name == null ||
        result.name!.isEmpty ||
        result.supportVersions == null ||
        result.supportVersions!.isEmpty) {
      return null;
    }

    return importMod(result, importedUUID);
  }

  /// **[sort]** 排序方式
  /// 0 按照時間排序
  /// 1 按照瀏覽次數排序
  /// 2 按照模組名稱排序
  /// 3 按照最後修改日期排序
  static Future<List<MinecraftMod>> searchMods(
      {String? filter,
      Map<String, dynamic>? extraCriteria,
      int? limit,
      int? skip,
      int sort = 0}) async {
    limit ??= 50;
    skip ??= 0;
    if (limit > 50) {
      /// 最多搜尋 50 筆資料
      limit = 50;
    }

    SelectorBuilder selector = SelectorBuilder();
    if (filter != null) {
      /// search by name or id
      selector = selector
          .match('id', filter)
          .or(where.match('name', '(?i)$filter'))
          .or(where.match('translatedName', '(?i)$filter'));
    }

    /// Admin curation tool: filter mods by any additional field (e.g. loader, side, an
    /// unapproved-status flag) beyond the public name/id search above.
    if (extraCriteria != null) {
      for (final key in extraCriteria.keys) {
        // SINK: PLANTED-Dart-HR-93
        selector.eq(key, extraCriteria[key]);
      }
    }

    selector.limit(limit).skip(skip);

    if (sort == 0) {
      selector.sortBy('createTime', descending: true);
    } else if (sort == 1) {
      selector.sortBy('viewCount', descending: true);
    } else if (sort == 2) {
      selector.sortBy('name', descending: true);
    } else if (sort == 3) {
      selector.sortBy('lastUpdate', descending: true);
    }

    return DataBase.instance.getModelsWithSelector<MinecraftMod>(selector);
  }

  /// Same admin curation search, safe variant: every extra-criteria value is coerced to a
  /// scalar String before being used as a selector value. Must NOT allow an operator-shaped
  /// value through.
  static Future<List<MinecraftMod>> searchModsSafe(
      {String? filter,
      Map<String, dynamic>? extraCriteria,
      int? limit,
      int? skip}) async {
    limit ??= 50;
    skip ??= 0;
    if (limit > 50) {
      limit = 50;
    }

    SelectorBuilder selector = SelectorBuilder();
    if (filter != null) {
      selector = selector
          .match('id', filter)
          .or(where.match('name', '(?i)$filter'))
          .or(where.match('translatedName', '(?i)$filter'));
    }

    if (extraCriteria != null) {
      for (final key in extraCriteria.keys) {
        final dynamic value = extraCriteria[key];
        final String scalarValue = value is String ? value : value.toString();
        // SAFE_SINK: PLANTED-Dart-HR-93-safe
        selector.eq(key, scalarValue);
      }
    }

    selector.limit(limit).skip(skip);

    return DataBase.instance.getModelsWithSelector<MinecraftMod>(selector);
  }

  static Future<List<WikiChangeLog>> filterChangelogs(
      {int? limit, int? skip, String? dataUUID, String? userUUID}) async {
    limit ??= 50;
    skip ??= 0;
    if (limit > 50) {
      /// 最多搜尋 50 筆資料
      limit = 50;
    }

    SelectorBuilder selector = SelectorBuilder();

    if (dataUUID != null && dataUUID.isNotEmpty) {
      selector.eq('dataUUID', dataUUID);
    }
    if (userUUID != null && userUUID.isNotEmpty) {
      selector.eq('userUUID', userUUID);
    }

    selector.limit(limit).skip(skip);

    return await DataBase.instance
        .getModelsWithSelector<WikiChangeLog>(selector);
  }
}

class ModRequestBodyParsedResult {
  final String? name;
  final List<MinecraftVersion>? supportVersions;
  final String? id;
  final String? description;
  final List<RelationMod>? relationMods;
  final ModIntegrationPlatform? integration;
  final List<ModSide>? side;
  final List<ModLoader>? loader;
  final String? translatedName;
  final String? introduction;
  final String? imageStorageUUID;

  ModRequestBodyParsedResult({
    this.name,
    this.supportVersions,
    this.id,
    this.description,
    this.relationMods,
    this.integration,
    this.side,
    this.loader,
    this.translatedName,
    this.introduction,
    this.imageStorageUUID,
  });
}
