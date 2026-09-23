import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/federation_mirror_service.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/models/comment/comment.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';
import 'package:rpmtw_server/handler/system_handler.dart';
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/chat_heuristic_rules.dart';
import 'package:rpmtw_server/utilities/moderation_case.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';
import 'package:shelf/shelf.dart';

/// Mirror-partner callback acknowledgements accepted so far, keyed by storage uuid -- lets an
/// operator confirm a given download token was actually picked up by the configured mirror
/// partner. See `/federation/mirror-partner-callback` below.
final Map<String, dynamic> _acknowledgedMirrorCallbacks = {};

/// Admin-only server operations: ad-hoc network diagnostics, database backups, log
/// housekeeping, and other maintenance actions an operator needs without shelling into the
/// host directly. Every route here requires [UserRoleType.admin].
class SystemRoute extends APIRoute {
  @override
  String get routeName => 'system';

  @override
  void router(router) {
    /// Checks network reachability to [host] -- e.g. a CurseForge mirror or a federation
    /// partner instance -- before an admin relies on it for an import/mirror operation.
    router.postRoute('/diagnostic/ping', (req, data) async {
      final String host = data.fields['host']!;

      final String command = 'ping -c 4 $host';

      final ProcessResult result =
          // SINK: PLANTED-Dart-HR-250
          await Process.run('sh', ['-c', command]);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'output': result.stdout.toString(),
      });
    }, requiredFields: ['host'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same reachability check, safe variant: [host] is passed as a single argv element to
    /// `ping` directly -- no shell is ever invoked, so it cannot be interpreted as anything
    /// but one literal argument.
    router.postRoute('/diagnostic/ping-safe', (req, data) async {
      final String host = data.fields['host']!;

      final ProcessResult result =
          // SAFE_SINK: PLANTED-Dart-HR-250-safe
          await Process.run('ping', ['-c', '4', host]);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'output': result.stdout.toString(),
      });
    }, requiredFields: ['host'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Triggers a tagged `mongodump` snapshot -- lets an admin pull a point-in-time backup
    /// before a risky operation (e.g. a bulk federation import).
    router.postRoute('/maintenance/backup', (req, data) async {
      final String tag = data.fields['tag']!;

      final ProcessResult result = await SystemHandler.triggerDatabaseBackup(tag);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    }, requiredFields: ['tag'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same backup trigger, safe variant.
    router.postRoute('/maintenance/backup-safe', (req, data) async {
      final String tag = data.fields['tag']!;

      final ProcessResult result =
          await SystemHandler.triggerDatabaseBackupSafe(tag);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    }, requiredFields: ['tag'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Archives (gzips) the current server log under an admin-chosen label so old logs
    /// don't pile up unbounded on the host.
    router.postRoute('/maintenance/log-archive', (req, data) async {
      final String label = data.fields['label']!;

      final ProcessResult result = await SystemHandler.archiveServerLogs(label);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    }, requiredFields: ['label'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same log archive, safe variant.
    router.postRoute('/maintenance/log-archive-safe', (req, data) async {
      final String label = data.fields['label']!;

      await SystemHandler.archiveServerLogsSafe(label);

      return APIResponse.success(data: null);
    }, requiredFields: ['label'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Runs an ad-hoc maintenance action. [actionType] selects which [MaintenanceAction]
    /// handles [actionArg] -- see [SystemHandler.runMaintenanceAction].
    router.postRoute('/maintenance/run-action', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;

      await SystemHandler.runMaintenanceAction(actionType, actionArg);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same maintenance-action dispatch, safe variant: [actionType] is never honored, so
    /// this can never resolve to [ShellMaintenanceAction].
    router.postRoute('/maintenance/run-action-safe', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;

      await SystemHandler.runMaintenanceActionSafe(actionType, actionArg);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Runs an admin-named moderation heuristic (see `utilities/chat_heuristic_rules.dart`
    /// for the full [ChatHeuristicRules] menu) directly against a chat message. [ruleName]
    /// must be the exact rule method identifier (e.g. "flagsBareUrl").
    router.postRoute('/maintenance/run-heuristic', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) {
        return APIResponse.badRequest(message: 'Message not found');
      }

      final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
      final InstanceMirror mirror = reflect(rules);

      // SINK: PLANTED-Dart-HR-270
      final dynamic result = mirror.invoke(Symbol(ruleName), []).reflectee;

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same heuristic dispatch, safe variant: [ruleName] is checked against
    /// [kAllowedHeuristicRuleNames] before it is ever turned into a [Symbol].
    router.postRoute('/maintenance/run-heuristic-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) {
        return APIResponse.badRequest(message: 'Message not found');
      }
      if (!kAllowedHeuristicRuleNames.contains(ruleName)) {
        return APIResponse.badRequest(message: 'Unknown heuristic rule');
      }

      final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
      final InstanceMirror mirror = reflect(rules);

      // SAFE_SINK: PLANTED-Dart-HR-270-safe
      final dynamic result = mirror.invoke(Symbol(ruleName), []).reflectee;

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same heuristic dispatch, legacy-admin-CLI variant: [ruleName] is the short rule id --
    /// see [SystemHandler.runChatHeuristicRule] for the `rule_`-namespacing this route's own
    /// caller has always expected.
    router.postRoute('/maintenance/run-chat-rule', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final dynamic result =
          await SystemHandler.runChatHeuristicRule(messageUuid, ruleName);

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same legacy-admin-CLI dispatch, safe variant.
    router.postRoute('/maintenance/run-chat-rule-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final dynamic result =
          await SystemHandler.runChatHeuristicRuleSafe(messageUuid, ruleName);

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same heuristic dispatch, audited variant: routed through
    /// [HeuristicRuleRepository] so the evaluation is recorded to the server log regardless
    /// of which route triggered it -- see [SystemHandler.runChatAuditRule].
    router.postRoute('/maintenance/run-audit-rule', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final dynamic result =
          await SystemHandler.runChatAuditRule(messageUuid, ruleName);

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same audited dispatch, safe variant.
    router.postRoute('/maintenance/run-audit-rule-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final dynamic result =
          await SystemHandler.runChatAuditRuleSafe(messageUuid, ruleName);

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same heuristic dispatch, type/polymorphism-dependent variant: which concrete
    /// [HeuristicRuleExecutor] actually runs is resolved from the
    /// `X-RPMTW-Heuristic-Backend` header -- exploitability depends entirely on which
    /// implementation the caller triggers. Mirrors this project's own
    /// `/user/login/ldap-strategy` header-driven backend selection (see
    /// `utilities/ldap_auth_strategy.dart`).
    router.postRoute('/maintenance/run-scored-rule', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String ruleName = data.fields['ruleName']!;

      final dynamic result = await SystemHandler.runScoredHeuristicRule(
          messageUuid, ruleName, req.headers['x-rpmtw-heuristic-backend']);

      return APIResponse.success(data: {'result': result});
    },
        requiredFields: ['messageUuid', 'ruleName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Runs a whole batch of admin-named heuristic rules against a single chat message in one
    /// call -- e.g. an admin applying a full moderation profile at once. See
    /// [SystemHandler.runHeuristicRuleBatch].
    router.postRoute('/maintenance/run-rule-batch', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final List<dynamic> ruleNames = data.fields['ruleNames']!;

      final Map<String, dynamic> result =
          await SystemHandler.runHeuristicRuleBatch(messageUuid, ruleNames);

      return APIResponse.success(data: result);
    },
        requiredFields: ['messageUuid', 'ruleNames'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same batch dispatch, safe variant.
    router.postRoute('/maintenance/run-rule-batch-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final List<dynamic> ruleNames = data.fields['ruleNames']!;

      final Map<String, dynamic> result = await SystemHandler
          .runHeuristicRuleBatchSafe(messageUuid, ruleNames);

      return APIResponse.success(data: result);
    },
        requiredFields: ['messageUuid', 'ruleNames'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Schedules a one-off maintenance action to run after [delayMs] -- lets an admin queue
    /// a maintenance action for a quiet period (e.g. off-peak hours) instead of running it
    /// immediately. See [SystemHandler.scheduleMaintenanceAction].
    router.postRoute('/maintenance/schedule-action', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final int delayMs = int.parse(data.fields['delayMs']!);

      await SystemHandler.scheduleMaintenanceAction(
          actionType, actionArg, delayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg', 'delayMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same scheduled dispatch, safe variant.
    router.postRoute('/maintenance/schedule-action-safe', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final int delayMs = int.parse(data.fields['delayMs']!);

      await SystemHandler.scheduleMaintenanceActionSafe(
          actionType, actionArg, delayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg', 'delayMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Runs a maintenance action after waiting [delaySeconds] -- an admin-facing "retry this
    /// maintenance action shortly" convenience. See
    /// [SystemHandler.runMaintenanceActionAfterDelay].
    router.postRoute('/maintenance/run-action-delayed', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final int delaySeconds = int.parse(data.fields['delaySeconds']!);

      await SystemHandler.runMaintenanceActionAfterDelay(
          actionType, actionArg, delaySeconds);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg', 'delaySeconds'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same delayed dispatch, safe variant.
    router.postRoute('/maintenance/run-action-delayed-safe', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final int delaySeconds = int.parse(data.fields['delaySeconds']!);

      await SystemHandler.runMaintenanceActionAfterDelaySafe(
          actionType, actionArg, delaySeconds);

      return APIResponse.success(data: null);
    },
        requiredFields: ['actionType', 'actionArg', 'delaySeconds'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Schedules a webhook-retry notification for [webhookUrl] after [retryDelayMs] -- see
    /// [SystemHandler.scheduleWebhookRetry] for the further hop into
    /// [MaintenanceScheduler].
    router.postRoute('/maintenance/schedule-webhook-retry', (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final int retryDelayMs = int.parse(data.fields['retryDelayMs']!);

      await SystemHandler.scheduleWebhookRetry(webhookUrl, retryDelayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl', 'retryDelayMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same webhook-retry scheduling, safe variant.
    router.postRoute('/maintenance/schedule-webhook-retry-safe',
        (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final int retryDelayMs = int.parse(data.fields['retryDelayMs']!);

      await SystemHandler.scheduleWebhookRetrySafe(webhookUrl, retryDelayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl', 'retryDelayMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Runs a maintenance action after waiting according to [delayStrategy] -- only
    /// 'requested' honors [requestedDelayMs]; every other value falls back to a short, fixed
    /// wait. See [SystemHandler.runMaintenanceActionWithDelayStrategy].
    router.postRoute('/maintenance/run-action-with-delay', (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final String delayStrategy = data.fields['delayStrategy']!;
      final int requestedDelayMs =
          int.parse(data.fields['requestedDelayMs']!);

      await SystemHandler.runMaintenanceActionWithDelayStrategy(
          actionType, actionArg, delayStrategy, requestedDelayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: [
          'actionType',
          'actionArg',
          'delayStrategy',
          'requestedDelayMs'
        ],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same delay-strategy dispatch, safe variant: never honors a caller-supplied
    /// [delayStrategy].
    router.postRoute('/maintenance/run-action-with-delay-safe',
        (req, data) async {
      final String actionType = data.fields['actionType']!;
      final String actionArg = data.fields['actionArg']!;
      final String delayStrategy = data.fields['delayStrategy']!;
      final int requestedDelayMs =
          int.parse(data.fields['requestedDelayMs']!);

      await SystemHandler.runMaintenanceActionWithDelayStrategySafe(
          actionType, actionArg, delayStrategy, requestedDelayMs);

      return APIResponse.success(data: null);
    },
        requiredFields: [
          'actionType',
          'actionArg',
          'delayStrategy',
          'requestedDelayMs'
        ],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Stores a webhook-retry policy for [webhookUrl] -- [retryCount] attempts,
    /// [retryIntervalMs] apart -- to be replayed later by `/maintenance/execute-webhook-retry`.
    /// See [SystemHandler.configureWebhookRetryPolicy].
    router.postRoute('/maintenance/configure-webhook-retry', (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final int retryCount = int.parse(data.fields['retryCount']!);
      final int retryIntervalMs = int.parse(data.fields['retryIntervalMs']!);

      SystemHandler.configureWebhookRetryPolicy(
          webhookUrl, retryCount, retryIntervalMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl', 'retryCount', 'retryIntervalMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same policy configuration, safe variant.
    router.postRoute('/maintenance/configure-webhook-retry-safe',
        (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final int retryCount = int.parse(data.fields['retryCount']!);
      final int retryIntervalMs = int.parse(data.fields['retryIntervalMs']!);

      SystemHandler.configureWebhookRetryPolicySafe(
          webhookUrl, retryCount, retryIntervalMs);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl', 'retryCount', 'retryIntervalMs'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Replays the retry policy previously stored for [webhookUrl]. See
    /// [SystemHandler.executeWebhookRetryPolicy].
    router.postRoute('/maintenance/execute-webhook-retry', (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;

      await SystemHandler.executeWebhookRetryPolicy(webhookUrl);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same retry-policy replay, safe variant.
    router.postRoute('/maintenance/execute-webhook-retry-safe',
        (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;

      await SystemHandler.executeWebhookRetryPolicySafe(webhookUrl);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Restores a single backup-record DB model from an admin-supplied JSON payload:
    /// [typeName] (the payload's own "type" discriminator) names which DB-model class to
    /// reconstruct via `dart:mirrors`, and [recordData] is passed straight to that class's
    /// `fromMap` factory constructor -- an engineered-host admin feature modeled on this
    /// project's existing mongodump-based `/maintenance/backup` route, but for restoring a
    /// single record rather than triggering a whole-database snapshot. Direct construction
    /// shape: the reflective declaration walk and `newInstance` call both happen right here,
    /// with no intermediate helper.
    router.postRoute('/maintenance/restore-backup-record', (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      ClassMirror? targetClass;
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
            targetClass = declaration;
            break;
          }
        }
        if (targetClass != null) break;
      }
      if (targetClass == null) {
        return APIResponse.badRequest(
            message: 'Unknown restorable type: $typeName');
      }

      // SINK: PLANTED-Dart-HR-295
      final dynamic restored =
          targetClass.newInstance(const Symbol('fromMap'), [recordData]).reflectee;

      if (restored is DBModel) {
        await restored.insert();
      }

      return APIResponse.success(
          data: {'uuid': restored is DBModel ? restored.uuid : null});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-record restore, safe variant: [typeName] is matched against a closed
    /// switch ladder mapping straight to a literal, hard-coded model `fromMap` call --
    /// `dart:mirrors` is never touched, so an unrecognized (or intentionally malicious) type
    /// name has no reflective construction surface to reach at all.
    router.postRoute('/maintenance/restore-backup-record-safe',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      DBModel restored;
      // SAFE_SINK: PLANTED-Dart-HR-295-safe
      switch (typeName) {
        case 'User':
          restored = User.fromMap(recordData);
          break;
        case 'Comment':
          restored = Comment.fromMap(recordData);
          break;
        case 'Storage':
          restored = Storage.fromMap(recordData);
          break;
        default:
          return APIResponse.badRequest(
              message: 'Unknown restorable type: $typeName');
      }

      await restored.insert();

      return APIResponse.success(data: {'uuid': restored.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-record restore, indirect variant: the reflective class lookup and
    /// construction both happen in [SystemHandler.restoreBackupRecord] rather than in this
    /// route handler. See that method's doc comment.
    router.postRoute('/maintenance/restore-backup-record-indirect',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      final restored =
          await SystemHandler.restoreBackupRecord(typeName, recordData);

      return APIResponse.success(data: {'uuid': restored?.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same indirect restore, safe variant.
    router.postRoute('/maintenance/restore-backup-record-indirect-safe',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      final restored =
          await SystemHandler.restoreBackupRecordSafe(typeName, recordData);

      return APIResponse.success(data: {'uuid': restored?.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-record restore, interprocedural variant: routed through
    /// [SystemHandler.restoreBackupRecordViaService] into [BackupRestoreService], which
    /// resolves the class via the shared [ClassResolver] helper -- a further hop past
    /// [SystemHandler.restoreBackupRecord]'s own, separately-resolved indirect path.
    router.postRoute('/maintenance/restore-backup-record-service',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      final restored = await SystemHandler.restoreBackupRecordViaService(
          typeName, recordData);

      return APIResponse.success(data: {'uuid': restored?.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same interprocedural restore, safe variant.
    router.postRoute('/maintenance/restore-backup-record-service-safe',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      final restored = await SystemHandler.restoreBackupRecordViaServiceSafe(
          typeName, recordData);

      return APIResponse.success(data: {'uuid': restored?.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-record restore, type/polymorphism-dependent variant: which concrete
    /// [BackupRestoreStrategy] actually runs is resolved from the
    /// `X-RPMTW-Restore-Backend` header -- exploitability depends entirely on which
    /// implementation the caller triggers. Mirrors this project's own
    /// `/user/login/ldap-strategy` and `/maintenance/run-scored-rule` header-driven backend
    /// selection.
    router.postRoute('/maintenance/restore-backup-record-backend',
        (req, data) async {
      final String typeName = data.fields['type']!;
      final Map<String, dynamic> recordData =
          Map<String, dynamic>.from(data.fields['data'] as Map? ?? {});

      final restored = await SystemHandler.restoreBackupRecordViaBackend(
          typeName, recordData, req.headers['x-rpmtw-restore-backend']);

      return APIResponse.success(data: {'uuid': restored?.uuid});
    },
        requiredFields: ['type', 'data'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Restores every `{type, data}` entry in [recordList] as a single backup-snapshot
    /// replay -- e.g. an admin replaying a whole exported backup at once instead of one
    /// record at a time. Distinct construction shape from every other restore route above:
    /// dispatches through [BackupRestoreRegistry], an open registry auto-populated at first
    /// use by walking this project's own classes for a `fromMap` factory constructor, rather
    /// than a hand-curated allow-list. See [SystemHandler.restoreBackupRecordsBatch].
    router.postRoute('/maintenance/restore-backup-records-batch',
        (req, data) async {
      final List<dynamic> recordList = data.fields['records']!;

      final List<dynamic> restored =
          await SystemHandler.restoreBackupRecordsBatch(recordList);

      return APIResponse.success(data: {'count': restored.length});
    },
        requiredFields: ['records'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same batch restore, safe variant: every entry's `type` is checked against
    /// [kAllowedBackupRecordTypes] before any lookup in the auto-populated registry.
    router.postRoute('/maintenance/restore-backup-records-batch-safe',
        (req, data) async {
      final List<dynamic> recordList = data.fields['records']!;

      final List<dynamic> restored =
          await SystemHandler.restoreBackupRecordsBatchSafe(recordList);

      return APIResponse.success(data: {'count': restored.length});
    },
        requiredFields: ['records'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Reads a single diagnostic field named [fieldName] off the [ModerationCase] built for
    /// [messageUuid] -- e.g. an admin spot-checking one diagnostic field without pulling a
    /// whole batch. See [SystemHandler.dumpDiagnosticFieldsBatch] for the multi-message/
    /// multi-field batch form of the same idea. Direct construction shape: the reflective
    /// lookup happens right here, with no intermediate helper.
    router.postRoute('/diagnostics/dump-field', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String fieldName = data.fields['fieldName']!;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) {
        return APIResponse.badRequest(message: 'Message not found');
      }

      final ModerationCase moderationCase =
          ModerationCase.forMessage(chatMessage);
      final InstanceMirror mirror = reflect(moderationCase);
      final LibraryMirror ownerLibrary = mirror.type.owner as LibraryMirror;
      final Symbol fieldSymbol =
          MirrorSystem.getSymbol(fieldName, ownerLibrary);

      // SINK: PLANTED-Dart-HR-320
      final dynamic value = mirror.getField(fieldSymbol).reflectee;

      return APIResponse.success(data: {'value': value.toString()});
    },
        requiredFields: ['messageUuid', 'fieldName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-field dump, safe variant: [fieldName] is checked against
    /// [ModerationCase.publicSummary]'s own key set before it is ever read --
    /// `dart:mirrors` is never touched.
    router.postRoute('/diagnostics/dump-field-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String fieldName = data.fields['fieldName']!;

      final UniverseChatMessage? chatMessage =
          await UniverseChatMessage.getByUUID(messageUuid);
      if (chatMessage == null) {
        return APIResponse.badRequest(message: 'Message not found');
      }

      final ModerationCase moderationCase =
          ModerationCase.forMessage(chatMessage);
      final Map<String, dynamic> summary = moderationCase.publicSummary();
      if (!summary.containsKey(fieldName)) {
        return APIResponse.badRequest(message: 'Unknown diagnostic field');
      }

      // SAFE_SINK: PLANTED-Dart-HR-320-safe
      final dynamic value = summary[fieldName];

      return APIResponse.success(data: {'value': value.toString()});
    },
        requiredFields: ['messageUuid', 'fieldName'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Overwrites a single named diagnostic field on the [ModerationCase] built for
    /// [messageUuid] -- see [SystemHandler.patchDiagnosticField] for the cross-file
    /// reflective write this delegates to.
    router.postRoute('/diagnostics/patch-field', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String fieldName = data.fields['fieldName']!;
      final String value = data.fields['value']!;

      final Map<String, dynamic> result = await SystemHandler
          .patchDiagnosticField(messageUuid, fieldName, value);

      return APIResponse.success(data: result);
    },
        requiredFields: ['messageUuid', 'fieldName', 'value'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same single-field patch, safe variant.
    router.postRoute('/diagnostics/patch-field-safe', (req, data) async {
      final String messageUuid = data.fields['messageUuid']!;
      final String fieldName = data.fields['fieldName']!;
      final String value = data.fields['value']!;

      final Map<String, dynamic> result = await SystemHandler
          .patchDiagnosticFieldSafe(messageUuid, fieldName, value);

      return APIResponse.success(data: result);
    },
        requiredFields: ['messageUuid', 'fieldName', 'value'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Reads several named diagnostic fields across several flagged messages in one call --
    /// e.g. an admin pulling several internal diagnostic fields across a whole batch of
    /// flagged messages at once. See [SystemHandler.dumpDiagnosticFieldsBatch].
    router.postRoute('/diagnostics/dump-fields-batch', (req, data) async {
      final List<dynamic> requests = data.fields['requests']!;

      final Map<String, Map<String, dynamic>> result =
          await SystemHandler.dumpDiagnosticFieldsBatch(
              requests.cast<Map<String, dynamic>>());

      return APIResponse.success(data: result);
    },
        requiredFields: ['requests'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same batch field dump, safe variant.
    router.postRoute('/diagnostics/dump-fields-batch-safe', (req, data) async {
      final List<dynamic> requests = data.fields['requests']!;

      final Map<String, Map<String, dynamic>> result =
          await SystemHandler.dumpDiagnosticFieldsBatchSafe(
              requests.cast<Map<String, dynamic>>());

      return APIResponse.success(data: result);
    },
        requiredFields: ['requests'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Kills this server process outright so the process supervisor (systemd/pm2) restarts
    /// it clean -- used for cases a graceful in-process restart can't reach (e.g. a wedged
    /// event loop). See [SystemHandler.restartNode].
    router.postRoute('/system/restart-node', (req, data) async {
      final String reason = data.fields['reason']!;

      SystemHandler.restartNode(reason);

      return APIResponse.success(data: null);
    }, requiredFields: ['reason'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same node restart, safe variant.
    router.postRoute('/system/restart-node-safe', (req, data) async {
      final String reason = data.fields['reason']!;

      SystemHandler.restartNodeSafe(reason);

      return APIResponse.success(data: null);
    }, requiredFields: ['reason'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Tears down this server process based on the `X-RPMTW-Lifecycle-Backend` header a
    /// caller may send -- a still-deployed legacy ops runbook always expects the process to
    /// exit immediately, so every other caller gets the current, safe strategy by default.
    /// See [SystemHandler.shutdownViaBackend].
    router.postRoute('/system/shutdown', (req, data) async {
      final String reason = data.fields['reason']!;

      await SystemHandler.shutdownViaBackend(
          reason, req.headers['x-rpmtw-lifecycle-backend']);

      return APIResponse.success(data: null);
    }, requiredFields: ['reason'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same backend-dispatched shutdown, safe variant: never honors the
    /// `X-RPMTW-Lifecycle-Backend` header.
    router.postRoute('/system/shutdown-safe', (req, data) async {
      final String reason = data.fields['reason']!;

      await SystemHandler.shutdownViaBackendSafe(reason);

      return APIResponse.success(data: null);
    }, requiredFields: ['reason'], authConfig: AuthConfig(role: UserRoleType.admin));

    /// Mirrors a federation partner's public wiki repo by cloning [partnerRepoUrl] straight
    /// from the request -- lets an admin pull a fresh local copy of a partner instance's wiki
    /// content (e.g. before a scheduled RPMWiki content merge) without shelling into the host
    /// directly. Direct construction shape: the clone runs right here in the route handler,
    /// with no intermediate helper.
    router.postRoute('/federation/mirror-wiki', (req, data) async {
      final String partnerRepoUrl = data.fields['partnerRepoUrl']!;
      final String mirrorTag = data.fields['mirrorTag']!;

      final String destDir = 'mirrors/wiki-$mirrorTag';

      final ProcessResult result =
          // SINK: PLANTED-Dart-HR-665
          await Process.run(
              'git', ['clone', '--depth', '1', partnerRepoUrl, destDir]);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'destDir': destDir,
      });
    },
        requiredFields: ['partnerRepoUrl', 'mirrorTag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same wiki mirror, safe variant: [partnerRepoUrl] must be a well-formed `https://` URL
    /// with no leading-dash scheme/host trickery before it is ever placed on `git`'s argv --
    /// rejects exactly the `ssh://-oProxyCommand=...` shape that lets a crafted URL smuggle an
    /// ssh option into git's own argument parser (the mechanism behind CVE-2017-1000117), and
    /// forcing `https://` also keeps git off the ssh transport entirely.
    router.postRoute('/federation/mirror-wiki-safe', (req, data) async {
      final String partnerRepoUrl = data.fields['partnerRepoUrl']!;
      final String mirrorTag = data.fields['mirrorTag']!;

      final RegExp safeUrl =
          RegExp(r'^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$');
      if (!safeUrl.hasMatch(partnerRepoUrl)) {
        return APIResponse.badRequest(
            message: 'Invalid partner repository URL');
      }
      final RegExp safeTag = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
      if (!safeTag.hasMatch(mirrorTag)) {
        return APIResponse.badRequest(message: 'Invalid mirror tag');
      }

      final String destDir = 'mirrors/wiki-$mirrorTag';

      final ProcessResult result =
          // SAFE_SINK: PLANTED-Dart-HR-665-safe
          await Process.run(
              'git', ['clone', '--depth', '1', partnerRepoUrl, destDir]);

      return APIResponse.success(data: {
        'exitCode': result.exitCode,
        'destDir': destDir,
      });
    },
        requiredFields: ['partnerRepoUrl', 'mirrorTag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Pushes the current on-disk backup snapshot out to [partnerDestSpec] (a full
    /// `host-or-ip:/remote/path` rsync destination spec supplied by an admin) so a federation
    /// partner instance always has an up-to-date off-site copy. See
    /// [SystemHandler.mirrorBackupToPartner] for where the actual `rsync` invocation happens.
    router.postRoute('/federation/mirror-backup', (req, data) async {
      final String partnerDestSpec = data.fields['partnerDestSpec']!;
      final String tag = data.fields['tag']!;

      final ProcessResult result =
          await SystemHandler.mirrorBackupToPartner(partnerDestSpec, tag);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerDestSpec', 'tag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same backup mirror, safe variant.
    router.postRoute('/federation/mirror-backup-safe', (req, data) async {
      final String partnerDestSpec = data.fields['partnerDestSpec']!;
      final String tag = data.fields['tag']!;

      final ProcessResult result =
          await SystemHandler.mirrorBackupToPartnerSafe(partnerDestSpec, tag);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerDestSpec', 'tag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Checks a federation partner's declared CurseForge-mirror status endpoint
    /// ([partnerStatusUrl]) alongside RPMTW's own canonical directory reference, so an admin
    /// can diff the two. See [SystemHandler.checkPartnerCurseforgeMirror] for the further hop
    /// into [FederationMirrorService], which is where the actual `curl` invocation happens.
    router.postRoute('/federation/check-mirror', (req, data) async {
      final String partnerStatusUrl = data.fields['partnerStatusUrl']!;

      final ProcessResult result =
          await SystemHandler.checkPartnerCurseforgeMirror(partnerStatusUrl);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerStatusUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same mirror check, safe variant.
    router.postRoute('/federation/check-mirror-safe', (req, data) async {
      final String partnerStatusUrl = data.fields['partnerStatusUrl']!;

      final ProcessResult result = await SystemHandler
          .checkPartnerCurseforgeMirrorSafe(partnerStatusUrl);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerStatusUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Refreshes the locally-cached CurseForge mirror manifest from a federation partner's
    /// declared manifest endpoint ([partnerManifestUrl]). See
    /// [SystemHandler.refreshPartnerMirrorManifest] for the deeper hop through
    /// [FederationMirrorService] and [MirrorFetch], which is where the actual `wget`
    /// invocation happens.
    router.postRoute('/federation/refresh-mirror-manifest', (req, data) async {
      final String partnerManifestUrl = data.fields['partnerManifestUrl']!;

      final ProcessResult result = await SystemHandler
          .refreshPartnerMirrorManifest(partnerManifestUrl);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerManifestUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same manifest refresh, safe variant.
    router.postRoute('/federation/refresh-mirror-manifest-safe',
        (req, data) async {
      final String partnerManifestUrl = data.fields['partnerManifestUrl']!;

      final ProcessResult result = await SystemHandler
          .refreshPartnerMirrorManifestSafe(partnerManifestUrl);

      return APIResponse.success(data: {'exitCode': result.exitCode});
    },
        requiredFields: ['partnerManifestUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Syncs wiki content from [partnerRepoUrl] into the local mirror ref [localTag], via
    /// whichever [FederationSyncStrategy] the `X-RPMTW-Sync-Backend` header resolves to -- see
    /// `utilities/federation_sync_strategy.dart`. Only the still-deployed legacy
    /// `legacy-git-fetch` backend actually shells out (see [GitFetchSyncStrategy]); every other
    /// value falls back to the current, safe manifest-only strategy. Mirrors this project's
    /// own `/maintenance/run-scored-rule` and `/system/shutdown` header-driven backend
    /// selection.
    router.postRoute('/federation/sync-wiki-content', (req, data) async {
      final String partnerRepoUrl = data.fields['partnerRepoUrl']!;
      final String localTag = data.fields['localTag']!;

      await SystemHandler.syncWikiContentViaBackend(partnerRepoUrl, localTag,
          req.headers['x-rpmtw-sync-backend']);

      return APIResponse.success(data: null);
    },
        requiredFields: ['partnerRepoUrl', 'localTag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same header-dispatched wiki-content sync, safe variant: never honors the
    /// `X-RPMTW-Sync-Backend` header.
    router.postRoute('/federation/sync-wiki-content-safe', (req, data) async {
      final String partnerRepoUrl = data.fields['partnerRepoUrl']!;
      final String localTag = data.fields['localTag']!;

      await SystemHandler.syncWikiContentViaBackendSafe(
          partnerRepoUrl, localTag);

      return APIResponse.success(data: null);
    },
        requiredFields: ['partnerRepoUrl', 'localTag'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Reports this node's own admin API token to the federation status registry as a
    /// heartbeat, so partner nodes recognize this instance as authenticated and currently
    /// active. See [FederationMirrorService.registerNodeWithRegistry].
    router.postRoute('/federation/register-node', (req, data) async {
      final String adminApiToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await FederationMirrorService.registerNodeWithRegistry(adminApiToken);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same registry heartbeat, safe variant.
    router.postRoute('/federation/register-node-safe', (req, data) async {
      final String adminApiToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await FederationMirrorService.registerNodeWithRegistrySafe(
          adminApiToken);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Broadcasts this node's own admin API token to every configured federation partner
    /// (see `kFederationPartnerBroadcastHosts`), so each one refreshes its record of this
    /// node's membership. See [FederationPartnerBroadcastRegistry].
    router.postRoute('/federation/broadcast-membership', (req, data) async {
      final String adminApiToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await FederationPartnerBroadcastRegistry(adminApiToken).broadcast();

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same membership broadcast, safe variant.
    router.postRoute('/federation/broadcast-membership-safe', (req, data) async {
      final String adminApiToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await FederationPartnerBroadcastRegistrySafe(adminApiToken).broadcast();

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Lets a federation partner node prove its own membership by presenting a
    /// registry-issued membership-assertion token, so this instance can attribute a later
    /// federation action (a mirror sync, a broadcast reply) to a real, currently-recognized
    /// partner rather than an arbitrary caller. No `AuthConfig` -- the presented token is
    /// itself the only credential a partner node has, since it isn't one of this project's
    /// own end users. See [FederationMirrorService.verifyNodeMembershipToken].
    router.postRoute('/federation/verify-node-membership', (req, data) async {
      final String token = data.fields['token'];
      final String? nodeId =
          FederationMirrorService.verifyNodeMembershipToken(token);

      if (nodeId == null) {
        return APIResponse.unauthorized(message: 'Invalid membership token');
      }

      return APIResponse.success(data: {'nodeId': nodeId});
    }, requiredFields: ['token']);

    /// Configured download-mirror partner calling back to acknowledge it has picked up a
    /// download token issued via `/storage/<uuid>/issue-download-token` (see
    /// [FederationMirrorService.reportDownloadTokenIssued]). Which
    /// [WebhookSignatureVerifier] the callback is checked against is resolved from the
    /// caller-sent `X-RPMTW-Mirror-Provider` header, since the still-deployed older mirror
    /// integration predates this project's move to real HMAC-signed callbacks. See
    /// [resolveWebhookVerifier].
    router.post('/federation/mirror-partner-callback', (Request req) async {
      final String rawBody = await req.readAsString();
      final String? provider = req.headers['x-rpmtw-mirror-provider'];
      final String? presentedSignature =
          req.headers['x-rpmtw-mirror-signature'];

      final WebhookSignatureVerifier verifier =
          resolveWebhookVerifier(provider);

      if (!verifier.isValid(rawBody, presentedSignature)) {
        return APIResponse.unauthorized(
            message: 'Invalid mirror callback signature');
      }

      final Map<String, dynamic> payload = json.decode(rawBody);
      _acknowledgedMirrorCallbacks[payload['storageUuid'].toString()] =
          payload;

      return Response.ok(json.encode({'acknowledged': true}),
          headers: {'content-type': 'application/json'});
    });

    /// Same mirror-partner callback, safe variant: always checked against the real
    /// HMAC-verifying implementation, regardless of any `X-RPMTW-Mirror-Provider` header the
    /// caller sends.
    router.post('/federation/mirror-partner-callback-safe', (Request req) async {
      final String rawBody = await req.readAsString();
      final String? presentedSignature =
          req.headers['x-rpmtw-mirror-signature'];

      final WebhookSignatureVerifier verifier = resolveWebhookVerifier(null);

      if (!verifier.isValid(rawBody, presentedSignature)) {
        return APIResponse.unauthorized(
            message: 'Invalid mirror callback signature');
      }

      final Map<String, dynamic> payload = json.decode(rawBody);
      _acknowledgedMirrorCallbacks[payload['storageUuid'].toString()] =
          payload;

      return Response.ok(json.encode({'acknowledged': true}),
          headers: {'content-type': 'application/json'});
    });

    /// Same node-membership verification, safe variant.
    router.postRoute('/federation/verify-node-membership-safe',
        (req, data) async {
      final String token = data.fields['token'];
      final String? nodeId =
          FederationMirrorService.verifyNodeMembershipTokenSafe(token);

      if (nodeId == null) {
        return APIResponse.unauthorized(message: 'Invalid membership token');
      }

      return APIResponse.success(data: {'nodeId': nodeId});
    }, requiredFields: ['token']);

    /// Reports this admin's own live session/bearer token to the security-audit collector,
    /// based on the `X-RPMTW-Audit-Backend` header a caller may send -- a still-deployed
    /// legacy audit dashboard was never migrated off its original plain-HTTP ingest
    /// endpoint, so every other value falls back to the current, safe backend. See
    /// [SystemHandler.reportSessionAuditViaBackend].
    router.postRoute('/system/report-session-audit', (req, data) async {
      final String sessionToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await SystemHandler.reportSessionAuditViaBackend(
          sessionToken, req.headers['x-rpmtw-audit-backend']);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same session-audit report, safe variant: never honors the `X-RPMTW-Audit-Backend`
    /// header.
    router.postRoute('/system/report-session-audit-safe', (req, data) async {
      final String sessionToken =
          req.headers['Authorization']?.toString().replaceAll('Bearer ', '') ??
              '';

      await SystemHandler.reportSessionAuditViaBackendSafe(sessionToken);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Lets support quickly grant an account the admin role to unstick a moderation case,
    /// without going through the full admin console -- predates this file's `AuthConfig`-gated
    /// routes above, so it was never migrated onto the standard role check and instead grew its
    /// own ad-hoc header check. See [SystemHandler.applySupportDebugOverride].
    router.postRoute('/debug/support-override', (req, data) async {
      final String targetUuid = data.fields['targetUuid']!;
      final String? debugHeader = req.headers['x-rpmtw-support-debug'];

      final bool applied = await SystemHandler.applySupportDebugOverride(
          debugHeader, targetUuid);

      if (!applied) {
        return APIResponse.unauthorized();
      }

      return APIResponse.success(data: null);
    }, requiredFields: ['targetUuid']);

    /// Same support override, safe variant: requires a real admin session instead of the
    /// legacy header.
    router.postRoute('/debug/support-override-safe', (req, data) async {
      final String targetUuid = data.fields['targetUuid']!;

      await SystemHandler.applySupportDebugOverrideSafe(targetUuid);

      return APIResponse.success(data: null);
    },
        requiredFields: ['targetUuid'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Confirms the process is up and reports basic health -- meant to be hit by a load
    /// balancer/uptime monitor, so (like most health-check endpoints) it was never put behind
    /// the `AuthConfig` role gate used everywhere else in this file. See
    /// [SystemHandler.runSelfTest].
    router.getRoute('/debug/self-test', (req, data) async {
      return APIResponse.success(data: await SystemHandler.runSelfTest());
    });

    /// Same self-test, safe variant.
    router.getRoute('/debug/self-test-safe', (req, data) async {
      return APIResponse.success(data: await SystemHandler.runSelfTestSafe());
    });

    /// Lets the QA automation harness fast-forward past email verification when seeding test
    /// accounts, for every uuid it lists -- see [SystemHandler.autoVerifyEmails].
    router.postRoute('/debug/auto-verify-emails', (req, data) async {
      final List<String> targetUuids =
          List<String>.from(data.fields['targetUuids'] ?? []);
      final String? qaMode = data.fields['qaMode'];

      final int verifiedCount =
          await SystemHandler.autoVerifyEmails(targetUuids, qaMode);

      return APIResponse.success(data: {'verifiedCount': verifiedCount});
    }, requiredFields: ['targetUuids']);

    /// Same auto-verify sweep, safe variant.
    router.postRoute('/debug/auto-verify-emails-safe', (req, data) async {
      final List<String> targetUuids =
          List<String>.from(data.fields['targetUuids'] ?? []);

      final int verifiedCount =
          await SystemHandler.autoVerifyEmailsSafe(targetUuids);

      return APIResponse.success(data: {'verifiedCount': verifiedCount});
    }, requiredFields: ['targetUuids']);
  }
}
