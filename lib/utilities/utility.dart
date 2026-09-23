import 'dart:io';
import 'dart:math';

import 'package:dotenv/dotenv.dart';
import 'package:pub_semver/pub_semver.dart';

class Utility {
  /// Characters a short, human-copyable identifier is drawn from -- excludes visually
  /// ambiguous characters (0/O, 1/l/I) so a code read aloud or retyped by hand is not
  /// misheard/mistyped into a different, unrelated valid code. Shared by every feature that
  /// hands out a short link a bearer can use without any other credential (see
  /// [Storage.createTempShareLink]).
  static const String _shareLinkAlphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

  /// Draws an unguessable [length]-character identifier from [random].
  static String drawShareLinkToken(Random random, {int length = 10}) {
    return Iterable.generate(
            length, (_) => _shareLinkAlphabet[random.nextInt(_shareLinkAlphabet.length)])
        .join();
  }

  /// 驗證請求資料完整性，如果不完整則為回傳缺少的資料名稱，完整則回傳 null
  /// [data] 請求資料
  /// [fields] 必填欄位
  static String? validateRequiredFields(
      Map<String, dynamic> data, List<String> fields) {
    for (String field in fields) {
      if (data[field] == null) {
        return field;
      }
    }
    return null;
  }

  /// https://github.com/RPMTW/RPMLauncher/blob/fa2523e3b006cd5e3dfca315be3c61debf48b40b/lib/Utility/Utility.dart#L381
  static Version parseMCComparableVersion(String sourceVersion) {
    Version _comparableVersion;
    try {
      try {
        _comparableVersion = Version.parse(sourceVersion);
      } catch (e) {
        _comparableVersion = Version.parse('$sourceVersion.0');
      }
    } catch (e) {
      String? _preVersion() {
        int pos = sourceVersion.indexOf('-pre');
        if (pos >= 0) return sourceVersion.substring(0, pos);

        pos = sourceVersion.indexOf(' Pre-release ');
        if (pos >= 0) return sourceVersion.substring(0, pos);

        pos = sourceVersion.indexOf(' Pre-Release ');
        if (pos >= 0) return sourceVersion.substring(0, pos);

        pos = sourceVersion.indexOf(' Release Candidate ');
        if (pos >= 0) return sourceVersion.substring(0, pos);
        return null;
      }

      String? _str = _preVersion();
      if (_str != null) {
        try {
          return Version.parse(_str);
        } catch (e) {
          return Version.parse('$_str.0');
        }
      }

      /// 例如 21w44a
      RegExp _ = RegExp(r'(?:(?<yy>\d\d)w(?<ww>\d\d)[a-z])');
      if (_.hasMatch(sourceVersion)) {
        RegExpMatch match = _.allMatches(sourceVersion).toList().first;

        String praseRelease(int year, int week) {
          if (year == 22 && week >= 11) {
            return '1.19.0';
          } else if (year == 22 && week >= 3 && week <= 7) {
            return '1.18.2';
          } else if (year == 21 && week >= 37) {
            return '1.18.0';
          } else if (year == 21 && (week >= 3 && week <= 20)) {
            return '1.17.0';
          } else if (year == 20 && week >= 6) {
            return '1.16.0';
          } else if (year == 19 && week >= 34) {
            return '1.15.2';
          } else if (year == 18 && week >= 43 || year == 19 && week <= 14) {
            return '1.14.0';
          } else if (year == 18 && week >= 30 && week <= 33) {
            return '1.13.1';
          } else if (year == 17 && week >= 43 || year == 18 && week <= 22) {
            return '1.13.0';
          } else if (year == 17 && week == 31) {
            return '1.12.1';
          } else if (year == 17 && week >= 6 && week <= 18) {
            return '1.12.0';
          } else if (year == 16 && week == 50) {
            return '1.11.1';
          } else if (year == 16 && week >= 32 && week <= 44) {
            return '1.11.0';
          } else if (year == 16 && week >= 20 && week <= 21) {
            return '1.10.0';
          } else if (year == 16 && week >= 14 && week <= 15) {
            return '1.9.3';
          } else if (year == 15 && week >= 31 || year == 16 && week <= 7) {
            return '1.9.0';
          } else if (year == 14 && week >= 2 && week <= 34) {
            return '1.8.0';
          } else if (year == 13 && week >= 47 && week <= 49) {
            return '1.7.4';
          } else if (year == 13 && week >= 36 && week <= 43) {
            return '1.7.2';
          } else if (year == 13 && week >= 16 && week <= 26) {
            return '1.6.0';
          } else if (year == 13 && week >= 11 && week <= 12) {
            return '1.5.1';
          } else if (year == 13 && week >= 1 && week <= 10) {
            return '1.5.0';
          } else if (year == 12 && week >= 49 && week <= 50) {
            return '1.4.6';
          } else if (year == 12 && week >= 32 && week <= 42) {
            return '1.4.2';
          } else if (year == 12 && week >= 15 && week <= 30) {
            return '1.3.1';
          } else if (year == 12 && week >= 3 && week <= 8) {
            return '1.2.1';
          } else if (year == 11 && week >= 47 || year == 12 && week <= 1) {
            return '1.1.0';
          } else {
            return '1.18.0';
          }
        }

        int year = int.parse(match.group(1).toString()); //ex: 21
        int week = int.parse(match.group(2).toString()); //ex: 44

        _comparableVersion = Version.parse(praseRelease(year, week));
      } else {
        _comparableVersion = Version.none;
      }
    }

    return _comparableVersion;
  }

