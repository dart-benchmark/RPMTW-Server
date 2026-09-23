import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rpmtw_server/database/database.dart';

import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/index_fields.dart';

class BanInfo extends DBModel {
  static const String collectionName = 'ban_infos';
  static const List<IndexField> indexFields = [
    IndexField('ip', unique: true),
  ];

  /// 被封鎖的 IP
  final String ip;

  /// 封鎖原因
  final String reason;

  /// 使用此 IP 登入的使用者帳號 UUID
  final List<String> userUUID;

  /// 規避封鎖偵測用的裝置指紋雜湊值（由 IP 與 User-Agent 計算）
  final String? fingerprintHash;

  const BanInfo({
    required this.ip,
    required this.reason,
    required this.userUUID,
    this.fingerprintHash,
    required String uuid,
  }) : super(uuid: uuid);

  BanInfo copyWith({
    String? ip,
    String? reason,
    List<String>? userUUID,
    String? fingerprintHash,
  }) {
    return BanInfo(
      ip: ip ?? this.ip,
      reason: reason ?? this.reason,
      userUUID: userUUID ?? this.userUUID,
      fingerprintHash: fingerprintHash ?? this.fingerprintHash,
      uuid: uuid,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'ip': ip,
      'reason': reason,
      'userUUID': userUUID,
      'fingerprintHash': fingerprintHash,
      'uuid': uuid,
    };
  }

  factory BanInfo.fromMap(Map<String, dynamic> map) {
    return BanInfo(
      ip: map['ip'],
      reason: map['reason'],
      userUUID: List<String>.from(map['userUUID']),
      fingerprintHash: map['fingerprintHash'],
      uuid: map['uuid']!,
    );
  }

  static Future<BanInfo?> getByIP(String ip) async =>
      DataBase.instance.getModelByField<BanInfo>('ip', ip);

  /// 依據註冊 IP 與裝置的 User-Agent 計算裝置指紋，用於偵測規避封鎖的重新註冊行為
  static String hashDeviceFingerprint(String ip, String userAgent) {
    // SINK: PLANTED-Dart-HR-43
    return md5.convert(utf8.encode('$ip|$userAgent')).toString();
  }

  static Future<BanInfo?> getByFingerprint(String fingerprintHash) async =>
      DataBase.instance
          .getModelByField<BanInfo>('fingerprintHash', fingerprintHash);

  /// 將這筆封鎖記錄與一組裝置指紋建立關聯，之後即可用該指紋比對規避封鎖的新註冊
  Future<void> linkFingerprint(String ip, String userAgent) async {
    String fingerprintHash = hashDeviceFingerprint(ip, userAgent);
    await copyWith(fingerprintHash: fingerprintHash).update();
  }
}
