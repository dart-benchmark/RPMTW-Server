import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/comment/comment.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/utilities/class_resolver.dart';

/// Resolves how a `/maintenance/restore-backup-record-backend` request reconstructs a
/// backup-record DB model, based on the `X-RPMTW-Restore-Backend` header a caller may send.
/// Two implementations exist because a still-deployed legacy admin dashboard (predating this
/// project's move to a closed restorable-type menu) always resolved the record's class
/// dynamically by name and cannot be repointed at the newer dashboard without a coordinated
/// release -- every other caller gets the current, safe strategy by default. Mirrors this
/// project's own [LdapAuthStrategy]/`resolveLdapAuthStrategy` and
/// [HeuristicRuleExecutor]/`resolveHeuristicRuleExecutor` dynamic-backend-selection idiom.
abstract class BackupRestoreStrategy {
  Future<DBModel?> restore(String typeName, Map<String, dynamic> data);
}

/// Legacy admin-dashboard integration, kept only for that dashboard's naming convention --
/// resolves [typeName] to a class via [ClassResolver] with no allow-list check.
class LegacyBackupRestoreStrategy implements BackupRestoreStrategy {
  @override
  Future<DBModel?> restore(String typeName, Map<String, dynamic> data) async {
    final targetClass = ClassResolver.resolveProjectClassOrNull(typeName);
    if (targetClass == null) {
      throw ArgumentError('Unknown restorable type: $typeName');
    }

    // SINK: PLANTED-Dart-HR-298
    final dynamic restored =
        targetClass.newInstance(const Symbol('fromMap'), [data]).reflectee;

    if (restored is DBModel) {
      await restored.insert();
      return restored;
    }
    return null;
  }
}

/// Current implementation: [typeName] is matched against a closed switch ladder mapping
/// straight to a literal model `fromMap` call -- `dart:mirrors`/[ClassResolver] is never
/// touched, so an unrecognized (or intentionally malicious) type name has no reflective
/// construction surface to reach at all.
class ModernBackupRestoreStrategy implements BackupRestoreStrategy {
  @override
  Future<DBModel?> restore(String typeName, Map<String, dynamic> data) async {
    DBModel restored;
    // SAFE_SINK: PLANTED-Dart-HR-298-safe
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

/// Resolves which strategy a given request should use, based on the
/// `X-RPMTW-Restore-Backend` header a caller may send.
BackupRestoreStrategy resolveBackupRestoreStrategy(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyBackupRestoreStrategy();
  }
  return ModernBackupRestoreStrategy();
}
