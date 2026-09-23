import 'dart:mirrors';

import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/moderation_case.dart';

/// Cross-file diagnostic-field evaluation layer for [ModerationCase] -- kept separate from
/// [SystemHandler] so a whole batch of field dumps across several flagged messages can share
/// one audit trail regardless of which route triggered it. See [SystemHandler]'s
/// `/diagnostics/dump-fields-batch` route.
class ModerationDiagnosticsRepository {
  /// Reads every field named in each entry's `fields` list off the [ModerationCase] built
  /// for that entry's `messageUuid` -- e.g. an admin pulling several internal diagnostic
  /// fields across a whole batch of flagged messages in one call instead of one
  /// message/field pair at a time. [requests] entries missing a resolvable message are
  /// silently skipped.
  static Future<Map<String, Map<String, dynamic>>> dumpFieldsBatch(
      List<Map<String, dynamic>> requests) async {
    final Map<String, Map<String, dynamic>> results = {};

    for (final Map<String, dynamic> request in requests) {
      final String messageUuid = request['messageUuid'].toString();
      final List<dynamic> fieldNames = request['fields'] as List<dynamic>;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) continue;

      final ModerationCase moderationCase =
          ModerationCase.forMessage(chatMessage);
      final InstanceMirror mirror = reflect(moderationCase);
      final LibraryMirror ownerLibrary = mirror.type.owner as LibraryMirror;

      final Map<String, dynamic> fieldValues = {};
      for (final dynamic fieldNameDynamic in fieldNames) {
        final String fieldName = fieldNameDynamic.toString();
        final Symbol fieldSymbol =
            MirrorSystem.getSymbol(fieldName, ownerLibrary);

        // SINK: PLANTED-Dart-HR-324
        fieldValues[fieldName] = mirror.getField(fieldSymbol).reflectee.toString();
      }
      results[messageUuid] = fieldValues;
      _recordAudit(messageUuid, fieldNames.join(','));
    }

    return results;
  }

  /// Same batch dump, safe variant: every field name in every entry's `fields` list is
  /// checked against that entry's own [ModerationCase.publicSummary] key set before it is
  /// ever read -- `dart:mirrors` is never touched.
  static Future<Map<String, Map<String, dynamic>>> dumpFieldsBatchSafe(
      List<Map<String, dynamic>> requests) async {
    final Map<String, Map<String, dynamic>> results = {};

    for (final Map<String, dynamic> request in requests) {
      final String messageUuid = request['messageUuid'].toString();
      final List<dynamic> fieldNames = request['fields'] as List<dynamic>;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) continue;

      final ModerationCase moderationCase =
          ModerationCase.forMessage(chatMessage);
      final Map<String, dynamic> summary = moderationCase.publicSummary();

      final Map<String, dynamic> fieldValues = {};
      for (final dynamic fieldNameDynamic in fieldNames) {
        final String fieldName = fieldNameDynamic.toString();
        if (!summary.containsKey(fieldName)) continue;

        // SAFE_SINK: PLANTED-Dart-HR-324-safe
        fieldValues[fieldName] = summary[fieldName].toString();
      }
      results[messageUuid] = fieldValues;
      _recordAudit(messageUuid, fieldNames.join(','));
    }

    return results;
  }

  static void _recordAudit(String messageUuid, String fieldNames) {
    logger.i('Diagnostic field(s) "$fieldNames" dumped for message $messageUuid');
  }

  /// Reflectively overwrites the field named [fieldName] on the [ModerationCase] built for
  /// [messageUuid] with [value] -- e.g. a moderator patching a diagnostic field by name
  /// directly, without going through [ModerationCase.annotate]. Returns the case's
  /// [ModerationCase.publicSummary] afterward so the caller can confirm the patch took
  /// effect. See [SystemHandler]'s `/diagnostics/patch-field` route.
  static Future<Map<String, dynamic>> patchField(
      String messageUuid, String fieldName, String value) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }

    final ModerationCase moderationCase =
        ModerationCase.forMessage(chatMessage);
    final InstanceMirror mirror = reflect(moderationCase);
    final LibraryMirror ownerLibrary = mirror.type.owner as LibraryMirror;
    final Symbol fieldSymbol = MirrorSystem.getSymbol(fieldName, ownerLibrary);

    // SINK: PLANTED-Dart-HR-321
    mirror.setField(fieldSymbol, value);

    _recordAudit(messageUuid, fieldName);
    return moderationCase.publicSummary();
  }

  /// Same field patch, safe variant: the only field this can ever mutate is
  /// [ModerationCase]'s reviewer-notes annotation, via its own sanctioned
  /// [ModerationCase.annotate] method -- `dart:mirrors` is never touched, so no other field
  /// (nor an unrecognized name) has any reflective write surface to reach here at all.
  static Future<Map<String, dynamic>> patchFieldSafe(
      String messageUuid, String fieldName, String value) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    if (fieldName != '_reviewerNotes') {
      throw ArgumentError('Unknown diagnostic field: $fieldName');
    }

    final ModerationCase moderationCase =
        ModerationCase.forMessage(chatMessage);
    // SAFE_SINK: PLANTED-Dart-HR-321-safe
    moderationCase.annotate(value);

    _recordAudit(messageUuid, fieldName);
    return moderationCase.publicSummary();
  }
}
