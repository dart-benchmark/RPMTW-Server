import 'dart:io';
import 'dart:mirrors';

import 'package:http/http.dart' as http;
import 'package:rpmtw_server/database/backup_restore_service.dart';
import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/federation_mirror_service.dart';
import 'package:rpmtw_server/database/heuristic_rule_repository.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/models/comment/comment.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';
import 'package:rpmtw_server/database/moderation_diagnostics_repository.dart';
import 'package:rpmtw_server/database/node_lifecycle_service.dart';
import 'package:rpmtw_server/utilities/backup_restore_models.dart';
import 'package:rpmtw_server/utilities/backup_restore_registry.dart';
import 'package:rpmtw_server/utilities/backup_restore_strategy.dart';
import 'package:rpmtw_server/utilities/chat_heuristic_rules.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/federation_sync_strategy.dart';
import 'package:rpmtw_server/utilities/heuristic_rule_executor.dart';
import 'package:rpmtw_server/utilities/lifecycle_strategy.dart';
import 'package:rpmtw_server/utilities/maintenance_scheduler.dart';
import 'package:rpmtw_server/utilities/ops_shell.dart';
import 'package:rpmtw_server/utilities/self_test_check.dart';

/// Ceiling for [SystemHandler.scheduleMaintenanceActionSafe] -- the longest a scheduled
/// maintenance action may ever be deferred, regardless of what a caller requests.
const int kMaxScheduledActionDelayMs = 5000;

/// Ceiling (in seconds, the unit the caller supplies) for
/// [SystemHandler.runMaintenanceActionAfterDelaySafe].
const int kMaxRetryDelaySeconds = 30;

/// Ceiling for how many attempts a stored [WebhookRetryPolicy] may ever replay -- see
/// [SystemHandler.configureWebhookRetryPolicySafe].
const int kMaxWebhookRetryCount = 10;

/// Ceiling (in milliseconds) for the per-attempt interval a stored [WebhookRetryPolicy] may
/// ever use -- see [SystemHandler.configureWebhookRetryPolicySafe].
const int kMaxWebhookRetryIntervalMs = 2000;

/// Admin-only operations support: ad-hoc network diagnostics, database backups, log
/// housekeeping, and file-integrity scanning that don't belong on any single domain model.
/// See [SystemRoute] for the routes that call into this handler, and
/// [Storage.writeToTempFileAndScan] for the further hop the malware-scan feature makes into
/// the storage model.
class SystemHandler {
  /// Triggers a `mongodump` snapshot tagged [tag] (e.g. "pre-migration",
  /// "weekly-2026-09-03") so an admin can pull a point-in-time backup before a risky
  /// operation without shelling into the host directly. See [SystemRoute]'s
  /// `/maintenance/backup` route.
  static Future<ProcessResult> triggerDatabaseBackup(String tag) async {
    final String command =
        'mongodump --archive=/var/backups/rpmtw/' + tag + '.archive';

    // SINK: PLANTED-Dart-HR-251
    return Process.run('sh', ['-c', command]);
  }

  /// Same backup trigger, safe variant: [tag] is restricted to a small, filesystem-safe
  /// character set before it ever reaches a command line, and `mongodump` is invoked
  /// directly (no shell) so a tag that did pass validation still could not be interpreted
  /// as anything but a single literal argument.
  static Future<ProcessResult> triggerDatabaseBackupSafe(String tag) async {
    final RegExp safeTag = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
    if (!safeTag.hasMatch(tag)) {
      throw ArgumentError('Invalid backup tag');
    }

    // SAFE_SINK: PLANTED-Dart-HR-251-safe
    return Process.run(
        'mongodump', ['--archive=/var/backups/rpmtw/$tag.archive']);
  }

  /// Archives the current server log under [label] -- see [OpsShell] for where the actual
  /// shell-out happens.
  static Future<ProcessResult> archiveServerLogs(String label) async {
    return OpsShell.buildAndRunArchiveCommand(label);
  }

  /// Same log archive, safe variant.
  static Future<void> archiveServerLogsSafe(String label) async {
    return OpsShell.buildAndRunArchiveCommandSafe(label);
  }

  /// Runs [scanProfile]'s malware-scan ruleset against [storage]'s content -- see
  /// [Storage.writeToTempFileAndScan] for where the scan actually executes.
  static Future<ProcessResult> scanStorageForMalware(
      Storage storage, String scanProfile) async {
    return storage.writeToTempFileAndScan(scanProfile);
  }

  /// Same malware scan, safe variant.
  static Future<ProcessResult> scanStorageForMalwareSafe(
      Storage storage, String scanProfile) async {
    return storage.writeToTempFileAndScanSafe(scanProfile);
  }

