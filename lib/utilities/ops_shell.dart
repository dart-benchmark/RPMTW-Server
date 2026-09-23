import 'dart:io';

/// Shared helper for admin/maintenance features that need to shell out to a short-lived,
/// fire-and-forget system command (log rotation, ad-hoc housekeeping) rather than manage a
/// long-running process of their own. Centralizing the actual [Process.run] call here keeps
/// every call site's command construction visible for review in one place, rather than
/// scattered across whichever route happens to need a shell-out.
class OpsShell {
  /// Builds the log-archive pipeline for [label] (an admin-supplied tag identifying this
  /// archive run, e.g. "nightly" or "pre-deploy") and runs it through the system shell so the
  /// `gzip`-then-redirect sequence can be expressed as a single command line, then returns the
  /// raw result for [SystemHandler.archiveServerLogs] to report back to the caller.
  static Future<ProcessResult> buildAndRunArchiveCommand(String label) async {
    final List<String> parts = [
      'gzip',
      '-c',
      'server.log',
      '>',
      'archive/$label.log.gz'
    ];
    final String command = parts.join(' ');

    // SINK: PLANTED-Dart-HR-252
    return Process.run('sh', ['-c', command]);
  }

  /// Same log archive, safe variant: [label] is restricted to a small, filesystem-safe
  /// character set before it ever reaches a command line, and the shell is removed from the
  /// pipeline entirely -- `gzip` is invoked directly to compress the log bytes, and the
  /// compressed output is written to disk by Dart itself instead of relying on shell `>`
  /// redirection to interpret [label].
  static Future<void> buildAndRunArchiveCommandSafe(String label) async {
    final RegExp safeLabel = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
    if (!safeLabel.hasMatch(label)) {
      throw ArgumentError('Invalid archive label');
    }

    // SAFE_SINK: PLANTED-Dart-HR-252-safe
    final ProcessResult result =
        await Process.run('gzip', ['-c', 'server.log'], stdoutEncoding: null);

    final File archiveFile = File('archive/$label.log.gz');
    await archiveFile.create(recursive: true);
    await archiveFile.writeAsBytes(result.stdout as List<int>);
  }
}
