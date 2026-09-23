import 'dart:mirrors';

import 'package:rpmtw_server/utilities/chat_heuristic_rules.dart';

/// Resolves how a `/maintenance/run-scored-rule` request runs an admin-named heuristic rule
/// against a [ChatHeuristicRules] target. Two implementations exist because a still-deployed
/// legacy admin dashboard (predating this project's move to a closed rule menu) always sent
/// rule names in PascalCase ("FlagsBareUrl") and expected them resolved dynamically, and
/// cannot be repointed at the newer dashboard without a coordinated release -- every other
/// caller gets the current, safe executor by default. Mirrors this project's own
/// [LdapAuthStrategy]/`resolveLdapAuthStrategy` dynamic-backend-selection idiom (see
/// `utilities/ldap_auth_strategy.dart`).
abstract class HeuristicRuleExecutor {
  /// Runs the rule named [ruleName] against [rules] and returns whatever the resolved method
  /// returns.
  Future<dynamic> execute(ChatHeuristicRules rules, String ruleName);
}

/// Legacy admin-dashboard integration, kept only for that dashboard's naming convention --
/// lower-cases just the first character of the caller-supplied PascalCase rule name and
/// reflectively invokes whatever member of [ChatHeuristicRules] the result names.
class LegacyHeuristicRuleExecutor implements HeuristicRuleExecutor {
  @override
  Future<dynamic> execute(ChatHeuristicRules rules, String ruleName) async {
    final InstanceMirror mirror = reflect(rules);
    final String methodName = _lowerFirstChar(ruleName);

    // SINK: PLANTED-Dart-HR-273
    return mirror.invoke(Symbol(methodName), []).reflectee;
  }

  static String _lowerFirstChar(String value) {
    if (value.isEmpty) return value;
    return value[0].toLowerCase() + value.substring(1);
  }
}

/// Current implementation: the rule name is matched against a closed switch ladder mapping
/// straight to a literal [ChatHeuristicRules] method reference -- `dart:mirrors` is never
/// touched, so an unrecognized (or intentionally malicious) rule name has no reflective
/// invocation surface to reach at all.
class ModernHeuristicRuleExecutor implements HeuristicRuleExecutor {
  @override
  Future<dynamic> execute(ChatHeuristicRules rules, String ruleName) async {
    // SAFE_SINK: PLANTED-Dart-HR-273-safe
    switch (ruleName) {
      case 'FlagsBareUrl':
      case 'flagsBareUrl':
        return rules.flagsBareUrl();
      case 'FlagsRepeatedCharacterSpam':
      case 'flagsRepeatedCharacterSpam':
        return rules.flagsRepeatedCharacterSpam();
      default:
        throw ArgumentError('Unknown heuristic rule: $ruleName');
    }
  }
}

/// Resolves which executor a given request should use, based on the
/// `X-RPMTW-Heuristic-Backend` header a caller may send.
HeuristicRuleExecutor resolveHeuristicRuleExecutor(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyHeuristicRuleExecutor();
  }
  return ModernHeuristicRuleExecutor();
}
