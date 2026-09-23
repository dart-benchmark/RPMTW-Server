/// The closed set of DB-model type names an admin may name when restoring a backup record
/// through any of this project's `/maintenance/restore-backup-record*` routes -- checked by
/// every safe variant ([SystemRoute]'s `-safe` routes, [SystemHandler]'s `Safe`-suffixed
/// methods, [BackupRestoreService.restoreSafe], [ModernBackupRestoreStrategy] and
/// [BackupRestoreRegistry.restoreBatchSafe]) before a caller-supplied type name is ever used
/// to select a class. Mirrors [kAllowedHeuristicRuleNames]'s role for the heuristic-rule
/// dispatch family.
const Set<String> kAllowedBackupRecordTypes = {
  'User',
  'Comment',
  'Storage',
};
