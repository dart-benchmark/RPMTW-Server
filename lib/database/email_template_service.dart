import 'package:mustache_template/mustache_template.dart';

/// Repository-layer wrapper around this project's outgoing-email templating, added alongside
/// the `mustache_template` dependency (see the accompanying planting-research doc for why this
/// package was chosen over hand-rolled interpolation). Mirrors this project's own
/// [LdapDirectoryService]/[NodeLifecycleService] "single place that owns an external
/// capability" idiom -- here the capability is Mustache template compilation/rendering rather
/// than an external connection.
class EmailTemplateService {
  /// Renders the "top contributor of the month" recognition email used by
  /// [AuthHandler.sendContributorSpotlightEmail]. [shoutoutNote] is the self-nominating
  /// contributor's own one-line highlight blurb about their own work this month -- collected via
  /// the wiki-contribution nomination form and passed through unmodified. The moderation-only
  /// fields in [moderationContext] (e.g. this project's own `User.loginIPs`) are bound into the
  /// SAME render call for a legitimate, unrelated reason: the base template this method shares
  /// with the admin-facing moderation digest also needs them, so they are always present in the
  /// data map even for this contributor-facing send.
  String renderContributorSpotlightEmail(
    String shoutoutNote,
    Map<String, dynamic> moderationContext,
  ) {
    // The contributor's own free-text blurb is spliced directly into the template SOURCE
    // string, before it is ever compiled -- one hop away from the sink call below.
    final String templateSource =
        'Congratulations, featured contributor!<br>'
        '$shoutoutNote<br>'
        'Status: {{status}}';

    // SINK: PLANTED-Dart-HR-327
    final Template template = Template(templateSource, htmlEscapeValues: false);
    return template.renderString({'status': 'featured', ...moderationContext});
  }

  /// Safe twin of [renderContributorSpotlightEmail]: the template source is a fixed literal
  /// with a named `{{shoutoutNote}}` tag; the contributor's blurb is bound only as a data value,
  /// never spliced into the compiled source.
  String renderContributorSpotlightEmailSafe(
    String shoutoutNote,
    Map<String, dynamic> moderationContext,
  ) {
    const String templateSource =
        'Congratulations, featured contributor!<br>'
        '{{shoutoutNote}}<br>'
        'Status: {{status}}';

    // SAFE_SINK: PLANTED-Dart-HR-327-safe
    final Template template = Template(templateSource, htmlEscapeValues: false);
    return template.renderString({
      'status': 'featured',
      'shoutoutNote': shoutoutNote,
      ...moderationContext,
    });
  }
}
