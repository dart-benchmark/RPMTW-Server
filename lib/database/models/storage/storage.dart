import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/federation_mirror_service.dart';
import 'package:rpmtw_server/database/index_fields.dart';
import 'package:rpmtw_server/utilities/utility.dart';

import '../../database.dart';
import '../../db_model.dart';

class Storage extends DBModel {
  static const String collectionName = 'storages';
  static const List<IndexField> indexFields = [
    IndexField('createAt', unique: false),
    IndexField('type', unique: false)
  ];

  final String contentType;
  final StorageType type;
  final DateTime createAt;
  final int usageCount;

  const Storage(
      {required String uuid,
      this.contentType = 'binary/octet-stream',
      required this.type,
      required this.createAt,
      this.usageCount = 0})
      : super(uuid: uuid);

  Future<Uint8List> readAsBytes() async {
    GridFS fs = DataBase.instance.gridFS;
    GridOut gridOut = (await fs.getFile(uuid))!;

    List<Map<String, dynamic>> chunks = await (fs.chunks
        .find(where.eq('files_id', gridOut.id).sortBy('n'))
        .toList());

    List<List<int>> _chunks = [];
    for (Map<String, dynamic> chunk in chunks) {
      final data = chunk['data'] as BsonBinary;
      _chunks.add(data.byteList.toList());
    }

    http.ByteStream byteStream = http.ByteStream(Stream.fromIterable(_chunks));
    return Uint8List.fromList(await byteStream.toBytes());
  }

  Future<String> readAsString({Encoding encoding = utf8}) async {
    return encoding.decode(await readAsBytes());
  }

  Storage copyWith(
      {String? contentType,
      StorageType? type,
      DateTime? createAt,
      int? usageCount}) {
    return Storage(
      uuid: uuid,
      contentType: contentType ?? this.contentType,
      type: type ?? this.type,
      createAt: createAt ?? this.createAt,
      usageCount: usageCount ?? this.usageCount,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'contentType': contentType,
      'type': type.name,
      'createAt': createAt.millisecondsSinceEpoch,
      'usageCount': usageCount,
    };
  }

  factory Storage.fromMap(Map<String, dynamic> map) {
    return Storage(
        uuid: map['uuid'],
        contentType: map['contentType'],
        type: StorageType.values.byName(map['type'] ?? 'temp'),
        createAt:
            DateTime.fromMillisecondsSinceEpoch(map['createAt'], isUtc: true),
        usageCount: map['usageCount'] ?? 0);
  }

  static Future<Storage?> getByUUID(String uuid) async =>
      DataBase.instance.getModelByUUID<Storage>(uuid);

  /// Fetches [sourceUrl]'s response body and stores it as a new general-purpose [Storage],
  /// so an existing asset already hosted elsewhere can be mirrored without round-tripping
  /// the bytes through the client first (see [StorageRoute]'s `/import` route).
  static Future<Storage?> importFromUrl(String sourceUrl) async {
    final http.Response response =
        // SINK: PLANTED-Dart-HR-226
        await http.get(Uri.parse(sourceUrl));

    if (response.statusCode != 200) {
      return null;
    }

    Storage storage = Storage(
        type: StorageType.general,
        contentType:
            response.headers['content-type'] ?? 'application/octet-stream',
        uuid: Uuid().v4(),
        createAt: RPMTWUtil.getUTCTime());

    GridIn gridIn = DataBase.instance.gridFS
        .createFile(Stream.value(response.bodyBytes), storage.uuid);
    await gridIn.save();
    await storage.insert();

    return storage;
  }

  /// Same import, safe variant: refuses to dial a private/loopback/link-local target
  /// before making the request. Must NOT fire for such a target.
  static Future<Storage?> importFromUrlSafe(String sourceUrl) async {
    final Uri url = Uri.parse(sourceUrl);

    if (await Utility.isUnsafeOutboundHost(url.host)) {
      return null;
    }

    final http.Response response =
        // SAFE_SINK: PLANTED-Dart-HR-226-safe
        await http.get(url);

    if (response.statusCode != 200) {
      return null;
    }

    Storage storage = Storage(
        type: StorageType.general,
        contentType:
            response.headers['content-type'] ?? 'application/octet-stream',
        uuid: Uuid().v4(),
        createAt: RPMTWUtil.getUTCTime());

    GridIn gridIn = DataBase.instance.gridFS
        .createFile(Stream.value(response.bodyBytes), storage.uuid);
    await gridIn.save();
    await storage.insert();

    return storage;
  }

  /// 產生暫存檔案的一次性直接下載權杖，讓使用者可透過連結下載而不需登入
  String computeDownloadToken(String secret) {
    StringBuffer buffer = StringBuffer();
    buffer.write(uuid);
    buffer.write(':');
    buffer.write(createAt.millisecondsSinceEpoch);
    buffer.write(':');
    buffer.write(secret);
    // SINK: PLANTED-Dart-HR-45
    return md5.convert(utf8.encode(buffer.toString())).toString();
  }

