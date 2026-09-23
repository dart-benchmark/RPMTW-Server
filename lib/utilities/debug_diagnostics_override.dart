/// A process-wide diagnostics toggle -- reachable by name through an unrestricted
/// `dart:mirrors` class lookup exactly like any real, restorable [DBModel], but never meant
/// to be selectable by a backup-record `type` discriminator at all: it isn't a persisted
/// model, and it is deliberately excluded from [kAllowedBackupRecordTypes]. Enabling it (see
/// [verboseDiagnosticsEnabled]) widens what a later admin diagnostics call would reveal to
/// whoever can also reach one.
///
/// Exists purely so this project's several discriminator-driven "restore backup record"
/// call sites (see `SystemRoute`'s `/maintenance/restore-backup-record*` routes,
/// `SystemHandler`, `BackupRestoreService`, `BackupRestoreStrategy` and
/// `BackupRestoreRegistry`) have a concrete, observable side effect to demonstrate: none of
/// them mean to ever construct this class, but a reflective class-name lookup with no
/// allow-list check has no way to tell it apart from a genuine restorable record type.
class DebugDiagnosticsOverride {
  /// Flipped by [DebugDiagnosticsOverride.fromMap] the instant this class is constructed --
  /// never by any legitimate restorable-record path, since none of them name this class.
  static bool verboseDiagnosticsEnabled = false;

  DebugDiagnosticsOverride._();

  /// Mirrors the `SomeModel.fromMap(Map<String, dynamic> map)` shape every real restorable
  /// [DBModel] in this project uses (see [User.fromMap], [Comment.fromMap],
  /// [Storage.fromMap]), so a reflective restore call that resolves to this class instead of
  /// an intended model still succeeds instead of throwing a [NoSuchMethodError] -- and so a
  /// registry that auto-registers "every class with a `fromMap` factory" (see
  /// [BackupRestoreRegistry]) picks this class up exactly as readily as a genuine model.
  factory DebugDiagnosticsOverride.fromMap(Map<String, dynamic> map) {
    verboseDiagnosticsEnabled = true;
    return DebugDiagnosticsOverride._();
  }
}
