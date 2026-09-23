import 'package:rpmtw_server/database/models/universe_chat/universe_chat_message.dart';

/// Internal, server-computed moderation bookkeeping for a single [UniverseChatMessage] --
/// deliberately never round-tripped through any DB model `toMap`/`outputMap`, since
/// [_riskScore] and [_reviewerNotes] are purely a moderation-team-internal signal, not
/// something any client (even an authenticated admin's own dashboard) is meant to read back
/// wholesale. Built fresh from the message on every diagnostic request -- nothing here is
/// persisted. See `routes/system_route.dart`'s `/diagnostics/*` admin routes for the only
/// intended entry points into a [ModerationCase]'s internals.
class ModerationCase {
  final UniverseChatMessage message;

  /// Server-computed abuse-risk heuristic, 0.0-1.0. Internal-only: informs which moderator
  /// queue a message lands in, never surfaced to any admin-facing summary. Only ever read
  /// via dart:mirrors reflection (see PLANTED-Dart-HR-320/324) -- the static analyzer cannot
  /// see that access, hence the ignore below.
  // ignore: unused_field
  final double _riskScore;

  /// Free-text internal annotation a moderator may attach while triaging -- may reference
  /// other open cases or a reporter's identity, so it is never exposed outside the
  /// moderation team's own tooling. The only field of the two that is ever mutated after
  /// construction (via [annotate]), which is why it isn't `final` like [_riskScore].
  String _reviewerNotes;

  ModerationCase._(this.message, this._riskScore, this._reviewerNotes);

  factory ModerationCase.forMessage(UniverseChatMessage message) {
    return ModerationCase._(message, _computeRiskScore(message), '');
  }

  static double _computeRiskScore(UniverseChatMessage message) {
    double score = 0.0;
    if (message.message.contains('http://') ||
        message.message.contains('https://')) {
      score += 0.4;
    }
    if (message.replyMessageUUID == null) score += 0.1;
    return score.clamp(0.0, 1.0);
  }

  /// Records [note] as this case's internal reviewer annotation. The only sanctioned way to
  /// mutate [_reviewerNotes] without reflecting into it directly -- see
  /// `SystemHandler.patchDiagnosticFieldSafe`.
  void annotate(String note) {
    _reviewerNotes = note;
  }

  /// The only fields a diagnostic summary is meant to ever surface -- deliberately excludes
  /// [_riskScore] and [_reviewerNotes]. Keyed without the leading underscore, since these
  /// are the project's own public diagnostic-field names, not [dart:mirrors] member symbols.
  Map<String, dynamic> publicSummary() => {
        'uuid': message.uuid,
        'username': message.username,
        'reviewerNotes': _reviewerNotes,
      };
}