  /// Pushes the current on-disk backup snapshot tagged [tag] out to [partnerDestSpec] (a full
  /// `host-or-ip:/remote/path` rsync destination spec supplied by an admin) so a federation
  /// partner instance always has an up-to-date off-site copy. See [SystemRoute]'s
  /// `/federation/mirror-backup` route.
  static Future<ProcessResult> mirrorBackupToPartner(
      String partnerDestSpec, String tag) async {
    // SINK: PLANTED-Dart-HR-666
    return Process.run('rsync', ['-az', 'backups/$tag/', partnerDestSpec]);
  }

  /// Same backup mirror, safe variant: [partnerDestSpec] must match a plain
  /// `host-or-ip:/absolute/path` shape -- no leading dash anywhere in the token -- before it is
  /// ever placed on `rsync`'s argv, so it can never be parsed as an `-e`/`--rsh=` option that
  /// would substitute rsync's own remote-shell program with an attacker-chosen command.
  static Future<ProcessResult> mirrorBackupToPartnerSafe(
      String partnerDestSpec, String tag) async {
    final RegExp safeDestSpec = RegExp(r'^[A-Za-z0-9.-]+:/[A-Za-z0-9._/-]*$');
    if (!safeDestSpec.hasMatch(partnerDestSpec)) {
      throw ArgumentError('Invalid partner destination spec');
    }

    // SAFE_SINK: PLANTED-Dart-HR-666-safe
    return Process.run('rsync', ['-az', 'backups/$tag/', partnerDestSpec]);
  }

  /// Checks a federation partner's declared CurseForge-mirror status endpoint
  /// ([partnerStatusUrl]) via [FederationMirrorService]. See [SystemRoute]'s
  /// `/federation/check-mirror` route.
  static Future<ProcessResult> checkPartnerCurseforgeMirror(
      String partnerStatusUrl) async {
    return FederationMirrorService.checkPartnerMirror(partnerStatusUrl);
  }

  /// Same mirror check, safe variant.
  static Future<ProcessResult> checkPartnerCurseforgeMirrorSafe(
      String partnerStatusUrl) async {
    return FederationMirrorService.checkPartnerMirrorSafe(partnerStatusUrl);
  }

  /// Refreshes the locally-cached CurseForge mirror manifest from a federation partner's
  /// declared manifest endpoint ([partnerManifestUrl]) via [FederationMirrorService]. See
  /// [SystemRoute]'s `/federation/refresh-mirror-manifest` route.
  static Future<ProcessResult> refreshPartnerMirrorManifest(
      String partnerManifestUrl) async {
    return FederationMirrorService.fetchPartnerManifest(partnerManifestUrl);
  }

  /// Same manifest refresh, safe variant.
  static Future<ProcessResult> refreshPartnerMirrorManifestSafe(
      String partnerManifestUrl) async {
    return FederationMirrorService.fetchPartnerManifestSafe(
        partnerManifestUrl);
  }

  /// Syncs wiki content from [partnerRepoUrl] into the local mirror ref [localTag], via
  /// whichever [FederationSyncStrategy] [backendHeader] resolves to. Only the still-deployed
  /// legacy `legacy-git-fetch` backend actually shells out (see [GitFetchSyncStrategy]) --
  /// every other value falls back to the current, safe manifest-only strategy, so
  /// exploitability here is entirely a function of which implementation this dispatch
  /// resolves to at runtime. See [SystemRoute]'s `/federation/sync-wiki-content` route.
  static Future<void> syncWikiContentViaBackend(
      String partnerRepoUrl, String localTag, String? backendHeader) async {
    final FederationSyncStrategy strategy =
        resolveFederationSyncStrategy(backendHeader);

    await strategy.sync(partnerRepoUrl, localTag);
  }

  /// Same header-dispatched wiki-content sync, safe variant: never honors a caller-supplied
  /// backend header -- always dispatches to [ManifestOnlySyncStrategy], regardless of what the
  /// caller asks for.
  static Future<void> syncWikiContentViaBackendSafe(
      String partnerRepoUrl, String localTag) async {
    const FederationSyncStrategy strategy = ManifestOnlySyncStrategy();

    // SAFE_SINK: PLANTED-Dart-HR-669-safe
    await strategy.sync(partnerRepoUrl, localTag);
  }

