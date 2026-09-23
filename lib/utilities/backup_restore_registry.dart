import 'dart:mirrors';

import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/utilities/backup_restore_models.dart';

/// An open, self-populating registry of restorable-record constructors, keyed by class
/// name -- built once, lazily, by walking every class declared in this project's own package
/// and auto-registering any that expose a `fromMap(Map<String, dynamic>)` factory
/// constructor, rather than a hand-curated list of the classes actually meant to be
/// restorable. See [BackupRestoreRegistry.restoreBatch] for the vulnerable batch-restore
/// consumer this feeds -- an admin replaying a whole backup snapshot (several `{type, data}`
/// records) in one call, rather than one record at a time like
/// [SystemRoute]'s other `/maintenance/restore-backup-record*` routes.
class BackupRestoreRegistry {
  static Map<String, dynamic Function(Map<String, dynamic>)>? _factories;

  static Map<String, dynamic Function(Map<String, dynamic>)> _factoriesOrBuild() {
    return _factories ??= _buildFactories();
  }

  static Map<String, dynamic Function(Map<String, dynamic>)> _buildFactories() {
    final Map<String, dynamic Function(Map<String, dynamic>)> factories = {};

    for (final LibraryMirror library
        in currentMirrorSystem().libraries.values) {
      if (library.uri.scheme != 'package' ||
          library.uri.pathSegments.isEmpty ||
          library.uri.pathSegments.first != 'rpmtw_server') {
        continue;
      }

      for (final DeclarationMirror declaration in library.declarations.values) {
        if (declaration is! ClassMirror) continue;
        final ClassMirror classMirror = declaration;

        for (final DeclarationMirror member in classMirror.declarations.values) {
          if (member is MethodMirror &&
              member.isConstructor &&
              MirrorSystem.getName(member.constructorName) == 'fromMap') {
            final String typeName =
                MirrorSystem.getName(classMirror.simpleName);
            factories[typeName] = (Map<String, dynamic> data) => classMirror
                .newInstance(const Symbol('fromMap'), [data]).reflectee;
            break;
          }
        }
      }
    }

    return factories;
  }

  /// Restores every `{type, data}` entry in [records] in turn. [records[i]['type']] is
  /// looked up directly in the auto-populated registry above -- no check that the resolved
  /// factory belongs to the small set of types actually meant to be restorable, so anything
  /// the reflective walk happened to pick up (see [DebugDiagnosticsOverride]) is just as
  /// reachable as a genuine backup-record model.
  static List<dynamic> restoreBatch(List<dynamic> records) {
    final Map<String, dynamic Function(Map<String, dynamic>)> factories =
        _factoriesOrBuild();
    final List<dynamic> restored = [];

    for (final dynamic recordDynamic in records) {
      final Map<String, dynamic> record =
          Map<String, dynamic>.from(recordDynamic as Map);
      final String type = record['type'] as String;
      final Map<String, dynamic> data =
          Map<String, dynamic>.from(record['data'] as Map? ?? {});

      final dynamic Function(Map<String, dynamic>)? factory = factories[type];
      if (factory == null) {
        throw ArgumentError('Unknown restorable type: $type');
      }

      // SINK: PLANTED-Dart-HR-299
      final dynamic instance = factory(data);
      restored.add(instance);
      if (instance is DBModel) {
        // Persisting each restored record is out of scope for this batch call's own
        // contract -- see BackupRestoreService for the persisted single-record restore path.
      }
    }

    return restored;
  }

  /// Same batch restore, safe variant: every entry's `type` is checked against
  /// [kAllowedBackupRecordTypes] before any lookup in the auto-populated registry --
  /// [DebugDiagnosticsOverride] (and anything else the reflective walk above picked up that
  /// isn't an intended restorable record) can never be selected, no matter what the registry
  /// itself contains.
  static List<dynamic> restoreBatchSafe(List<dynamic> records) {
    final Map<String, dynamic Function(Map<String, dynamic>)> factories =
        _factoriesOrBuild();
    final List<dynamic> restored = [];

    for (final dynamic recordDynamic in records) {
      final Map<String, dynamic> record =
          Map<String, dynamic>.from(recordDynamic as Map);
      final String type = record['type'] as String;
      final Map<String, dynamic> data =
          Map<String, dynamic>.from(record['data'] as Map? ?? {});

      if (!kAllowedBackupRecordTypes.contains(type)) {
        throw ArgumentError('Unknown restorable type: $type');
      }

      // SAFE_SINK: PLANTED-Dart-HR-299-safe
      final dynamic Function(Map<String, dynamic>)? factory = factories[type];
      if (factory == null) {
        throw ArgumentError('Unknown restorable type: $type');
      }
      final dynamic instance = factory(data);
      restored.add(instance);
    }

    return restored;
  }
}
