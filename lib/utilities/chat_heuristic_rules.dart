import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';

/// The full menu of moderation heuristics an admin may run against a single universe-chat
/// message through the `/maintenance/run-*` family of routes in [SystemRoute]. Every route
/// resolves the caller-supplied rule identifier to one of the methods below at runtime --
/// some resolution paths validate the identifier against [kAllowedHeuristicRuleNames] first,
/// others don't (see each route's own doc comment in `routes/system_route.dart` for which is
/// which). New heuristics are added here as plain, single-argument-free methods.
class ChatHeuristicRules {
  final UniverseChatMessage chatMessage;

  const ChatHeuristicRules(this.chatMessage);

  /// Flags [chatMessage] when it contains a bare, unshortened URL -- a mild signal an admin
  /// can act on without also enabling this project's full [ScamDetection] domain matching.
  bool flagsBareUrl() =>
      chatMessage.message.contains('http://') ||
      chatMessage.message.contains('https://');

  /// Flags [chatMessage] when a single character makes up more than half its length -- a
  /// common raid/spam pattern ("aaaaaaaaaaaaaaaaaa").
  bool flagsRepeatedCharacterSpam() {
    if (chatMessage.message.isEmpty) return false;

    final Map<String, int> charCounts = {};
    for (final String char in chatMessage.message.split('')) {
      charCounts[char] = (charCounts[char] ?? 0) + 1;
    }
    final int mostCommonCount = charCounts.values.reduce((a, b) => a > b ? a : b);

    return mostCommonCount > chatMessage.message.length / 2;
  }

  /// Permanently deletes [chatMessage]. Reserved for content a moderator has already
  /// confirmed is malicious through the ordinary moderation-search flow
  /// ([UniverseChatMessage.search]) -- this is a terminal moderation *action*, not a
  /// heuristic *check*, and must never be reachable by an admin merely naming it in a rule
  /// field. Deliberately excluded from [kAllowedHeuristicRuleNames].
  Future<void> purgeMessage() => chatMessage.delete();

  /// Prefixed aliases kept for the older `/maintenance/run-chat-rule` admin-CLI naming
  /// convention (see [SystemHandler.runChatHeuristicRule]), which has always namespaced rule
  /// identifiers with a `rule_` prefix. Delegate straight through to the methods above.
  bool rule_flagsBareUrl() => flagsBareUrl();
  bool rule_flagsRepeatedCharacterSpam() => flagsRepeatedCharacterSpam();
  Future<void> rule_purgeMessage() => purgeMessage();
}

/// The closed set of heuristic rule identifiers safe to resolve from caller input --
/// deliberately excludes `purgeMessage` (see its doc comment above). Checked by every
/// `/maintenance/run-*-safe` route (and the safe [HeuristicRuleExecutor] backend) before the
/// identifier is ever turned into a `Symbol`.
const Set<String> kAllowedHeuristicRuleNames = {
  'flagsBareUrl',
  'flagsRepeatedCharacterSpam',
};
