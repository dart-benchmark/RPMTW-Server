import 'package:mustache_template/mustache_template.dart';

/// Resolves how the `/user/verification-reminder` email's greeting line is rendered, based on
/// the `X-RPMTW-Greeting-Backend` header a caller may send. Two implementations exist because a
/// still-deployed legacy client integration expects the greeting to be assembled the original
/// (pre-templating-library) way -- every other caller gets the current, safe renderer by
/// default. Mirrors this project's own [LifecycleStrategy]/`resolveLifecycleStrategy` and
/// [LdapAuthStrategy]/`resolveLdapAuthStrategy` dynamic-backend-selection idiom.
abstract class EmailGreetingRenderer {
  String renderGreeting(
    String customGreeting,
    Map<String, dynamic> internalContext,
  );
}

/// Legacy integration, kept only for that integration's own expected wording -- splices
/// [customGreeting] directly into the compiled template source.
class LegacyGreetingRenderer implements EmailGreetingRenderer {
  @override
  String renderGreeting(
    String customGreeting,
    Map<String, dynamic> internalContext,
  ) {
    final String templateSource =
        'Hi there! $customGreeting<br>Please verify your account: {{code}}';

    // SINK: PLANTED-Dart-HR-328
    final Template template = Template(templateSource, htmlEscapeValues: false);
    return template.renderString({
      'code': internalContext['code'],
      ...internalContext,
    });
  }
}

/// Current implementation: the custom greeting is bound only as a data value against a fixed
/// template source, never re-compiled.
class ModernGreetingRenderer implements EmailGreetingRenderer {
  @override
  String renderGreeting(
    String customGreeting,
    Map<String, dynamic> internalContext,
  ) {
    const String templateSource =
        'Hi there! {{customGreeting}}<br>Please verify your account: {{code}}';

    // SAFE_SINK: PLANTED-Dart-HR-328-safe
    final Template template = Template(templateSource, htmlEscapeValues: false);
    return template.renderString({
      'customGreeting': customGreeting,
      'code': internalContext['code'],
      ...internalContext,
    });
  }
}

EmailGreetingRenderer resolveEmailGreetingRenderer(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyGreetingRenderer();
  }
  return ModernGreetingRenderer();
}
