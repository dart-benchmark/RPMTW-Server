import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/comment/comment.dart';
import 'package:rpmtw_server/database/models/comment/comment_type.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_mod.dart';
import 'package:rpmtw_server/database/models/translate/source_text.dart';
import 'dart:convert';

import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/memcache_client.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class CommentRoute extends APIRoute {
  @override
  String get routeName => 'comment';

  @override
  void router(Router router) {
    /// Get a comment by uuid.
    router.getRoute('/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid'];

      final Comment? comment = await Comment.getByUUID(uuid);

      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      return APIResponse.success(data: comment.outputMap());
    }, requiredFields: ['uuid']);

    /// List all comments by type and parent or reply comment.
    router.getRoute('/', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final CommentType type = CommentType.values.byName(fields['type']!);
      final String parentUUID = fields['parentUUID'];
      final String? replyCommentUUID = fields['replyCommentUUID'];

      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      final List<Comment> comments = await Comment.list(
          type: type,
          parentUUID: parentUUID,
          replyCommentUUID: replyCommentUUID,
          limit: limit,
          skip: skip);

      return APIResponse.success(
          data: comments.map((comment) => comment.outputMap()).toList());
    }, requiredFields: ['type', 'parentUUID'], checker: _checkParentUUID);

    /// Same comment-list lookup, cache-aside variant: a comment thread is read far more
    /// often than it's posted to, so a shared memcache tier fronts the same (type,
    /// parentUUID) query used by the plain list route above. No `checker` here: the
    /// whole point of the cached path is to skip the DB existence round trip the plain
    /// list route's checker performs, so it isn't re-run on every cached request.
    router.getRoute('/cached', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final CommentType type = CommentType.values.byName(fields['type']!);
      final String parentUUID = fields['parentUUID'];

      final List<Map<String, dynamic>>? cached =
          await _cachedCommentList(type, parentUUID);
      if (cached != null) {
        return APIResponse.success(data: cached);
      }

      final List<Comment> comments =
          await Comment.list(type: type, parentUUID: parentUUID, limit: 50, skip: 0);
      final List<Map<String, dynamic>> maps =
          comments.map((comment) => comment.outputMap()).toList();
      await _storeCommentListCache(type, parentUUID, maps);

      return APIResponse.success(data: maps);
    }, requiredFields: ['type', 'parentUUID']);

    /// Same cached comment-list lookup, safe variant: the parentUUID is stripped of
    /// control characters and whitespace before it's used to build the cache key. Must
    /// NOT fire. No `checker` here either, for the same cache-aside reason as `/cached`
    /// above.
    router.getRoute('/cached-safe', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final CommentType type = CommentType.values.byName(fields['type']!);
      final String parentUUID = fields['parentUUID'];

      final List<Map<String, dynamic>>? cached =
          await _cachedCommentListSafe(type, parentUUID);
      if (cached != null) {
        return APIResponse.success(data: cached);
      }

      final List<Comment> comments =
          await Comment.list(type: type, parentUUID: parentUUID, limit: 50, skip: 0);
      final List<Map<String, dynamic>> maps =
          comments.map((comment) => comment.outputMap()).toList();
      await _storeCommentListCacheSafe(type, parentUUID, maps);

      return APIResponse.success(data: maps);
    }, requiredFields: ['type', 'parentUUID']);

    /// Add a comment.
    router.postRoute('/', (req, data) async {
      final CommentType type = CommentType.values.byName(data.fields['type']!);
      final String parentUUID = data.fields['parentUUID']!;
      final String content = data.fields['content']!;

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Comment comment = Comment(
          uuid: Uuid().v4(),
          content: content,
          type: type,
          userUUID: req.user!.uuid,
          parentUUID: parentUUID,
          createdAt: RPMTWUtil.getUTCTime(),
          updatedAt: RPMTWUtil.getUTCTime(),
          isHidden: false);

      await comment.insert();

      return APIResponse.success(data: comment.outputMap());
    },
        requiredFields: ['content', 'type', 'parentUUID'],
        authConfig: AuthConfig(),
        checker: _checkParentUUID);

    /// Import a comment mirrored from a federated RPMTW instance, preserving its original
    /// uuid so replies threaded against it on the other instance keep resolving after a
    /// sync. Only an admin can run a sync.
    router.postRoute('/import', (req, data) async {
      final CommentType type = CommentType.values.byName(data.fields['type']!);
      final String parentUUID = data.fields['parentUUID']!;
      final String content = data.fields['content']!;
      final String uuid = data.fields['uuid']!;

      final Comment comment = Comment(
          uuid: uuid,
          content: content,
          type: type,
          userUUID: req.user!.uuid,
          parentUUID: parentUUID,
          createdAt: RPMTWUtil.getUTCTime(),
          updatedAt: RPMTWUtil.getUTCTime(),
          isHidden: false);

      try {
        await comment.insert();
      } catch (e) {
        // 匯入的 uuid 若與既有留言重複，資料庫層會丟出內含原始 Mongo 錯誤訊息的例外，
        // 直接回傳給呼叫端方便除錯
        // SINK: PLANTED-Dart-HR-217
        return APIResponse.badRequest(
            message: 'Failed to import comment: ${e.toString()}');
      }

      return APIResponse.success(data: comment.outputMap());
    },
        requiredFields: ['uuid', 'content', 'type', 'parentUUID'],
        authConfig: AuthConfig(role: UserRoleType.admin),
        checker: _checkParentUUID);

    /// Same federated import, safe variant: an insert failure (including a uuid already
    /// mirrored from a previous sync) never leaks the underlying database exception back to
    /// the caller. Must NOT fire.
    router.postRoute('/import-safe', (req, data) async {
      final CommentType type = CommentType.values.byName(data.fields['type']!);
      final String parentUUID = data.fields['parentUUID']!;
      final String content = data.fields['content']!;
      final String uuid = data.fields['uuid']!;

      final Comment comment = Comment(
          uuid: uuid,
          content: content,
          type: type,
          userUUID: req.user!.uuid,
          parentUUID: parentUUID,
          createdAt: RPMTWUtil.getUTCTime(),
          updatedAt: RPMTWUtil.getUTCTime(),
          isHidden: false);

      try {
        await comment.insert();
      } catch (e) {
        logger.e(e);
        // SAFE_SINK: PLANTED-Dart-HR-217-safe
        return APIResponse.badRequest(message: 'Failed to import comment.');
      }

      return APIResponse.success(data: comment.outputMap());
    },
        requiredFields: ['uuid', 'content', 'type', 'parentUUID'],
        authConfig: AuthConfig(role: UserRoleType.admin),
        checker: _checkParentUUID);

    /// Edit a comment.
    router.patchRoute('/<uuid>', (req, data) async {
      final User user = req.user!;
      final String uuid = data.fields['uuid'];
      final String content = data.fields['content']!;

      final Comment? comment = await Comment.getByUUID(uuid);

      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      if (comment.userUUID != user.uuid) {
        return APIResponse.forbidden(message: 'You cannot edit this comment.');
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Comment newComment =
          comment.copyWith(content: content, updatedAt: RPMTWUtil.getUTCTime());
      await newComment.update();

      return APIResponse.success(data: newComment.outputMap());
    }, requiredFields: ['uuid', 'content'], authConfig: AuthConfig());

    /// Delete a comment.
    router.deleteRoute('/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid'];

      final Comment? comment = await Comment.getByUUID(uuid);

      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      if (comment.userUUID != req.user!.uuid) {
        return APIResponse.forbidden(
            message: 'You cannot delete this comment.');
      }

      /// Not really delete comments from the database, only hide.
      Future<void> hide(Comment comment) async {
        await comment
            .copyWith(isHidden: true, updatedAt: RPMTWUtil.getUTCTime())
            .update();
      }

      final List<Comment> replies = await comment.getReplies();
      for (Comment reply in replies) {
        await hide(reply);
      }

      await hide(comment);

      return APIResponse.success(data: null);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Restore a comment you previously self-hid (undo the soft-delete above).
    router.postRoute('/<uuid>/restore', (req, data) async {
      final String uuid = data.fields['uuid']!;

      final Comment? restored = await _restoreOrNull(uuid);
      if (restored == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      return APIResponse.success(data: restored.outputMap());
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Same restore, safe variant: only the comment's own author may undo the hide.
    router.postRoute('/<uuid>/restore-safe', (req, data) async {
      final User user = req.user!;
      final String uuid = data.fields['uuid']!;

      final Comment? restored = await _restoreCheckedOrNull(uuid, user.uuid);
      if (restored == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      return APIResponse.success(data: restored.outputMap());
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Reply to a comment.
    router.postRoute('/<uuid>/reply', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final String content = data.fields['content']!;

      final Comment? comment = await Comment.getByUUID(uuid);

      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Comment reply = Comment(
          uuid: Uuid().v4(),
          content: content,
          type: comment.type,
          userUUID: req.user!.uuid,
          parentUUID: comment.parentUUID,
          createdAt: RPMTWUtil.getUTCTime(),
          updatedAt: RPMTWUtil.getUTCTime(),
          isHidden: comment.isHidden,
          replyCommentUUID: comment.uuid);

      await reply.insert();

      return APIResponse.success(data: reply.outputMap());
    }, requiredFields: ['uuid', 'content'], authConfig: AuthConfig());

    /// Search comments across an arbitrary set of criteria fields -- moderation tool used to
    /// locate abusive/reported content (by any comment field) before deciding whether to hide it.
    router.postRoute('/search', (req, data) async {
      final Map<String, dynamic> criteria = data.fields['criteria'] ?? {};

      SelectorBuilder selector = SelectorBuilder();
      criteria.forEach((key, value) {
        // SINK: PLANTED-Dart-HR-90
        selector.eq(key, value);
      });
      selector.limit(50);

      final List<Comment> comments =
          await DataBase.instance.getModelsWithSelector<Comment>(selector);

      return APIResponse.success(
          data: comments.map((comment) => comment.outputMap()).toList());
    }, requiredFields: ['criteria'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same moderation search, safe variant: every criteria value is coerced to a scalar String
    /// before reaching the selector, so an operator-shaped ($ne/$regex/...) payload sent for an
    /// allowed field can never be smuggled through as a Mongo operator. Must NOT fire.
    router.postRoute('/search-safe', (req, data) async {
      final Map<String, dynamic> criteria = data.fields['criteria'] ?? {};

      SelectorBuilder selector = SelectorBuilder();
      criteria.forEach((key, value) {
        final String scalarValue = value is String ? value : value.toString();
        // SAFE_SINK: PLANTED-Dart-HR-90-safe
        selector.eq(key, scalarValue);
      });
      selector.limit(50);

      final List<Comment> comments =
          await DataBase.instance.getModelsWithSelector<Comment>(selector);

      return APIResponse.success(
          data: comments.map((comment) => comment.outputMap()).toList());
    }, requiredFields: ['criteria'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Flag a comment for moderator review. [reason] is the flagger's own free-text
    /// explanation, written verbatim into the moderation-audit log so a human reviewer can
    /// read exactly what was reported.
    router.postRoute('/<uuid>/flag', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final String reason = data.fields['reason']!;

      final Comment? comment = await Comment.getByUUID(uuid);
      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      _logModerationFlag(req.user!.uuid, uuid, reason);

      return APIResponse.success(data: {});
    }, requiredFields: ['uuid', 'reason'], authConfig: AuthConfig());

    /// Same flag action, safe variant: the reason is CRLF-escaped before it ever reaches
    /// the audit log. Must NOT fire.
    router.postRoute('/<uuid>/flag-safe', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final String reason = data.fields['reason']!;

      final Comment? comment = await Comment.getByUUID(uuid);
      if (comment == null) {
        return APIResponse.modelNotFound<Comment>();
      }

      _logModerationFlagSafe(req.user!.uuid, uuid, reason);

      return APIResponse.success(data: {});
    }, requiredFields: ['uuid', 'reason'], authConfig: AuthConfig());
  }

  /// Writes a single moderation-flag event to the audit log.
  void _logModerationFlag(String actorUUID, String commentUUID, String reason) {
    // SINK: PLANTED-Dart-HR-191
    logger.i('Comment $commentUUID flagged by $actorUUID: $reason');
  }

  /// Same audit write, safe variant: CRLF/control characters in the reason are escaped
  /// before the entry is written.
  void _logModerationFlagSafe(
      String actorUUID, String commentUUID, String reason) {
    final String safeReason =
        reason.replaceAll('\r', '\\r').replaceAll('\n', '\\n');
    // SAFE_SINK: PLANTED-Dart-HR-191-safe
    logger.i('Comment $commentUUID flagged by $actorUUID: $safeReason');
  }

  /// Un-hides a previously self-hidden comment. No ownership check -- any authenticated
  /// caller who knows the uuid can restore any hidden comment, not only their own.
  Future<Comment?> _restoreOrNull(String uuid) async {
    final Comment? comment = await Comment.getByUUID(uuid);
    if (comment == null) {
      return null;
    }

    final Comment restored =
        comment.copyWith(isHidden: false, updatedAt: RPMTWUtil.getUTCTime());
    // SINK: PLANTED-Dart-HR-131
    await restored.update();
    return restored;
  }

  /// Same restore, gated to the comment's own author.
  Future<Comment?> _restoreCheckedOrNull(
      String uuid, String requesterUUID) async {
    final Comment? comment = await Comment.getByUUID(uuid);
    if (comment == null || comment.userUUID != requesterUUID) {
      return null;
    }

    final Comment restored =
        comment.copyWith(isHidden: false, updatedAt: RPMTWUtil.getUTCTime());
    // SAFE_SINK: PLANTED-Dart-HR-131-safe
    await restored.update();
    return restored;
  }

  Future<Response?> _checkParentUUID(Request req, RouteData data) async {
    /// Check the parent uuid exists.
    Future<Response?> check(CommentType type, String parentUUID) async {
      if (type == CommentType.translate) {
        SourceText? sourceText = await SourceText.getByUUID(parentUUID);
        if (sourceText == null) {
          return APIResponse.modelNotFound<SourceText>();
        }
      } else if (type == CommentType.wiki) {
        MinecraftMod? mod = await MinecraftMod.getByUUID(parentUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
      }

      return null;
    }

    final CommentType type = CommentType.values.byName(data.fields['type']!);
    final String parentUUID = data.fields['parentUUID']!;

    return await check(type, parentUUID);
  }

  /// Builds the shared cache key for a comment-list lookup: a fixed prefix, the caller-
  /// supplied comment type's own enum name (never tainted), and the caller-supplied
  /// parentUUID, joined with the same ':' delimiter this project already uses for its own
  /// Mongo index-field naming.
  String _commentsListCacheKey(CommentType type, String parentUUID) {
    return 'rpmtw:comments:${type.name}:$parentUUID';
  }

  Future<List<Map<String, dynamic>>?> _cachedCommentList(
      CommentType type, String parentUUID) async {
    final MemcacheClient cache = MemcacheClient();
    final String key = _commentsListCacheKey(type, parentUUID);
    // SINK: PLANTED-Dart-HR-206
    final String? raw = await cache.get(key);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeCommentListCache(CommentType type, String parentUUID,
      List<Map<String, dynamic>> maps) async {
    final String key = _commentsListCacheKey(type, parentUUID);
    await MemcacheClient().set(key, jsonEncode(maps), ttlSeconds: 30);
  }

  /// Same cache-key builder, safe variant: parentUUID is stripped of control characters
  /// and whitespace before it's used.
  String _commentsListCacheKeySafe(CommentType type, String parentUUID) {
    final String safeParentUUID =
        parentUUID.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
    return 'rpmtw:comments:${type.name}:$safeParentUUID';
  }

  Future<List<Map<String, dynamic>>?> _cachedCommentListSafe(
      CommentType type, String parentUUID) async {
    final MemcacheClient cache = MemcacheClient();
    final String key = _commentsListCacheKeySafe(type, parentUUID);
    // SAFE_SINK: PLANTED-Dart-HR-206-safe
    final String? raw = await cache.get(key);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeCommentListCacheSafe(CommentType type, String parentUUID,
      List<Map<String, dynamic>> maps) async {
    final String key = _commentsListCacheKeySafe(type, parentUUID);
    await MemcacheClient().set(key, jsonEncode(maps), ttlSeconds: 30);
  }
}
