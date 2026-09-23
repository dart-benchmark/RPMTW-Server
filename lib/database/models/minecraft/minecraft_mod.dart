import 'dart:convert';

import 'package:rpmtw_server/database/database.dart';

import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/index_fields.dart';
import 'package:rpmtw_server/database/models/minecraft/relation_mod.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version.dart';
import 'package:rpmtw_server/database/models/minecraft/mod_integration.dart';
import 'package:rpmtw_server/database/models/minecraft/mod_side.dart';
import 'package:rpmtw_server/utilities/memcache_client.dart';

class MinecraftMod extends DBModel {
  static const String collectionName = 'minecraft_mods';
  static const List<IndexField> indexFields = [
    IndexField('name', unique: false),
    IndexField('id', unique: false),
    IndexField('integration', unique: false),
    IndexField('translatedName', unique: false),
    IndexField('viewCount', unique: false),
  ];

  /// 模組的名稱 (尚未翻譯的原始名稱)
  final String name;

  /// 模組描述
  final String? description;

  /// 模組 ID (例如 rpmtw_update_mod )
  final String? id;

  /// 模組支援的 Minecraft 版本
  final List<MinecraftVersion> supportVersions;

  /// 關聯模組
  final List<RelationMod> relationMods;

  /// 模組串連的平台 (例如 CurseForge、Modrinth...)
  final ModIntegrationPlatform integration;

  /// 模組支援的執行環境 (客戶端/伺服器端)
  final List<ModSide> side;

  /// 模組使用的模組載入器 (例如 Forge、Fabric...)
  final List<ModLoader>? loader;

  /// 最後資料更新日期
  final DateTime lastUpdate;

  /// 模組收錄日期
  final DateTime createTime;

  /// 已翻譯過的模組名稱
  final String? translatedName;

  /// 模組的介紹文章 (Markdown 格式)
  final String? introduction;

  /// 模組的封面圖 (Storage UUID)
  final String? imageStorageUUID;

  /// 模組瀏覽次數
  final int viewCount;

  const MinecraftMod(
      {required this.name,
      this.description,
      this.loader,
      required this.id,
      required this.supportVersions,
      required this.relationMods,
      required this.integration,
      required this.side,
      required this.lastUpdate,
      required this.createTime,
      this.translatedName,
      this.introduction,
      this.imageStorageUUID,
      this.viewCount = 0,
      required String uuid})
      : super(uuid: uuid);

  MinecraftMod copyWith({
    String? name,
    String? description,
    String? id,
    List<MinecraftVersion>? supportVersions,
    List<RelationMod>? relationMods,
    ModIntegrationPlatform? integration,
    List<ModSide>? side,
    DateTime? lastUpdate,
    List<ModLoader>? loader,
    DateTime? createTime,
    String? translatedName,
    String? introduction,
    String? imageStorageUUID,
    int? viewCount,
  }) {
    return MinecraftMod(
      uuid: uuid,
      name: name ?? this.name,
      description: description ?? this.description,
      id: id ?? this.id,
      supportVersions: supportVersions ?? this.supportVersions,
      relationMods: relationMods ?? this.relationMods,
      integration: integration ?? this.integration,
      side: side ?? this.side,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      createTime: createTime ?? this.createTime,
      loader: loader ?? this.loader,
      translatedName: translatedName ?? this.translatedName,
      introduction: introduction ?? this.introduction,
      imageStorageUUID: imageStorageUUID ?? this.imageStorageUUID,
      viewCount: viewCount ?? this.viewCount,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'name': name,
      'description': description,
      'id': id,
      'supportVersions': supportVersions.map((x) => x.toMap()).toList(),
      'relationMods': relationMods.map((x) => x.toMap()).toList(),
      'integration': integration.toMap(),
      'side': side.map((x) => x.toMap()).toList(),
      'lastUpdate': lastUpdate.millisecondsSinceEpoch,
      'createTime': createTime.millisecondsSinceEpoch,
      'loader': loader?.map((x) => x.name).toList(),
      'translatedName': translatedName,
      'introduction': introduction,
      'imageStorageUUID': imageStorageUUID,
      'viewCount': viewCount,
    };
  }

