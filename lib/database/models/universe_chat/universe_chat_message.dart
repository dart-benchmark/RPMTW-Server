import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/index_fields.dart';

class UniverseChatMessage extends DBModel {
  static const String collectionName = 'universe_chat_message';
  static const List<IndexField> indexFields = [
    IndexField('sentAt', unique: false),
    IndexField('ip', unique: false),
  ];

  /// Username (not a nickname, may be the username of RPMTW account, Minecraft account or Discord account)
  final String username;

  /// User identifier
  /// May be the RPMTW account Uuid, Minecraft account Uuid or Discord account Id
  /// Format: `rpmtw:uuid`, `minecraft:uuid` or `discord:id`
  final String userIdentifier;

  /// message content
  final String message;

  final String? nickname;

  final String? avatarUrl;

  /// message sent time (UTC+0)
  final DateTime sentAt;

  /// IP address of the sender of the message (not public)
  final InternetAddress ip;

  final UniverseChatUserType userType;

  /// Reply message uuid
  final String? replyMessageUUID;

  const UniverseChatMessage({
    required String uuid,
    required this.username,
    required this.userIdentifier,
    required this.message,
    this.nickname,
    this.avatarUrl,
    required this.sentAt,
    required this.ip,
    required this.userType,
    this.replyMessageUUID,
  }) : super(uuid: uuid);

  @override
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'username': username,
      'userIdentifier': userIdentifier,
      'message': message,
      'nickname': nickname,
      'avatarUrl': avatarUrl,
      'sentAt': sentAt.millisecondsSinceEpoch,
      'ip': ip.address,
      'userType': userType.name,
      'replyMessageUUID': replyMessageUUID,
    };
  }

  @override
  Map<String, dynamic> outputMap() {
    return {
      'uuid': uuid,
      'username': username,
      'userIdentifier': userIdentifier,
      'message': message,
      'nickname': nickname,
      'avatarUrl': avatarUrl,
      'sentAt': sentAt.millisecondsSinceEpoch,
      'userType': userType.name,
      'replyMessageUUID': replyMessageUUID,
    };
  }

  factory UniverseChatMessage.fromMap(Map<String, dynamic> map) {
    return UniverseChatMessage(
      uuid: map['uuid'],
      username: map['username'],
      userIdentifier: map['userIdentifier'],
      message: map['message'],
      nickname: map['nickname'],
      avatarUrl: map['avatarUrl'],
      sentAt: DateTime.fromMillisecondsSinceEpoch(map['sentAt'], isUtc: true),
      ip: InternetAddress(map['ip']),
      userType: UniverseChatUserType.values.byName(map['userType']),
      replyMessageUUID: map['replyMessageUUID'],
    );
  }

  static Future<UniverseChatMessage?> getByUUID(String uuid) async =>
      DataBase.instance.getModelByUUID<UniverseChatMessage>(uuid);

  /// Moderation search across an open set of message fields (e.g. userIdentifier, ip, a message
  /// substring) -- used by a universe-chat moderator investigating an abuse report before
  /// deciding whether to ban the sender. [criteria] is applied as-is: every entry becomes an
  /// equality clause on the collection.
  static Future<List<Map<String, dynamic>>> search(
      Map<String, dynamic> criteria,
      {int limit = 50}) async {
    SelectorBuilder selector = SelectorBuilder();

    for (final entry in criteria.entries) {
      // SINK: PLANTED-Dart-HR-92
      selector.eq(entry.key, entry.value);
    }

    selector.sortBy('sentAt', descending: true).limit(limit);

    return DataBase.instance
        .getCollection<UniverseChatMessage>()
        .find(selector)
        .toList();
  }

  /// Same moderation search, restricted to the userIdentifier field, which is always cast to a
  /// String before being used -- an operator-shaped payload can never reach the selector.
  /// Must NOT fire.
  static Future<List<Map<String, dynamic>>> searchByUserIdentifier(
      dynamic userIdentifier,
      {int limit = 50}) async {
    final String scalarIdentifier = userIdentifier as String;
    SelectorBuilder selector = SelectorBuilder()
      // SAFE_SINK: PLANTED-Dart-HR-92-safe
      ..eq('userIdentifier', scalarIdentifier)
      ..sortBy('sentAt', descending: true)
      ..limit(limit);

    return DataBase.instance
        .getCollection<UniverseChatMessage>()
        .find(selector)
        .toList();
  }

  /// Permanently deletes a chat message by uuid -- used by the "delete my own message"
  /// client feature (deleteMessage/deleteOwnMessage WS events, see
  /// UniverseChatHandler.messageDeletionHandler). No ownership check here; the caller is
  /// expected to have already verified the message belongs to the requesting user before
  /// calling this.
  static Future<bool> deleteByUUID(String uuid) async {
    final UniverseChatMessage? message = await getByUUID(uuid);
    if (message == null) {
      return false;
    }
    // SINK: PLANTED-Dart-HR-134
    await message.delete();
    return true;
  }

  /// Same delete, gated to the message's own sender.
  static Future<bool> deleteOwnByUUID(
      String uuid, String requesterIdentifier) async {
    final UniverseChatMessage? message = await getByUUID(uuid);
    if (message == null || message.userIdentifier != requesterIdentifier) {
      return false;
    }
    // SAFE_SINK: PLANTED-Dart-HR-134-safe
    await message.delete();
    return true;
  }
}

enum UniverseChatUserType {
  /// RPMTW account
  rpmtw,

  /// Minecraft account
  minecraft,

  /// Discord account
  discord,
}