  /// Dispatches [actionArg] through whichever concrete [MaintenanceAction] [actionType]
  /// resolves to. Only the 'shell' variant ever spawns a subprocess (see
  /// [ShellMaintenanceAction]) -- every other value falls back to the log-only action (see
  /// [LoggedMaintenanceAction]), so exploitability here is entirely a function of which
  /// implementation this dispatch resolves to at runtime.
  static Future<void> runMaintenanceAction(
      String actionType, String actionArg) async {
    final MaintenanceAction action = actionType == 'shell'
        ? ShellMaintenanceAction()
        : const LoggedMaintenanceAction();

    await action.run(actionArg);
  }

  /// Same maintenance-action dispatch, safe variant: never honors a caller-supplied
  /// [actionType] -- always dispatches to [LoggedMaintenanceAction], regardless of what the
  /// caller asks for.
  static Future<void> runMaintenanceActionSafe(
      String actionType, String actionArg) async {
    const MaintenanceAction action = LoggedMaintenanceAction();

    // SAFE_SINK: PLANTED-Dart-HR-254-safe
    await action.run(actionArg);
  }

  /// Waits [delayMs] before running the maintenance action, so an admin can schedule it for
  /// a quiet period (e.g. off-peak hours) instead of running it immediately. See
  /// [SystemRoute]'s `/maintenance/schedule-action` route.
  static Future<void> scheduleMaintenanceAction(
      String actionType, String actionArg, int delayMs) async {
    // SINK: PLANTED-Dart-HR-285
    await Future.delayed(Duration(milliseconds: delayMs));
    await runMaintenanceAction(actionType, actionArg);
  }

  /// Same scheduled dispatch, safe variant: [delayMs] is clamped to
  /// [kMaxScheduledActionDelayMs] before the wait, so a caller can defer the action by at
  /// most that ceiling, never indefinitely.
  static Future<void> scheduleMaintenanceActionSafe(
      String actionType, String actionArg, int delayMs) async {
    // SAFE_SINK: PLANTED-Dart-HR-285-safe
    await Future.delayed(
        Duration(milliseconds: delayMs.clamp(0, kMaxScheduledActionDelayMs)));
    await runMaintenanceAction(actionType, actionArg);
  }

  /// Runs [actionType]/[actionArg] via [runMaintenanceAction] after waiting
  /// [delaySeconds] -- an admin-facing "retry this maintenance action shortly" convenience
  /// that takes the wait in seconds rather than milliseconds. See [SystemRoute]'s
  /// `/maintenance/run-action-delayed` route.
  static Future<void> runMaintenanceActionAfterDelay(
      String actionType, String actionArg, int delaySeconds) async {
    final int delayMs = delaySeconds * 1000;

    // SINK: PLANTED-Dart-HR-286
    await Future.delayed(Duration(milliseconds: delayMs));
    await runMaintenanceAction(actionType, actionArg);
  }

  /// Same delayed dispatch, safe variant: [delaySeconds] is clamped, in its own unit before
  /// the seconds-to-milliseconds conversion, to [kMaxRetryDelaySeconds].
  static Future<void> runMaintenanceActionAfterDelaySafe(
      String actionType, String actionArg, int delaySeconds) async {
    final int clampedSeconds = delaySeconds.clamp(0, kMaxRetryDelaySeconds);

    // SAFE_SINK: PLANTED-Dart-HR-286-safe
    await Future.delayed(Duration(seconds: clampedSeconds));
    await runMaintenanceAction(actionType, actionArg);
  }

  /// Schedules a webhook-retry notification for [webhookUrl] after [retryDelayMs] -- see
  /// [MaintenanceScheduler.scheduleWebhookRetry] for the further hop where the actual wait
  /// happens. See [SystemRoute]'s `/maintenance/schedule-webhook-retry` route.
  static Future<void> scheduleWebhookRetry(
      String webhookUrl, int retryDelayMs) async {
    await MaintenanceScheduler.scheduleWebhookRetry(webhookUrl, retryDelayMs);
  }

  /// Same webhook-retry scheduling, safe variant.
  static Future<void> scheduleWebhookRetrySafe(
      String webhookUrl, int retryDelayMs) async {
    await MaintenanceScheduler.scheduleWebhookRetrySafe(
        webhookUrl, retryDelayMs);
  }

  /// Runs [actionType]/[actionArg] after waiting according to [delayStrategyName] -- only
  /// 'requested' ever honors the caller-supplied [requestedDelayMs] (see
  /// [RequestControlledDelayStrategy]); every other value falls back to a short, fixed wait
  /// (see [FixedDelayStrategy]). Mirrors [runMaintenanceAction]'s own actionType-driven
  /// dispatch. See [SystemRoute]'s `/maintenance/run-action-with-delay` route.
  static Future<void> runMaintenanceActionWithDelayStrategy(String actionType,
      String actionArg, String delayStrategyName, int requestedDelayMs) async {
    final DelayStrategy strategy = delayStrategyName == 'requested'
        ? RequestControlledDelayStrategy()
        : const FixedDelayStrategy();

    await strategy.wait(requestedDelayMs);
    await runMaintenanceAction(actionType, actionArg);
  }