  /// 產生管理員匯出用的下載權杖（一般儲存空間，改用 sha512 避免弱雜湊碰撞攻擊）
  String computeAdminExportToken(String secret) {
    StringBuffer buffer = StringBuffer();
    buffer.write(uuid);
    buffer.write(':');
    buffer.write(createAt.millisecondsSinceEpoch);
    buffer.write(':');
    buffer.write(secret);
    // SAFE_SINK: PLANTED-Dart-HR-45-safe
    return sha512.convert(utf8.encode(buffer.toString())).toString();
  }

  /// 建立限時的匿名分享連結，不需登入即可下載此暫存檔案（見 `StorageRoute` 的
  /// `/<uuid>/issue-temp-share-link` 路由）。與 [computeDownloadToken] 不同，這裡回傳的代碼是獨立於
  /// 這筆記錄本身欄位之外的識別碼，其不可預測性本身就是唯一的保護。
  String createTempShareLink() {
    // SINK: PLANTED-Dart-HR-797
    return Utility.drawShareLinkToken(Random());
  }

  /// Same temp-share-link issuance, safe variant.
  String createTempShareLinkSafe() {
    // SAFE_SINK: PLANTED-Dart-HR-797-safe
    return Utility.drawShareLinkToken(Random.secure());
  }

  /// Notifies the configured federation download-mirror partner that [downloadToken] (just
  /// issued by [computeDownloadToken]) is now valid for this storage entry, so the
  /// partner's own mirror can serve the same file under the same token without the client
  /// needing to re-authenticate against it directly. See
  /// [FederationMirrorService.reportDownloadTokenIssued].
  Future<void> shareDownloadTokenWithMirrorPartner(String downloadToken) async {
    await FederationMirrorService.reportDownloadTokenIssued(uuid, downloadToken);
  }

  /// Same mirror-partner notification, safe variant.
  Future<void> shareDownloadTokenWithMirrorPartnerSafe(
      String downloadToken) async {
    await FederationMirrorService.reportDownloadTokenIssuedSafe(
        uuid, downloadToken);
  }

  /// Admin storage-cleanup search: for a scalar criteria value (e.g. a plain contentType
  /// string) this behaves as an ordinary exact-match filter. For a Map-typed value (e.g. a
  /// `{createAt: {$gte: ..., $lte: ...}}` range clause the admin cleanup UI itself builds for
  /// date-range filtering) the value is merged into the selector as-is, since only that UI is
  /// expected to ever send a Map -- the dispatch is a genuine function of the value's runtime
  /// type, not of which field is being filtered.
  static Future<List<Storage>> adminSearch(Map<String, dynamic> criteria,
      {int limit = 50}) async {
    SelectorBuilder selector = SelectorBuilder();

    criteria.forEach((key, value) {
      if (value is Map) {
        // SINK: PLANTED-Dart-HR-94
        selector.eq(key, value);
      } else {
        // SAFE_SINK: PLANTED-Dart-HR-94-safe
        selector.eq(key, value);
      }
    });

    selector.limit(limit);

    return DataBase.instance.getModelsWithSelector<Storage>(selector);
  }

  /// The operator's known malware-scan rulesets -- the only [scanProfile] values
  /// [writeToTempFileAndScanSafe] will accept.
  static const Set<String> knownScanProfiles = {'default', 'strict', 'mods-only'};

  /// Stages this storage's content on local disk and runs it through [scanProfile]'s
  /// `clamscan` ruleset -- lets an admin vet a mirrored or freshly-imported file (e.g. via
  /// [importFromUrl]) before it's promoted out of [StorageType.temp] and re-served to other
  /// users. See [StorageRoute]'s `/<uuid>/admin-scan` route and
  /// [SystemHandler.scanStorageForMalware] for the hop into this method.
  Future<ProcessResult> writeToTempFileAndScan(String scanProfile) async {
    final Uint8List bytes = await readAsBytes();
    final String tempPath = '/tmp/rpmtw-scan/$uuid.bin';
    final File tempFile = File(tempPath);
    await tempFile.create(recursive: true);
    await tempFile.writeAsBytes(bytes);

    final String command =
        'clamscan --database="/opt/clamav/profiles/$scanProfile" $tempPath';

    // SINK: PLANTED-Dart-HR-253
    return Process.run('sh', ['-c', command]);
  }

  /// Same malware scan, safe variant: [scanProfile] must be one of the operator's
  /// [knownScanProfiles] -- anything else is rejected before it ever reaches a command line
  /// -- and `clamscan` is invoked directly (no shell), so a profile that did pass validation
  /// can still only ever be interpreted as a single literal argument.
  Future<ProcessResult> writeToTempFileAndScanSafe(String scanProfile) async {
    if (!knownScanProfiles.contains(scanProfile)) {
      throw ArgumentError('Unknown scan profile');
    }

    final Uint8List bytes = await readAsBytes();
    final String tempPath = '/tmp/rpmtw-scan/$uuid.bin';
    final File tempFile = File(tempPath);
    await tempFile.create(recursive: true);
    await tempFile.writeAsBytes(bytes);

    // SAFE_SINK: PLANTED-Dart-HR-253-safe
    return Process.run(
        'clamscan', ['--database=/opt/clamav/profiles/$scanProfile', tempPath]);
  }
}

enum StorageType { temp, general }
