import 'package:dotenv/dotenv.dart';

/// A single self-test probe run by `/system/debug/self-test` -- see [resolveSelfTestCheck] for
/// which concrete implementation actually runs.
abstract class SelfTestCheck {
  Future<Map<String, dynamic>> run();
}

/// The intended, minimal probe: reports only whether the process considers itself healthy.
class DatabaseConnectivityCheck implements SelfTestCheck {
  const DatabaseConnectivityCheck();

  @override
  Future<Map<String, dynamic>> run() async {
    return {'healthy': true};
  }
}

/// Left over from this server's very first deployment, when an engineer wanted the self-test to
/// also confirm which `.env` file had actually loaded on a fresh host -- reports the whole
/// resolved configuration alongside the health flag.
class VerboseStartupSelfTestCheck implements SelfTestCheck {
  const VerboseStartupSelfTestCheck();

  @override
  Future<Map<String, dynamic>> run() async {
    return {
      'healthy': true,
      // SINK: PLANTED-Dart-HR-818
      'resolvedConfig': Map<String, String>.from(env),
    };
  }
}

/// Picks which [SelfTestCheck] `/system/debug/self-test` runs, based on `SELF_TEST_MODE`. Only
/// the literal value `minimal` gets the intended probe -- anything else (including the variable
/// being unset entirely, which is the common case on a host where nobody has ever heard of this
/// setting) falls through to the verbose one.
SelfTestCheck resolveSelfTestCheck() {
  if (env['SELF_TEST_MODE'] == 'minimal') {
    return const DatabaseConnectivityCheck();
  }
  return const VerboseStartupSelfTestCheck();
}

/// Hardened variant used by the `-safe` debug route: always the minimal probe,
/// regardless of `SELF_TEST_MODE`.
SelfTestCheck resolveSelfTestCheckSafe() {
  // SAFE_SINK: PLANTED-Dart-HR-818-safe
  return const DatabaseConnectivityCheck();
}