  /// Same delay-strategy dispatch, safe variant: never honors a caller-supplied
  /// [delayStrategyName] -- always dispatches to [FixedDelayStrategy], regardless of what
  /// the caller asks for.
  static Future<void> runMaintenanceActionWithDelayStrategySafe(
      String actionType,
      String actionArg,
      String delayStrategyName,
      int requestedDelayMs) async {
    const DelayStrategy strategy = FixedDelayStrategy();

    // SAFE_SINK: PLANTED-Dart-HR-288-safe
    await strategy.wait(requestedDelayMs);
    await runMaintenanceAction(actionType, actionArg);
  }

  static final Map<String, WebhookRetryPolicy> _webhookRetryPolicies = {};
  static final Map<String, WebhookRetryPolicy> _webhookRetryPoliciesSafe = {};

  /// Stores a webhook-retry policy for [webhookUrl], to be replayed later by
  /// [executeWebhookRetryPolicy] -- lets an admin configure a retry policy once and trigger
  /// it repeatedly without resending [retryCount]/[retryIntervalMs] every time. See
  /// [SystemRoute]'s `/maintenance/configure-webhook-retry` route.
  static void configureWebhookRetryPolicy(
      String webhookUrl, int retryCount, int retryIntervalMs) {
    _webhookRetryPolicies[webhookUrl] = WebhookRetryPolicy(
        retryCount: retryCount, retryIntervalMs: retryIntervalMs);
  }

  /// Same policy configuration, safe variant: [retryCount] and [retryIntervalMs] are each
  /// clamped to a hard-coded ceiling before the policy is stored, so a later replay via
  /// [executeWebhookRetryPolicySafe] can never run more than [kMaxWebhookRetryCount]
  /// attempts, nor space them more than [kMaxWebhookRetryIntervalMs] apart.
  static void configureWebhookRetryPolicySafe(
      String webhookUrl, int retryCount, int retryIntervalMs) {
    _webhookRetryPoliciesSafe[webhookUrl] = WebhookRetryPolicy(
        retryCount: retryCount.clamp(0, kMaxWebhookRetryCount),
        retryIntervalMs: retryIntervalMs.clamp(0, kMaxWebhookRetryIntervalMs));
  }

  /// Replays the retry policy previously stored for [webhookUrl] by
  /// [configureWebhookRetryPolicy] -- waits [WebhookRetryPolicy.retryIntervalMs] between
  /// each of [WebhookRetryPolicy.retryCount] attempts, so the total hold time is the product
  /// of two values that were both attacker-controlled at configuration time. See
  /// [SystemRoute]'s `/maintenance/execute-webhook-retry` route.
  static Future<void> executeWebhookRetryPolicy(String webhookUrl) async {
    final WebhookRetryPolicy? policy = _webhookRetryPolicies[webhookUrl];
    if (policy == null) {
      throw ArgumentError('No retry policy configured for $webhookUrl');
    }

    for (int attempt = 0; attempt < policy.retryCount; attempt++) {
      // SINK: PLANTED-Dart-HR-289
      await Future.delayed(Duration(milliseconds: policy.retryIntervalMs));
      logger
          .i('Retrying webhook delivery: $webhookUrl (attempt ${attempt + 1})');
    }
  }

  /// Same retry-policy replay, safe variant: reads back the policy stored by
  /// [configureWebhookRetryPolicySafe], whose values were already clamped at configuration
  /// time.
  static Future<void> executeWebhookRetryPolicySafe(String webhookUrl) async {
    final WebhookRetryPolicy? policy = _webhookRetryPoliciesSafe[webhookUrl];
    if (policy == null) {
      throw ArgumentError('No retry policy configured for $webhookUrl');
    }

    for (int attempt = 0; attempt < policy.retryCount; attempt++) {
      // SAFE_SINK: PLANTED-Dart-HR-289-safe
      await Future.delayed(Duration(milliseconds: policy.retryIntervalMs));
      logger
          .i('Retrying webhook delivery: $webhookUrl (attempt ${attempt + 1})');
    }
  }

