import 'dart:mirrors';

/// Resolves a [ClassMirror] for an arbitrary class name declared anywhere in this project's
/// own package -- shared by [BackupRestoreService] (see
/// `database/backup_restore_service.dart`) and [LegacyBackupRestoreStrategy] (see
/// `utilities/backup_restore_strategy.dart`) so the reflective declaration walk lives in one
/// place rather than being duplicated at every one of this project's differently-shaped
/// restore call sites -- [SystemRoute] and [SystemHandler]'s own direct/one-hop restore
/// routes each still perform this same walk inline, so it is not the *only* place it happens,
/// but it is the one multi-hop callers share.
class ClassResolver {
  /// Walks every class declared in this project's own package (`package:rpmtw_server/...`)
  /// looking for one named exactly [className] -- no restriction on which classes are
  /// eligible, so this can resolve to any class in the library, not just an intended
  /// "restorable record" subset.
  static ClassMirror? resolveProjectClassOrNull(String className) {
    for (final LibraryMirror library
        in currentMirrorSystem().libraries.values) {
      if (library.uri.scheme != 'package' ||
          library.uri.pathSegments.isEmpty ||
          library.uri.pathSegments.first != 'rpmtw_server') {
        continue;
      }

      for (final DeclarationMirror declaration in library.declarations.values) {
        if (declaration is ClassMirror &&
            MirrorSystem.getName(declaration.simpleName) == className) {
          return declaration;
        }
      }
    }
    return null;
  }
}
