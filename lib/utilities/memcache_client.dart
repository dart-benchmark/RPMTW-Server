import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// A minimal, hand-rolled client for the classic memcached ASCII text protocol -- no
/// external `memcached_client`/`memcached` package dependency, matching this project's own
/// preference for small, self-contained utilities living under `lib/utilities/` (see
/// [ScamDetection], [Utility]) rather than reaching for a third-party library for a narrow
/// need.
///
/// Implements exactly the wire format documented by the memcached project's own
/// `protocol.txt`: every command is a single line terminated by `\r\n`, a storage command's
/// data block is read by the server for exactly the declared byte count, and a `get` line
/// may carry one or more space-separated keys. The server itself is documented to reject a
/// key containing whitespace or control characters -- this client does **not** re-check
/// that rule before writing the command line, so whatever `String` is passed as `key` is
/// interpolated into the command exactly as given.
///
/// Unlike a long-lived connection pool, this client opens a fresh socket per call and
/// closes it once the command completes. Simpler to reason about, and cheap enough for the
/// read-heavy, latency-tolerant lookups it backs here (glossary/mod/comment caches, none of
/// which sit on a per-message hot path the way Universe Chat's socket_io traffic does).
class MemcacheClient {
  final String host;
  final int port;

  final List<int> _pendingBytes = [];

  MemcacheClient({String? host, int? port})
      : host = host ?? env['MEMCACHE_HOST'] ?? '127.0.0.1',
        port = port ?? int.tryParse(env['MEMCACHE_PORT'] ?? '') ?? 11211;

  /// Sends `get <key>\r\n` and returns the raw value, or `null` on a miss, a malformed
  /// response, or any I/O failure -- a cache tier is always allowed to fail silently rather
  /// than take down the request path that consults it.
  Future<String?> get(String key) async {
    Socket? socket;
    try {
      socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      socket.add(utf8.encode('get $key\r\n'));
      await socket.flush();

      final StringBuffer response = StringBuffer();
      await for (final String chunk in socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .timeout(const Duration(seconds: 1), onTimeout: (sink) => sink.close())) {
        response.write(chunk);
        if (response.toString().contains('END\r\n')) break;
      }

      final String raw = response.toString();
      if (!raw.startsWith('VALUE ')) return null;
      final int headerEnd = raw.indexOf('\r\n');
      if (headerEnd == -1) return null;
      final int dataEnd = raw.indexOf('\r\nEND\r\n', headerEnd);
      if (dataEnd == -1) return null;
      return raw.substring(headerEnd + 2, dataEnd);
    } catch (_) {
      return null;
    } finally {
      await socket?.close();
    }
  }

  /// Sends a `set <key> <flags> <exptime> <bytes>\r\n<data>\r\n` command immediately, per
  /// the storage-command grammar in `protocol.txt`. Best-effort: a failed write is silently
  /// dropped, since a cache write must never block or fail the request that triggered it.
  Future<void> set(String key, String value, {int ttlSeconds = 0}) async {
    Socket? socket;
    try {
      socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      final List<int> dataBytes = utf8.encode(value);
      final String header = 'set $key 0 $ttlSeconds ${dataBytes.length}\r\n';
      socket.add(utf8.encode(header));
      socket.add(dataBytes);
      socket.add(utf8.encode('\r\n'));
      await socket.flush();
    } catch (_) {
      // Best-effort cache write.
    } finally {
      await socket?.close();
    }
  }

  /// Queues a `set` command's bytes for a later batched [flushPending] instead of opening a
  /// connection immediately -- used by a caller iterating a list of values that wants one
  /// shared write at the end rather than one round trip per element.
  void queueSet(String key, String value, {int ttlSeconds = 0}) {
    final List<int> dataBytes = utf8.encode(value);
    final String header = 'set $key 0 $ttlSeconds ${dataBytes.length}\r\n';
    _pendingBytes.addAll(utf8.encode(header));
    _pendingBytes.addAll(dataBytes);
    _pendingBytes.addAll(utf8.encode('\r\n'));
  }

  /// Flushes every command queued via [queueSet] over one connection, then clears the
  /// queue regardless of whether the write succeeded.
  Future<void> flushPending() async {
    if (_pendingBytes.isEmpty) return;
    Socket? socket;
    try {
      socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      socket.add(_pendingBytes);
      await socket.flush();
    } catch (_) {
      // Best-effort batched cache write.
    } finally {
      _pendingBytes.clear();
      await socket?.close();
    }
  }
}