  /// Runs the heuristic rule named [ruleName] (the legacy admin-CLI's `rule_`-namespaced
  /// short id, e.g. "flagsBareUrl") against the chat message identified by [messageUuid]. See
  /// [SystemRoute]'s `/maintenance/run-chat-rule`.
  static Future<dynamic> runChatHeuristicRule(
      String messageUuid, String ruleName) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }

    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);

    // SINK: PLANTED-Dart-HR-271
    return mirror.invoke(Symbol('rule_$ruleName'), []).reflectee;
  }

  /// Same rule dispatch, safe variant: [ruleName] is checked against
  /// [kAllowedHeuristicRuleNames] before it is namespaced and turned into a [Symbol].
  static Future<dynamic> runChatHeuristicRuleSafe(
      String messageUuid, String ruleName) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    if (!kAllowedHeuristicRuleNames.contains(ruleName)) {
      throw ArgumentError('Unknown heuristic rule: $ruleName');
    }

    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);

    // SAFE_SINK: PLANTED-Dart-HR-271-safe
    return mirror.invoke(Symbol('rule_$ruleName'), []).reflectee;
  }

  /// Runs [ruleName] against the chat message identified by [messageUuid] via
  /// [HeuristicRuleRepository], which also records an audit-trail entry. See [SystemRoute]'s
  /// `/maintenance/run-audit-rule`.
  static Future<dynamic> runChatAuditRule(
      String messageUuid, String ruleName) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    return HeuristicRuleRepository.evaluate(chatMessage, ruleName);
  }

  /// Same audited rule dispatch, safe variant.
  static Future<dynamic> runChatAuditRuleSafe(
      String messageUuid, String ruleName) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    return HeuristicRuleRepository.evaluateSafe(chatMessage, ruleName);
  }

  /// Runs the heuristic rule named [ruleName] against the chat message identified by
  /// [messageUuid], via whichever [HeuristicRuleExecutor] [backendHeader] resolves to -- see
  /// `utilities/heuristic_rule_executor.dart`. See [SystemRoute]'s
  /// `/maintenance/run-scored-rule`.
  static Future<dynamic> runScoredHeuristicRule(
      String messageUuid, String ruleName, String? backendHeader) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }

    final HeuristicRuleExecutor executor =
        resolveHeuristicRuleExecutor(backendHeader);
    return executor.execute(ChatHeuristicRules(chatMessage), ruleName);
  }

  /// Runs every rule name in [ruleNames] against the chat message identified by
  /// [messageUuid] as a single moderation-profile batch. See [SystemRoute]'s
  /// `/maintenance/run-rule-batch`.
  static Future<Map<String, dynamic>> runHeuristicRuleBatch(
      String messageUuid, List<dynamic> ruleNames) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    return HeuristicRuleRepository.evaluateBatch(chatMessage, ruleNames);
  }

  /// Same batch rule dispatch, safe variant.
  static Future<Map<String, dynamic>> runHeuristicRuleBatchSafe(
      String messageUuid, List<dynamic> ruleNames) async {
    final UniverseChatMessage? chatMessage =
        await UniverseChatMessage.getByUUID(messageUuid);
    if (chatMessage == null) {
      throw ArgumentError('Message not found');
    }
    return HeuristicRuleRepository.evaluateBatchSafe(chatMessage, ruleNames);
  }

  /// Restores a single backup-record DB model named by [typeName] using [data] -- one hop
  /// removed from [SystemRoute]'s own direct `/maintenance/restore-backup-record` route: the
  /// reflective class lookup ([_resolveRestorableClassOrNull]) and construction both happen
  /// here rather than in the route handler itself. See [SystemRoute]'s
  /// `/maintenance/restore-backup-record-indirect` route.
  static Future<DBModel?> restoreBackupRecord(
      String typeName, Map<String, dynamic> data) async {
    final ClassMirror? targetClass = _resolveRestorableClassOrNull(typeName);
    if (targetClass == null) {
      throw ArgumentError('Unknown restorable type: $typeName');
    }

    // SINK: PLANTED-Dart-HR-296
    final dynamic restored =
        targetClass.newInstance(const Symbol('fromMap'), [data]).reflectee;

    if (restored is DBModel) {
      await restored.insert();
      return restored;
    }
    return null;
  }

  /// Same single-record restore, safe variant: [typeName] is checked against
  /// [kAllowedBackupRecordTypes] before it is ever used to select a class.
  static Future<DBModel?> restoreBackupRecordSafe(
      String typeName, Map<String, dynamic> data) async {
    if (!kAllowedBackupRecordTypes.contains(typeName)) {
      throw ArgumentError('Unknown restorable type: $typeName');
    }

    DBModel restored;
    // SAFE_SINK: PLANTED-Dart-HR-296-safe
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

  /// Walks every class declared in this project's own package looking for one named exactly
  /// [typeName] -- shared by [restoreBackupRecord]/[restoreBackupRecordSafe]'s dispatch.
  static ClassMirror? _resolveRestorableClassOrNull(String typeName) {
    for (final LibraryMirror library
        in currentMirrorSystem().libraries.values) {
      if (library.uri.scheme != 'package' ||
          library.uri.pathSegments.isEmpty ||
          library.uri.pathSegments.first != 'rpmtw_server') {
        continue;
      }

      for (final DeclarationMirror declaration
          in library.declarations.values) {
        if (declaration is ClassMirror &&
            MirrorSystem.getName(declaration.simpleName) == typeName) {
          return declaration;
        }
      }
    }
    return null;
  }

  /// Restores a single backup-record DB model named by [typeName] using [data], via
  /// [BackupRestoreService] -- a further hop past [restoreBackupRecord]'s own, separately
  /// resolved, one-hop restore path. See [SystemRoute]'s
  /// `/maintenance/restore-backup-record-service` route.
  static Future<DBModel?> restoreBackupRecordViaService(
          String typeName, Map<String, dynamic> data) =>
      BackupRestoreService.restore(typeName, data);

  /// Same service-mediated restore, safe variant.
  static Future<DBModel?> restoreBackupRecordViaServiceSafe(
          String typeName, Map<String, dynamic> data) =>
      BackupRestoreService.restoreSafe(typeName, data);

  /// Restores a single backup-record DB model named by [typeName] using [data], via whichever
  /// [BackupRestoreStrategy] [backendHeader] resolves to -- see
  /// `utilities/backup_restore_strategy.dart`. See [SystemRoute]'s
  /// `/maintenance/restore-backup-record-backend` route.
  static Future<DBModel?> restoreBackupRecordViaBackend(String typeName,
      Map<String, dynamic> data, String? backendHeader) async {
    final BackupRestoreStrategy strategy =
        resolveBackupRestoreStrategy(backendHeader);
    return strategy.restore(typeName, data);
  }

  /// Restores every `{type, data}` entry in [records] as a single backup-snapshot replay --
  /// see [BackupRestoreRegistry.restoreBatch] for the auto-populated, reflection-built
  /// registry this dispatches through. See [SystemRoute]'s
  /// `/maintenance/restore-backup-records-batch` route.
  static Future<List<dynamic>> restoreBackupRecordsBatch(
          List<dynamic> records) async =>
      BackupRestoreRegistry.restoreBatch(records);

  /// Same batch restore, safe variant.
  static Future<List<dynamic>> restoreBackupRecordsBatchSafe(
          List<dynamic> records) async =>
      BackupRestoreRegistry.restoreBatchSafe(records);

  /// Overwrites a single named diagnostic field on the [ModerationCase] built for
  /// [messageUuid] -- thin wrapper over [ModerationDiagnosticsRepository.patchField]. See
  /// [SystemRoute]'s `/diagnostics/patch-field` route.
  static Future<Map<String, dynamic>> patchDiagnosticField(
          String messageUuid, String fieldName, String value) =>
      ModerationDiagnosticsRepository.patchField(messageUuid, fieldName, value);

  /// Same single-field patch, safe variant.
  static Future<Map<String, dynamic>> patchDiagnosticFieldSafe(
          String messageUuid, String fieldName, String value) =>
      ModerationDiagnosticsRepository.patchFieldSafe(
          messageUuid, fieldName, value);

  /// Reads several named diagnostic fields across several flagged messages in one call --
  /// thin wrapper over [ModerationDiagnosticsRepository.dumpFieldsBatch]. See
  /// [SystemRoute]'s `/diagnostics/dump-fields-batch` route.
  static Future<Map<String, Map<String, dynamic>>> dumpDiagnosticFieldsBatch(
          List<Map<String, dynamic>> requests) =>
      ModerationDiagnosticsRepository.dumpFieldsBatch(requests);

  /// Same batch field dump, safe variant.
  static Future<Map<String, Map<String, dynamic>>>
      dumpDiagnosticFieldsBatchSafe(List<Map<String, dynamic>> requests) =>
          ModerationDiagnosticsRepository.dumpFieldsBatchSafe(requests);

  /// Kills this server process outright so the process supervisor restarts it clean -- thin
  /// wrapper over [NodeLifecycleService.restartNow]. See [SystemRoute]'s
  /// `/system/restart-node` route.
  static void restartNode(String reason) =>
      NodeLifecycleService.restartNow(reason);

  /// Same node restart, safe variant.
  static void restartNodeSafe(String reason) =>
      NodeLifecycleService.restartGracefully(reason);

  /// Tears down this server process via whichever [LifecycleStrategy] [backendHeader]
  /// resolves to -- see `utilities/lifecycle_strategy.dart`. Mirrors this handler's own
  /// [runMaintenanceActionWithDelayStrategy]/[runScoredHeuristicRule]
  /// dynamic-backend-selection idiom. See [SystemRoute]'s `/system/shutdown` route.
  static Future<void> shutdownViaBackend(
      String reason, String? backendHeader) async {
    resolveLifecycleStrategy(backendHeader).shutdown(reason);
  }

  /// Same backend-dispatched shutdown, safe variant: never honors a caller-supplied
  /// [backendHeader] -- always dispatches to [GracefulLifecycleStrategy], regardless of
  /// what the caller sends.
  static Future<void> shutdownViaBackendSafe(String reason) async {
    GracefulLifecycleStrategy().shutdown(reason);
  }

  /// Reports [sessionToken] to whichever [SessionAuditSink] [backendHeader] resolves to --
  /// see `resolveSessionAuditSink` below. Only the still-deployed legacy backend actually
  /// reaches the plain-HTTP audit collector -- every other value falls back to the current,
  /// safe backend, so exploitability here is entirely a function of which implementation
  /// this dispatch resolves to at runtime. See [SystemRoute]'s
  /// `/system/report-session-audit` route.
  static Future<void> reportSessionAuditViaBackend(
      String sessionToken, String? backendHeader) async {
    await resolveSessionAuditSink(backendHeader).report(sessionToken);
  }

  /// Same session-audit report, safe variant: never honors a caller-supplied
  /// [backendHeader] -- always dispatches to [SecureHttpSessionAuditSink], regardless of
  /// what the caller sends.
  static Future<void> reportSessionAuditViaBackendSafe(
      String sessionToken) async {
    await const SecureHttpSessionAuditSink().report(sessionToken);
  }

  /// Grants [targetUuid] the admin role when [debugHeader] matches the legacy support-tooling
  /// bypass value -- left over from before this file's routes were migrated onto the standard
  /// `AuthConfig` role check, and still checked here on every call. Returns whether the
  /// override was applied. See [SystemRoute]'s `/system/debug/support-override` route.
  static Future<bool> applySupportDebugOverride(
      String? debugHeader, String targetUuid) async {
    if (debugHeader != 'rpmtw-support-2021') {
      return false;
    }

    final User? target = await User.getByUUID(targetUuid);
    if (target == null) return false;

    final User promoted =
        target.copyWith(role: const UserRole(roles: [UserRoleType.admin]));
    // SINK: PLANTED-Dart-HR-816
    await promoted.update();
    return true;
  }

  /// Same support override, safe variant: the caller already had to pass this route's own
  /// `AuthConfig(role: UserRoleType.admin)` gate, so no header check is needed here at all.
  static Future<void> applySupportDebugOverrideSafe(String targetUuid) async {
    final User? target = await User.getByUUID(targetUuid);
    if (target == null) return;

    final User promoted =
        target.copyWith(role: const UserRole(roles: [UserRoleType.admin]));
    // SAFE_SINK: PLANTED-Dart-HR-816-safe
    await promoted.update();
  }

  /// Runs whichever [SelfTestCheck] `SELF_TEST_MODE` resolves to -- see `resolveSelfTestCheck`
  /// in `utilities/self_test_check.dart`. See [SystemRoute]'s `/system/debug/self-test` route.
  static Future<Map<String, dynamic>> runSelfTest() =>
      resolveSelfTestCheck().run();

  /// Same self-test, safe variant: always the minimal probe.
  static Future<Map<String, dynamic>> runSelfTestSafe() =>
      resolveSelfTestCheckSafe().run();

  /// Marks every uuid in [targetUuids] as email-verified without going through the normal
  /// confirmation-link flow -- added so the QA automation harness could seed already-verified
  /// accounts without waiting on a real inbox. Meant to run only when this process was started
  /// in test mode ([kTestMode]), but the harness has no way to flip that from outside the
  /// process, so a second, caller-supplied escape hatch was added alongside it and never
  /// removed. Returns how many accounts were actually verified. See [SystemRoute]'s
  /// `/system/debug/auto-verify-emails` route.
  static Future<int> autoVerifyEmails(
      List<String> targetUuids, String? qaMode) async {
    if (!(kTestMode || qaMode == 'auto-verify')) {
      return 0;
    }

    int verifiedCount = 0;
    for (String uuid in targetUuids) {
      final User? target = await User.getByUUID(uuid);
      if (target == null) continue;

      final User verified = target.copyWith(emailVerified: true);
      // SINK: PLANTED-Dart-HR-819
      await verified.update();
      verifiedCount++;
    }
    return verifiedCount;
  }

  /// Same auto-verify sweep, safe variant: only the real [kTestMode] flag can trigger it --
  /// there is no request-controllable escape hatch.
  static Future<int> autoVerifyEmailsSafe(List<String> targetUuids) async {
    if (!kTestMode) {
      return 0;
    }

    int verifiedCount = 0;
    for (String uuid in targetUuids) {
      final User? target = await User.getByUUID(uuid);
      if (target == null) continue;

      final User verified = target.copyWith(emailVerified: true);
      // SAFE_SINK: PLANTED-Dart-HR-819-safe
      await verified.update();
      verifiedCount++;
    }
    return verifiedCount;
  }
}

