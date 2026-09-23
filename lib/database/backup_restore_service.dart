import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/comment/comment.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/utilities/backup_restore_models.dart';
import 'package:rpmtw_server/utilities/class_resolver.dart';

/// Cross-file restore layer sitting between [SystemHandler]'s admin-facing
/// `/maintenance/restore-backup-record-service` route and the actual class-resolution step
/// [ClassResolver] performs -- kept separate from [SystemHandler] so a future caller (e.g. a
/// scheduled federation-restore job) could reuse the same restore logic without going
/// through the admin route layer at all. Mirrors [HeuristicRuleRepository]'s role for the
/// heuristic-rule dispatch family.
class BackupRestoreService {
  /// Restores the DB-model record named by [typeName] from [data] -- [typeName] is resolved
  /// to a class via [ClassResolver] with no check that the resolved class is one of the
  /// small set of types actually meant to be restorable. See [SystemHandler]'s
  /// `restoreBackupRecordViaService`.
  static Future<DBModel?> restore(
      String typeName, Map<String, dynamic> data) async {
    final targetClass = ClassResolver.resolveProjectClassOrNull(typeName);
    if (targetClass == null) {
      throw ArgumentError('Unknown restorable type: $typeName');
    }

    // SINK: PLANTED-Dart-HR-297
    final dynamic restored =
        targetClass.newInstance(const Symbol('fromMap'), [data]).reflectee;

    if (restored is DBModel) {
      await restored.insert();
      return restored;
    }
    return null;
  }

  /// Same restore, safe variant: [typeName] is checked against
  /// [kAllowedBackupRecordTypes] before it is ever used to select a class -- dispatch goes
  /// straight to a literal, hard-coded `fromMap` call per known type, so [ClassResolver] (and
  /// therefore `dart:mirrors`) is never touched at all.
  static Future<DBModel?> restoreSafe(
      String typeName, Map<String, dynamic> data) async {
    if (!kAllowedBackupRecordTypes.contains(typeName)) {
      throw ArgumentError('Unknown restorable type: $typeName');
    }

    DBModel restored;
    // SAFE_SINK: PLANTED-Dart-HR-297-safe
    switch (typeName) {
      case 'User':
        restored = User.fromMap(data);
        break;
      case 'Comment':
        restored = Comment.fromMap(data);
        break;
      case 'Storage':
        restored = Storage.fromMap(data);
        break;
      default:
        throw ArgumentError('Unknown restorable type: $typeName');
    }

    await restored.insert();
    return restored;
  }
}
