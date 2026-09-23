import 'dart:mirrors';

import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';
import 'package:rpmtw_server/utilities/chat_heuristic_rules.dart';
import 'package:rpmtw_server/utilities/data.dart';

/// Cross-file evaluation layer sitting between [SystemHandler]'s admin-facing maintenance
/// routes and the actual [ChatHeuristicRules] methods a named rule resolves to -- kept
/// separate from [SystemHandler] so the audit-trail bookkeeping below is shared regardless of
/// which route triggered the evaluation, and so a single rule name can be resolved either one
/// at a time ([evaluate]) or as part of a whole moderation-profile batch ([evaluateBatch]).
class HeuristicRuleRepository {
  /// Evaluates the single rule named [ruleName] against [chatMessage]. See [SystemHandler]'s
  /// `/maintenance/run-audit-rule`.
  static Future<dynamic> evaluate(
      UniverseChatMessage chatMessage, String ruleName) async {
    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);

    // SINK: PLANTED-Dart-HR-272
    final Symbol ruleSymbol = MirrorSystem.getSymbol(ruleName);
    final dynamic result = mirror.invoke(ruleSymbol, []).reflectee;
    _recordAudit(chatMessage.uuid, ruleName);
    return result;
  }

  /// Same single-rule evaluation, safe variant: [ruleName] is checked against
  /// [kAllowedHeuristicRuleNames] before it is ever turned into a [Symbol].
  static Future<dynamic> evaluateSafe(
      UniverseChatMessage chatMessage, String ruleName) async {
    if (!kAllowedHeuristicRuleNames.contains(ruleName)) {
      throw ArgumentError('Unknown heuristic rule: $ruleName');
    }

    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);

    // SAFE_SINK: PLANTED-Dart-HR-272-safe
    final Symbol ruleSymbol = MirrorSystem.getSymbol(ruleName);
    final dynamic result = mirror.invoke(ruleSymbol, []).reflectee;
    _recordAudit(chatMessage.uuid, ruleName);
    return result;
  }

  /// Evaluates every rule name in [ruleNames] against [chatMessage] in turn -- e.g. an admin
  /// running a whole "moderation profile" of rules at once instead of one at a time. See
  /// [SystemHandler]'s `/maintenance/run-rule-batch`.
  static Future<Map<String, dynamic>> evaluateBatch(
      UniverseChatMessage chatMessage, List<dynamic> ruleNames) async {
    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);
    final Map<String, dynamic> results = {};

    for (final dynamic ruleNameDynamic in ruleNames) {
      final String ruleName = ruleNameDynamic.toString();

      // SINK: PLANTED-Dart-HR-274
      results[ruleName] = mirror.invoke(Symbol(ruleName), []).reflectee;
    }
    _recordAudit(chatMessage.uuid, ruleNames.join(','));
    return results;
  }

  /// Same batch evaluation, safe variant: every name in [ruleNames] is checked against
  /// [kAllowedHeuristicRuleNames] before it is turned into a [Symbol] -- an unlisted name
  /// anywhere in the batch aborts the whole run rather than silently skipping just that one.
  static Future<Map<String, dynamic>> evaluateBatchSafe(
      UniverseChatMessage chatMessage, List<dynamic> ruleNames) async {
    final ChatHeuristicRules rules = ChatHeuristicRules(chatMessage);
    final InstanceMirror mirror = reflect(rules);
    final Map<String, dynamic> results = {};

    for (final dynamic ruleNameDynamic in ruleNames) {
      final String ruleName = ruleNameDynamic.toString();
      if (!kAllowedHeuristicRuleNames.contains(ruleName)) {
        throw ArgumentError('Unknown heuristic rule: $ruleName');
      }

      // SAFE_SINK: PLANTED-Dart-HR-274-safe
      results[ruleName] = mirror.invoke(Symbol(ruleName), []).reflectee;
    }
    _recordAudit(chatMessage.uuid, ruleNames.join(','));
    return results;
  }

  static void _recordAudit(String chatMessageUuid, String ruleNames) {
    logger.i('Heuristic rule(s) "$ruleNames" evaluated against message $chatMessageUuid');
  }
}
