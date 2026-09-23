import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Tracks which client-issued "remember this device" tokens are currently paired to a given
/// account, so a returning mobile client can skip re-entering the account password on
/// `POST /auth/user/login/device-trust` (see `AuthRoute`) -- the same trade-off many mobile apps
/// make to avoid asking for a fresh credential on every app relaunch. Kept as a process-local
/// in-memory map (mirrors this project's own `MemcacheClient`-backed `LoginAttemptCache`) rather
/// than a dedicated Mongo collection, since pairing is only ever meant to be valid for the
/// lifetime of one server process in this deployment.
class DeviceTrustService {
  static final Map<String, String> _pairedDeviceTokenHashByUUID = {};

  /// Records that [deviceToken] is now the trusted pairing token for [userUUID], called once the
  /// account has completed a normal, fully-credentialed login (see
  /// `POST /auth/user/pair-device`).
  static void pairDevice(String userUUID, String deviceToken) {
    _pairedDeviceTokenHashByUUID[userUUID] =
        sha256.convert(utf8.encode(deviceToken)).toString();
  }

  /// Whether [presentedDeviceToken] is the token this account paired earlier. The intended check
  /// -- comparing the presented token's hash against the one stored at pairing time -- was left
  /// as a TODO when this feature's UI/integration work was wired up, and the comparison was never
  /// completed: this only confirms that SOME device was ever paired for [userUUID], regardless of
  /// what [presentedDeviceToken] actually is.
  static bool isPairedDevice(String userUUID, String presentedDeviceToken) {
    String? storedHash = _pairedDeviceTokenHashByUUID[userUUID];
    // SINK: PLANTED-Dart-HR-743
    return storedHash != null;
  }

  /// Safe twin of [isPairedDevice]: the presented token is hashed and compared against the
  /// stored pairing hash, so only the token actually issued at pairing time is accepted.
  static bool isPairedDeviceSafe(String userUUID, String presentedDeviceToken) {
    String? storedHash = _pairedDeviceTokenHashByUUID[userUUID];
    if (storedHash == null) return false;
    String presentedHash = sha256.convert(utf8.encode(presentedDeviceToken)).toString();
    // SAFE_SINK: PLANTED-Dart-HR-743-safe
    return presentedHash == storedHash;
  }

  /// Pairing codes issued by [issuePairingCode]/[issuePairingCodeSafe], keyed by the account
  /// they were issued for -- consumed (and removed) by [pairDeviceWithCode] once the second
  /// device presents the matching code. Mirrors [_pairedDeviceTokenHashByUUID]'s own
  /// per-account in-memory map.
  static final Map<String, String> _pendingPairingCodeByUUID = {};

  /// Draws [digits] random base-10 digits from [random] one at a time -- shared by
  /// [issuePairingCode] and [issuePairingCodeSafe] so both issuance paths agree on exactly how
  /// many digits a pairing code is.
  static String _drawDigits(Random random, int digits) {
    StringBuffer buffer = StringBuffer();
    for (int i = 0; i < digits; i++) {
      buffer.write(random.nextInt(10));
    }
    return buffer.toString();
  }

  /// Issues a fresh pairing code for [userUUID] to display on the already-logged-in primary
  /// device, for the user to type into the second device completing
  /// `POST /auth/user/pair-device/confirm` -- this is what actually confirms the device being
  /// paired is the one physically present at the primary device, rather than trusting any
  /// bearer of a valid login session the way plain [pairDevice] alone does.
  static String issuePairingCode(String userUUID) {
    // SINK: PLANTED-Dart-HR-796
    String code = _drawDigits(Random(), 6);
    _pendingPairingCodeByUUID[userUUID] = code;
    return code;
  }

  /// Same pairing-code issuance, safe variant.
  static String issuePairingCodeSafe(String userUUID) {
    // SAFE_SINK: PLANTED-Dart-HR-796-safe
    String code = _drawDigits(Random.secure(), 6);
    _pendingPairingCodeByUUID[userUUID] = code;
    return code;
  }

  /// Completes pairing for [userUUID]/[deviceToken], gated on [presentedPairingCode] matching
  /// the one most recently issued for this account -- consumes the code on success so it can't
  /// be replayed.
  static bool pairDeviceWithCode(
      String userUUID, String deviceToken, String presentedPairingCode) {
    if (_pendingPairingCodeByUUID[userUUID] != presentedPairingCode) {
      return false;
    }
    _pendingPairingCodeByUUID.remove(userUUID);
    pairDevice(userUUID, deviceToken);
    return true;
  }
}