  factory MinecraftMod.fromMap(Map<String, dynamic> map) {
    return MinecraftMod(
      uuid: map['uuid'] as String,
      name: map['name'],
      description: map['description'],
      id: map['id'],
      supportVersions: List<MinecraftVersion>.from(
          map['supportVersions']?.map((x) => MinecraftVersion.fromMap(x))),
      relationMods: List<RelationMod>.from(
          map['relationMods']?.map((x) => RelationMod.fromMap(x))),
      integration: ModIntegrationPlatform.fromMap(map['integration']),
      side: List<ModSide>.from(map['side']?.map((x) => ModSide.fromMap(x))),
      lastUpdate:
          DateTime.fromMillisecondsSinceEpoch(map['lastUpdate'], isUtc: true),
      createTime:
          DateTime.fromMillisecondsSinceEpoch(map['createTime'], isUtc: true),
      loader: List<ModLoader>.from(
          map['loader']?.map((x) => ModLoader.values.byName(x)) ?? []),
      translatedName: map['translatedName'],
      introduction: map['introduction'],
      imageStorageUUID: map['imageStorageUUID'],
      viewCount: map['viewCount'] ?? 0,
    );
  }

  static Future<MinecraftMod?> getByUUID(String uuid) async =>
      DataBase.instance.getModelByUUID<MinecraftMod>(uuid);

  static Future<MinecraftMod?> getByModID(String id) async =>
      DataBase.instance.getModelByField<MinecraftMod>('id', id);

  static Future<MinecraftMod?> getByTranslatedName(
          String translatedName) async =>
      DataBase.instance
          .getModelByField<MinecraftMod>('translatedName', translatedName);

  /// Cache-aside lookup for the `/mod/view/<uuid>` hot path -- mods are viewed far more
  /// often than they're edited, so a shared memcache tier in front of the Mongo lookup
  /// meaningfully cuts DB load once more than one server instance is running.
  static Future<MinecraftMod?> getCachedOrNull(String uuid) async {
    final MemcacheClient cache = MemcacheClient();
    final StringBuffer keyBuilder = StringBuffer('rpmtw:mod:');
    keyBuilder.write(uuid);
    final String key = keyBuilder.toString();
    // SINK: PLANTED-Dart-HR-207
    final String? raw = await cache.get(key);
    if (raw == null) return null;
    try {
      return MinecraftMod.fromMap(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> storeCached(MinecraftMod mod) async {
    final StringBuffer keyBuilder = StringBuffer('rpmtw:mod:');
    keyBuilder.write(mod.uuid);
    await MemcacheClient()
        .set(keyBuilder.toString(), jsonEncode(mod.toMap()), ttlSeconds: 60);
  }

  /// Same cache-aside lookup, safe variant: the uuid is stripped of control characters and
  /// whitespace before it's used to build the cache key. Must NOT fire.
  static Future<MinecraftMod?> getCachedOrNullSafe(String uuid) async {
    final MemcacheClient cache = MemcacheClient();
    final String safeUuid = uuid.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
    final StringBuffer keyBuilder = StringBuffer('rpmtw:mod:');
    keyBuilder.write(safeUuid);
    final String key = keyBuilder.toString();
    // SAFE_SINK: PLANTED-Dart-HR-207-safe
    final String? raw = await cache.get(key);
    if (raw == null) return null;
    try {
      return MinecraftMod.fromMap(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> storeCachedSafe(MinecraftMod mod) async {
    final String safeUuid = mod.uuid.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
    final StringBuffer keyBuilder = StringBuffer('rpmtw:mod:');
    keyBuilder.write(safeUuid);
    await MemcacheClient()
        .set(keyBuilder.toString(), jsonEncode(mod.toMap()), ttlSeconds: 60);
  }
}

enum ModLoader { fabric, forge, other }
