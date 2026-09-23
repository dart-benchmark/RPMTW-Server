import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/index_fields.dart';
import 'package:rpmtw_server/database/model_field.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/database/models/translate/mod_source_info.dart';
import 'package:rpmtw_server/database/models/translate/source_text.dart';

/// Represents the source language file in a text format.
class SourceFile extends DBModel {
  static const String collectionName = 'source_files';
  static const List<IndexField> indexFields = [
    IndexField('modSourceInfoUUID', unique: false),
    IndexField('textUUIDs', unique: false),
  ];

  final String modSourceInfoUUID;
  final String storageUUID;
  final String path;
  final SourceFileType type;

  /// [SourceText] included in the file.
  final List<String> textUUIDs;

  Future<ModSourceInfo?> get sourceInfo =>
      ModSourceInfo.getByUUID(modSourceInfoUUID);

  Future<Storage?> get storage => Storage.getByUUID(storageUUID);

  Future<List<SourceText>> get sourceTexts async {
    List<SourceText> result = [];
    for (String uuid in textUUIDs) {
      SourceText? text = await SourceText.getByUUID(uuid);
      if (text == null) {
        throw Exception('SourceText not found, uuid: $uuid');
      }
      result.add(text);
    }
    return result;
  }

  const SourceFile(
      {required String uuid,
      required this.modSourceInfoUUID,
      required this.storageUUID,
      required this.path,
      required this.type,
      required this.textUUIDs})
      : super(uuid: uuid);

  SourceFile copyWith({
    String? modSourceInfoUUID,
    String? storageUUID,
    String? path,
    SourceFileType? type,
    List<String>? textUUIDs,
  }) {
    return SourceFile(
      uuid: uuid,
      modSourceInfoUUID: modSourceInfoUUID ?? this.modSourceInfoUUID,
      storageUUID: storageUUID ?? this.storageUUID,
      path: path ?? this.path,
      type: type ?? this.type,
      textUUIDs: textUUIDs ?? this.textUUIDs,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'modSourceInfoUUID': modSourceInfoUUID,
      'storageUUID': storageUUID,
      'path': path,
      'type': type.name,
      'textUUIDs': textUUIDs,
    };
  }

  @override
  Future<WriteResult> delete({bool deleteDependencies = true}) async {
    if (deleteDependencies) {
      final List<SourceText> texts = await sourceTexts;

      for (final text in texts) {
        await text.delete();
      }

      Storage? _storage = await storage;
      if (_storage != null) {
        _storage = _storage.copyWith(
            type: StorageType.general,
            usageCount: _storage.usageCount > 0 ? _storage.usageCount - 1 : 0);
        await _storage.update();
      }
    }

    return super.delete();
  }

  factory SourceFile.fromMap(Map<String, dynamic> map) {
    return SourceFile(
      uuid: map['uuid'],
      modSourceInfoUUID: map['modSourceInfoUUID'],
      storageUUID: map['storageUUID'],
      path: map['path'],
      type: SourceFileType.values.byName(map['type']),
      textUUIDs: List<String>.from(map['textUUIDs']),
    );
  }

  static Future<SourceFile?> getByUUID(String uuid) =>
      DataBase.instance.getModelByUUID<SourceFile>(uuid);

  static Future<List<SourceFile>> list(
          {String? modSourceInfoUUID, int? limit, int? skip}) =>
      DataBase.instance.getModelsByField<SourceFile>([
        if (modSourceInfoUUID != null)
          ModelField('modSourceInfoUUID', modSourceInfoUUID)
      ], limit: limit, skip: skip);

  /// Fetches the request's [SourceFileImportRequest.sourceUrl] and stores its content as a
  /// new [Storage]-backed [SourceFile], so a translation source can be mirrored directly
  /// from wherever the mod's own upstream lang file already lives, instead of round
  /// tripping the bytes through the client via /storage/create first (see the
  /// `/source-file/import` route).
  static Future<SourceFile?> importFromRequest(
      SourceFileImportRequest request) async {
    final http.Response response =
        // SINK: PLANTED-Dart-HR-227
        await http.get(Uri.parse(request.sourceUrl));

    if (response.statusCode != 200) {
      return null;
    }

    Storage storage = Storage(
        type: StorageType.general,
        contentType:
            response.headers['content-type'] ?? 'text/plain; charset=utf-8',
        uuid: Uuid().v4(),
        createAt: RPMTWUtil.getUTCTime());

    GridIn gridIn = DataBase.instance.gridFS
        .createFile(Stream.value(response.bodyBytes), storage.uuid);
    await gridIn.save();
    await storage.insert();

    SourceFile file = SourceFile(
        uuid: Uuid().v4(),
        modSourceInfoUUID: request.modSourceInfoUUID,
        storageUUID: storage.uuid,
        path: request.path,
        type: request.type,
        textUUIDs: []);

    await file.insert();
    return file;
  }

  /// Same import, safe variant: only honors [SourceFileImportRequest.sourceUrl] when its
  /// host is on the small, fixed allowlist of trusted upstream source hosts (raw GitHub
  /// content and the CurseForge CDN) -- sound here because a translation source file
  /// legitimately only ever needs to come from one of a known, small set of hosts, unlike
  /// a general-purpose fetch feature. Must NOT fire for any other host.
  static Future<SourceFile?> importFromRequestSafe(
      SourceFileImportRequest request) async {
    final Uri url = Uri.parse(request.sourceUrl);
    const List<String> trustedSourceHosts = [
      'raw.githubusercontent.com',
      'media.forgecdn.net',
    ];

    if (!trustedSourceHosts.contains(url.host)) {
      return null;
    }

    final http.Response response =
        // SAFE_SINK: PLANTED-Dart-HR-227-safe
        await http.get(url);

    if (response.statusCode != 200) {
      return null;
    }

    Storage storage = Storage(
        type: StorageType.general,
        contentType:
            response.headers['content-type'] ?? 'text/plain; charset=utf-8',
        uuid: Uuid().v4(),
        createAt: RPMTWUtil.getUTCTime());

    GridIn gridIn = DataBase.instance.gridFS
        .createFile(Stream.value(response.bodyBytes), storage.uuid);
    await gridIn.save();
    await storage.insert();

    SourceFile file = SourceFile(
        uuid: Uuid().v4(),
        modSourceInfoUUID: request.modSourceInfoUUID,
        storageUUID: storage.uuid,
        path: request.path,
        type: request.type,
        textUUIDs: []);

    await file.insert();
    return file;
  }
}

/// Request DTO for [SourceFile.importFromRequest]/[SourceFile.importFromRequestSafe] --
/// carries the caller-supplied [sourceUrl] from the route handler across to the model
/// method that actually dials it, exactly as the caller supplied it.
class SourceFileImportRequest {
  final String modSourceInfoUUID;
  final String sourceUrl;
  final String path;
  final SourceFileType type;

  const SourceFileImportRequest({
    required this.modSourceInfoUUID,
    required this.sourceUrl,
    required this.path,
    required this.type,
  });
}

enum SourceFileType {
  /// Localized file format used in versions 1.13 and above
  gsonLang,

  /// Localized file format used in versions below 1.12 (inclusive)
  minecraftLang,
  patchouli,

  /// Plain text format
  /// Each line of text is a source entry, and the key in the source entry uses the md5 hash value of the source content
  plainText,

  /// Custom json format
  /// e.g. Tinkers Construct book...
  customJson
}