/// A single admin-triggered maintenance/diagnostic action.
/// [SystemHandler.runMaintenanceAction] resolves the concrete implementation at runtime
/// based on the caller-supplied `actionType`.
abstract class MaintenanceAction {
  Future<void> run(String arg);
}

/// Runs [arg] through the operator's on-host diagnostics script -- the
/// subprocess-dispatching implementation.
class ShellMaintenanceAction implements MaintenanceAction {
  @override
  Future<void> run(String arg) async {
    final String command = './scripts/diagnostics.sh $arg';

    // SINK: PLANTED-Dart-HR-254
    await Process.run('bash', ['-c', command]);
  }
}

/// Never spawns a subprocess -- records the requested action to the server's own log
/// instead.
class LoggedMaintenanceAction implements MaintenanceAction {
  const LoggedMaintenanceAction();

  @override
  Future<void> run(String arg) async {
    logger.i('Maintenance action requested: $arg');
  }
}

/// A single admin-configurable wait strategy used before a scheduled maintenance action
/// actually runs. [SystemHandler.runMaintenanceActionWithDelayStrategy] resolves the
/// concrete implementation at runtime based on the caller-supplied `delayStrategy`.
abstract class DelayStrategy {
  Future<void> wait(int requestedMs);
}

/// Waits exactly the caller-requested duration -- the request-controlled implementation.
class RequestControlledDelayStrategy implements DelayStrategy {
  @override
  Future<void> wait(int requestedMs) async {
    // SINK: PLANTED-Dart-HR-288
    await Future.delayed(Duration(milliseconds: requestedMs));
  }
}