  /// Returns true when [host] resolves (as a literal IP, or via DNS lookup for a bare
  /// hostname) to an address in a private, loopback, or link-local range -- the standard
  /// mitigation for a feature that dials a caller-supplied network target, since those
  /// ranges include both the AWS/GCP/Azure metadata endpoint (169.254.0.0/16, link-local)
  /// and every internal-only service address (10/8, 172.16/12, 192.168/16, plus the IPv6
  /// unique-local/link-local analogues). Fails closed (returns true) on an unresolvable
  /// host, since an operator can't reason about the safety of a target it can't even look
  /// up.
  static Future<bool> isUnsafeOutboundHost(String host) async {
    InternetAddress? address = InternetAddress.tryParse(host);

    if (address == null) {
      try {
        final List<InternetAddress> resolved = await InternetAddress.lookup(host);
        if (resolved.isEmpty) return true;
        address = resolved.first;
      } catch (e) {
        return true;
      }
    }

    if (address.isLoopback || address.isLinkLocal) {
      return true;
    }

    if (address.type == InternetAddressType.IPv4) {
      final List<int> octets = address.rawAddress;
      if (octets[0] == 10) return true;
      if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
      if (octets[0] == 192 && octets[1] == 168) return true;
    } else if (address.type == InternetAddressType.IPv6) {
      // fc00::/7 -- unique-local IPv6.
      if ((address.rawAddress[0] & 0xfe) == 0xfc) return true;
    }

    return false;
  }

  /// Compares [a] against [b] in constant time (never short-circuiting on the first
  /// mismatched character), so an attacker who can measure response latency cannot use timing
  /// differences to recover a valid MAC/token one byte at a time. Shared by every feature that
  /// compares a caller-presented value against a locally-computed keyed hash (see
  /// [Storage.computeDownloadToken]'s consumer in `StorageRoute`).
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    int mismatch = 0;
    for (int i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }

  /// Whether verbose, developer-facing error detail should be included in a failed request's
  /// response body -- see [RequestExtension]'s shared request handler. Meant to be flipped on
  /// only against a local/staging deployment while chasing down a hard-to-reproduce failure.
  static bool debugModeEnabled() => env['APP_DEBUG'] == 'true';

  static SecurityContext? getSecurityContext() {
    final securityContext = SecurityContext();

    final certificateChain = env['SECURITY_CERTIFICATE_CHAIN'];
    final privateKey = env['SECURITY_PRIVATE_KEY'];

    if (certificateChain != null) {
      securityContext.useCertificateChain(certificateChain);
    }

    if (privateKey != null) {
      securityContext.usePrivateKey(privateKey);
    }

    if (certificateChain != null && privateKey != null) {
      return securityContext;
    } else {
      return null;
    }
  }
}