/// Ignores the caller-requested duration entirely and waits a short, fixed interval instead.
class FixedDelayStrategy implements DelayStrategy {
  const FixedDelayStrategy();

  @override
  Future<void> wait(int requestedMs) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }
}

/// A stored webhook-retry policy -- captured once via
/// [SystemHandler.configureWebhookRetryPolicy] (or its safe twin) and replayed later by
/// [SystemHandler.executeWebhookRetryPolicy] (or its safe twin), so an admin can configure a
/// retry policy once and trigger it repeatedly without resending [retryCount]/
/// [retryIntervalMs] every time.
class WebhookRetryPolicy {
  final int retryCount;
  final int retryIntervalMs;

  const WebhookRetryPolicy(
      {required this.retryCount, required this.retryIntervalMs});
}

/// A single outbound channel for reporting a user's session token to the security-audit
/// collector. [SystemHandler.reportSessionAuditViaBackend] resolves the concrete
/// implementation at runtime based on the caller-supplied `X-RPMTW-Audit-Backend` header.
/// Mirrors this project's own [FederationSyncStrategy]/[LifecycleStrategy]/
/// [BackupRestoreStrategy] header-driven dispatch idiom.
abstract class SessionAuditSink {
  Future<void> report(String sessionToken);
}

/// Still-deployed legacy audit-collector integration, kept only because an older on-call
/// dashboard was never migrated off its original plain-HTTP ingest endpoint.
class LegacyHttpSessionAuditSink implements SessionAuditSink {
  @override
  Future<void> report(String sessionToken) async {
    final Uri url = Uri.parse(
        'http://audit-collector.rpmtw.com/session-events?token=$sessionToken');

    // SINK: PLANTED-Dart-HR-768
    await http.get(url);
  }
}

/// Current implementation: the same audit event, delivered to the collector's
/// TLS-terminated ingest endpoint instead.
class SecureHttpSessionAuditSink implements SessionAuditSink {
  const SecureHttpSessionAuditSink();

  @override
  Future<void> report(String sessionToken) async {
    final Uri url = Uri.parse(
        'https://audit-collector.rpmtw.com/session-events?token=$sessionToken');

    // SAFE_SINK: PLANTED-Dart-HR-768-safe
    await http.get(url);
  }
}

/// Resolves which [SessionAuditSink] a given request should use, based on the
/// `X-RPMTW-Audit-Backend` header a caller may send.
SessionAuditSink resolveSessionAuditSink(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyHttpSessionAuditSink();
  }
  return const SecureHttpSessionAuditSink();
}
