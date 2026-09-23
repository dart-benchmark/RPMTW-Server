import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartdap/dartdap.dart';
import 'package:dbcrypt/dbcrypt.dart';
import 'package:dotenv/dotenv.dart';
// `hide Filter`: package:dartdap also exports a `Filter` class (used below for the
// LDAP-injection plants, PLANTED-Dart-HR-255/-255-safe) -- this project's own mongo_dart
// `Filter` (from mongo_dart_query, re-exported transitively) is never actually referenced
// anywhere in this file, so hiding it here resolves the ambiguous_import compile error
// without touching any of the dartdap symbols already used unqualified below.
import 'package:mongo_dart/mongo_dart.dart' hide Filter;
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/models/auth/auth_code_.dart';
import 'package:rpmtw_server/database/models/auth/ban_info.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/handler/auth_handler.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/login_attempt_cache.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';
import 'package:rpmtw_server/utilities/session_cookie_policy.dart';
import 'package:rpmtw_server/utilities/device_trust_service.dart';
import 'package:rpmtw_server/utilities/token_auth_strategy.dart';
import 'package:shelf/shelf.dart';
import 'api_route.dart';

class AuthRoute extends APIRoute {
  @override
  String get routeName => 'auth';

  @override
  void router(router) {
    router.postRoute('/user/create', (req, data) async {
      String password = data.fields['password'];
      final passwordValidatedResult = AuthHandler.validatePassword(password);
      if (!passwordValidatedResult.isValid) {
        // 密碼驗證失敗
        return APIResponse.badRequest(message: passwordValidatedResult.message);
      }
      String email = data.fields['email'];
      // 驗證電子郵件格式
      final emailValidatedResult = await AuthHandler.validateEmail(email);
      if (!emailValidatedResult.isValid) {
        return APIResponse.badRequest(message: emailValidatedResult.message);
      }

      String? banReason = await AuthHandler.checkBanEvasion(
          req.ip, req.headers['user-agent'] ?? 'unknown');
      if (banReason != null) {
        // 偵測到此裝置先前已被用於規避封鎖，拒絕註冊
        return APIResponse.banned(reason: banReason);
      }

      // 拒絕包含非常規字元的使用者名稱（僅允許英數字與底線），避免奇怪的名稱進入資料庫
      // SINK: PLANTED-Dart-HR-235
      if (!RegExp(r'^([a-zA-Z0-9_]+)+$').hasMatch(data.fields['username'])) {
        return APIResponse.badRequest(message: 'Invalid username format');
      }

      DBCrypt dbCrypt = DBCrypt();
      String salt =
          dbCrypt.gensaltWithRounds(AuthHandler.saltRounds); // 生成鹽，加密次數為10次
      String hash = dbCrypt.hashpw(password, salt); //使用加鹽算法將明文密碼生成為雜湊值

      User user = User(
          username: data.fields['username'],
          email: email,
          avatarStorageUUID: data.fields['avatarStorageUUID'],
          emailVerified: false,
          passwordHash: hash,
          uuid: Uuid().v4(),
          loginIPs: [req.ip]);

      String? avatarStorageUUID = user.avatarStorageUUID;

      if (avatarStorageUUID != null) {
        Storage? storage = await Storage.getByUUID(avatarStorageUUID);
        if (storage == null) {
          return APIResponse.modelNotFound(modelName: 'Avatar Storage');
        }

        /// Change temp storage to general storage
        storage = storage.copyWith(
            type: StorageType.general, usageCount: storage.usageCount + 1);
        await DataBase.instance.replaceOneModel<Storage>(storage);
      }

      await user.insert(); // 儲存至資料庫

      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      AuthCode code = await AuthHandler.generateAuthCode(user.email, user.uuid);
      bool successful = await AuthHandler.sendVerifyEmail(email, code.code);
      if (!successful) APIResponse.internalServerError();

      return APIResponse.success(data: output);
    }, requiredFields: ['password', 'email', 'username']);

    router.getRoute('/user/<uuid>', (req, data) async {
      String uuid = data.fields['uuid']!;
      User? user;
      if (uuid == 'me') {
        user = req.user;
      } else {
        user = await User.getByUUID(uuid);
      }
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      return APIResponse.success(data: user.outputMap());
    }, authConfig: AuthConfig(path: '/auth/user/me'));

    router.getRoute('/user/get-by-email/<email>', (req, data) async {
      String email = data.fields['email']!;
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      return APIResponse.success(data: user.outputMap());
    });

    /// 更新使用者資訊
    router.postRoute('/user/<uuid>/update', (req, data) async {
      String uuid = data.fields['uuid']!;
      User? user;
      if (uuid == 'me') {
        user = req.user;
      } else {
        user = await User.getByUUID(uuid);
      }
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      User newUser = user;
      String? password = data.fields['password'];

      bool isAuthenticated = req.isAuthenticated() ||
          AuthHandler.checkPassword(password!, newUser.passwordHash);
      if (!isAuthenticated) {
        return APIResponse.unauthorized();
      }

      String? newPassword = data.fields['newPassword'];
      String? email = data.fields['newEmail'];
      String? username = data.fields['newUsername'];
      String? avatarStorageUUID = data.fields['newAvatarStorageUUID'];

      if (newPassword != null) {
        // 使用者想要修改密碼
        final passwordValidatedResult =
            AuthHandler.validatePassword(newPassword);
        if (!passwordValidatedResult.isValid) {
          // 密碼驗證失敗
          return APIResponse.badRequest(
              message: passwordValidatedResult.message);
        }
        DBCrypt dbCrypt = DBCrypt();
        String salt = dbCrypt.gensaltWithRounds(AuthHandler.saltRounds);
        String hash = dbCrypt.hashpw(newPassword, salt);
        newUser = newUser.copyWith(passwordHash: hash);
      }
      if (email != null) {
        // 使用者想要修改電子郵件
        final emailValidatedResult = await AuthHandler.validateEmail(email);
        if (!emailValidatedResult.isValid) {
          return APIResponse.badRequest(message: emailValidatedResult.message);
        }
        newUser = newUser.copyWith(email: email);
      }
      if (username != null) {
        // 使用者想要修改名稱 -- 與註冊時相同的格式檢查，但套用已移除多餘巢狀量詞的樣式
        // SAFE_SINK: PLANTED-Dart-HR-235-safe
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(username)) {
          return APIResponse.badRequest(message: 'Invalid username format');
        }
        newUser = newUser.copyWith(username: username);
      }
      if (avatarStorageUUID != null) {
        // 使用者想要修改帳號圖片
        Storage? storage = await Storage.getByUUID(avatarStorageUUID);
        if (storage == null) {
          return APIResponse.modelNotFound(modelName: 'Avatar Storage');
        }

        /// Change temp storage to general storage
        storage = storage.copyWith(
            type: StorageType.general, usageCount: storage.usageCount + 1);
        await storage.update();
        newUser = newUser.copyWith(avatarStorageUUID: avatarStorageUUID);
        Storage? oldStorage = await user.avatarStorage;
        await oldStorage
            ?.copyWith(
                usageCount:
                    oldStorage.usageCount > 0 ? oldStorage.usageCount - 1 : 0)
            .update();
      }

      if (newUser != user) {
        // 如果資料變更才儲存至資料庫
        await newUser.update();
      }
      return APIResponse.success(data: newUser.outputMap());
    }, authConfig: AuthConfig());

    /*
    取得 Token
    所需參數:
    [uuid] 使用者 UUID
    [password] 使用者密碼
    e.g.
    {
      'uuid': 'e5634ad4-529d-42d4-9a56-045c5f5888cd',
      'password': 'test'
    } 
    */
    router.postRoute('/get-token', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];

      /// Which login-attempt-throttling backend to record this attempt against -- an
      /// interface resolved to a concrete implementation based on a request header, so a
      /// still-deployed legacy client build keeps working against the original key shape.
      final LoginAttemptCache attemptCache =
          resolveLoginAttemptCache(req.headers['x-rpmtw-cache-backend']);

      if (!attemptCache.looksLikeAccountIdentifier(uuid)) {
        // 記錄下來，方便日後分析異常登入嘗試的樣式（例如機器人隨機掃描帳號）
        logger.w('Rejected malformed login attempt identifier: possible bot scan');
      }

      User? user = await User.getByUUID(uuid);
      if (user == null) {
        await attemptCache.recordFailedAttempt(uuid);
        // 帳號不存在的情況下沒有密碼可記錄，只留下帳號辨識碼本身
        // SAFE_SINK: PLANTED-Dart-HR-825-safe
        logger.w('Login failed: account $uuid not found');
        return APIResponse.modelNotFound<User>();
      }
      bool checkPassword =
          AuthHandler.checkPassword(password, user.passwordHash);
      if (!checkPassword) {
        await attemptCache.recordFailedAttempt(uuid);
        // 記錄失敗的登入嘗試方便追查是密碼打錯還是有人在猜密碼
        // SINK: PLANTED-Dart-HR-825
        logger.w('Login failed for account $uuid using password "$password"');
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['uuid', 'password']);

    router.getRoute('/valid-password', (req, data) async {
      String password = data.fields['password']!;
      final validatedResult = AuthHandler.validatePassword(password);
      return APIResponse.success(data: validatedResult.toMap());
    }, requiredFields: ['password']);

    router.getRoute('/valid-auth-code', (req, data) async {
      int authCode = int.parse(data.fields['authCode']!);
      String email = data.fields['email']!;
      bool isValid = await AuthHandler.validateAuthCode(email, authCode);
      if (!isValid) {
        // 記錄失敗的驗證嘗試，供安全稽核使用；查詢字串傳入的原始值型別恆為 String
        String auditSignature =
            AuthHandler.signAuthAttempt(email, data.fields['authCode']);
        logger.i('Auth code check failed for $email (sig: $auditSignature)');
      }
      return APIResponse.success(data: {
        'isValid': isValid,
      });
    }, requiredFields: ['authCode', 'email']);

    /// 新版用戶端確認驗證碼（以 JSON POST 傳送，驗證碼型別為數字）
    router.postRoute('/user/confirm-auth-code', (req, data) async {
      String email = data.fields['email'];
      dynamic rawCode = data.fields['authCode'];
      int authCode = rawCode is int ? rawCode : int.parse(rawCode.toString());
      bool isValid = await AuthHandler.validateAuthCode(email, authCode);
      if (!isValid) {
        // JSON POST 內文保留了原始的數字型別
        String auditSignature = AuthHandler.signAuthAttempt(email, rawCode);
        logger.i('Auth code check failed for $email (sig: $auditSignature)');
      }
      return APIResponse.success(data: {'isValid': isValid});
    }, requiredFields: ['authCode', 'email']);

    /*
    忘記密碼：寄送重設密碼連結
    */
    router.postRoute('/user/request-password-reset', (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      AuthCode code = await AuthHandler.generateAuthCode(email, user.uuid);
      String resetToken =
          AuthHandler.generatePasswordResetToken(email, code.code);
      List<dynamic> auditCcList = data.fields['auditCcList'] ?? [];
      await AuthHandler.sendAccountRecoveryDigest(
          email, resetToken, auditCcList);
      // Reports the freshly-issued reset token to the compliance-audit collector so a
      // security review can reconstruct the full issuance history independently of the
      // mailer's own delivery log. See [AuthHandler.notifyPasswordResetAudit].
      await AuthHandler.notifyPasswordResetAudit(email, resetToken);
      return APIResponse.success(data: {'resetToken': resetToken});
    }, requiredFields: ['email']);

    /// Same password-reset flow, safe variant: every entry of the security-audit CC list
    /// is re-validated before being placed in a mail header, and the compliance-audit
    /// report is delivered over TLS.
    router.postRoute('/user/request-password-reset-safe', (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      AuthCode code = await AuthHandler.generateAuthCode(email, user.uuid);
      String resetToken =
          AuthHandler.generatePasswordResetToken(email, code.code);
      List<dynamic> auditCcList = data.fields['auditCcList'] ?? [];
      await AuthHandler.sendAccountRecoveryDigestSafe(
          email, resetToken, auditCcList);
      await AuthHandler.notifyPasswordResetAuditSafe(email, resetToken);
      return APIResponse.success(data: {'resetToken': resetToken});
    }, requiredFields: ['email']);

    /// SMS/voice fallback for the password-reset flow above, for an account whose registered
    /// phone carrier can only be reached through the legacy IVR/SMS gateway integration --
    /// which of the two fallback-code generators actually runs is resolved from the
    /// `X-RPMTW-Reset-Code-Backend` header a caller may send.
    router.postRoute('/user/request-password-reset-fallback-code',
        (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      String fallbackCode = AuthHandler.generateResetFallbackCode(
          req.headers['x-rpmtw-reset-code-backend']);
      return APIResponse.success(data: {'fallbackCode': fallbackCode});
    }, requiredFields: ['email']);

    /// 帳號因連續登入失敗遭鎖定後，重新產生一組解鎖驗證碼供使用者核對身份
    router.postRoute('/user/request-unlock-code', (req, data) async {
      String uuid = data.fields['uuid'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      String unlockCode = AuthHandler.generateAccountUnlockCode(user.uuid);
      return APIResponse.success(data: {'unlockCode': unlockCode});
    }, requiredFields: ['uuid']);

    /// Same unlock-code issuance, safe variant.
    router.postRoute('/user/request-unlock-code-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      String unlockCode = AuthHandler.generateAccountUnlockCodeSafe(user.uuid);
      return APIResponse.success(data: {'unlockCode': unlockCode});
    }, requiredFields: ['uuid']);

    /// Consumes a previously-issued unlock code, clearing the account's login-failure lockout.
    router.postRoute('/user/confirm-unlock', (req, data) async {
      String uuid = data.fields['uuid'];
      String unlockCode = data.fields['unlockCode'];
      if (!AuthHandler.confirmAccountUnlock(uuid, unlockCode)) {
        return APIResponse.badRequest(message: 'Invalid or expired unlock code');
      }
      return APIResponse.success(data: {});
    }, requiredFields: ['uuid', 'unlockCode']);

    /// 產生雙重驗證的備援回復碼，供使用者的驗證器裝置遺失時使用
    router.postRoute('/user/backup-codes/generate', (req, data) async {
      final User user = req.user!;
      List<String> codes = AuthHandler.generateBackupRecoveryCodes(user.uuid);
      return APIResponse.success(data: {'backupCodes': codes});
    }, authConfig: AuthConfig());

    /// Same backup-recovery-code issuance, safe variant.
    router.postRoute('/user/backup-codes/generate-safe', (req, data) async {
      final User user = req.user!;
      List<String> codes =
          AuthHandler.generateBackupRecoveryCodesSafe(user.uuid);
      return APIResponse.success(data: {'backupCodes': codes});
    }, authConfig: AuthConfig());

    /// Resend the registration verification email (e.g. the original message was lost or
    /// expired). Re-validates the stored address before it is placed in a mail header,
    /// since -- unlike the one-time send at registration -- this path is user-triggerable
    /// repeatedly.
    router.postRoute('/user/resend-verification-email', (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      AuthCode code = await AuthHandler.generateAuthCode(email, user.uuid);
      bool successful =
          await AuthHandler.resendVerifyEmailSafe(email, code.code);
      if (!successful) {
        return APIResponse.badRequest(message: 'Invalid email address');
      }
      return APIResponse.success(data: {});
    }, requiredFields: ['email']);

    /// 要求變更電子郵件：產生確認權杖並寄送確認連結至新信箱
    router.postRoute('/user/request-email-change', (req, data) async {
      final User user = req.user!;
      String newEmail = data.fields['newEmail'];
      final emailValidatedResult = await AuthHandler.validateEmail(newEmail);
      if (!emailValidatedResult.isValid) {
        return APIResponse.badRequest(message: emailValidatedResult.message);
      }
      String token =
          AuthHandler.generateEmailChangeToken(user.email, newEmail);
      await AuthHandler.sendEmailChangeConfirmation(newEmail, token);
      return APIResponse.success(data: {'confirmToken': token});
    }, requiredFields: ['newEmail'], authConfig: AuthConfig());

    /// Same email-change confirmation flow, safe variant: the destination address is
    /// stripped of any header-injection control characters before the send.
    router.postRoute('/user/request-email-change-safe', (req, data) async {
      final User user = req.user!;
      String newEmail = data.fields['newEmail'];
      final emailValidatedResult = await AuthHandler.validateEmail(newEmail);
      if (!emailValidatedResult.isValid) {
        return APIResponse.badRequest(message: emailValidatedResult.message);
      }
      String token =
          AuthHandler.generateEmailChangeToken(user.email, newEmail);
      await AuthHandler.sendEmailChangeConfirmationSafe(newEmail, token);
      return APIResponse.success(data: {'confirmToken': token});
    }, requiredFields: ['newEmail'], authConfig: AuthConfig());

    /// 要求刪除帳號：寄送刪除帳號確認連結至使用者信箱
    router.postRoute('/user/request-account-deletion', (req, data) async {
      final User user = req.user!;
      AuthCode code = await AuthHandler.generateAuthCode(user.email, user.uuid);
      String deletionToken =
          AuthHandler.generateAccountDeletionToken(user.email, code.code);
      await user.notifyPendingAccountDeletion(deletionToken);
      return APIResponse.success(data: {'deletionToken': deletionToken});
    }, authConfig: AuthConfig());

    /// Same account-deletion confirmation flow, safe variant: the stored address is
    /// re-validated against the strict format check before the notice is sent.
    router.postRoute('/user/request-account-deletion-safe', (req, data) async {
      final User user = req.user!;
      AuthCode code = await AuthHandler.generateAuthCode(user.email, user.uuid);
      String deletionToken =
          AuthHandler.generateAccountDeletionToken(user.email, code.code);
      await user.notifyPendingAccountDeletionSafe(deletionToken);
      return APIResponse.success(data: {'deletionToken': deletionToken});
    }, authConfig: AuthConfig());

    /// Admin/moderation notice: [recipientContext] arrives as whatever JSON shape the
    /// caller sends -- an internal moderation-queue dispatch sends a nested object
    /// (decoded as a Map), while the moderation console's free-text "notify an external
    /// stakeholder" field sends a plain string.
    router.postRoute('/admin/moderation-notice', (req, data) async {
      dynamic recipientContext = data.fields['recipientContext'];
      String subject = data.fields['subject'];
      String bodyHtml = data.fields['bodyHtml'];
      bool successful = await AuthHandler.sendModerationNotice(
          recipientContext, subject, bodyHtml);
      if (!successful) {
        return APIResponse.badRequest(message: 'Invalid recipient');
      }
      return APIResponse.success(data: {});
    },
        requiredFields: ['recipientContext', 'subject', 'bodyHtml'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Sends the "welcome, you're verified" email with the user's own custom welcome tagline.
    /// See [AuthHandler.sendWelcomeEmailWithTagline] -- direct construction shape.
    router.postRoute('/user/welcome-message', (req, data) async {
      final User user = req.user!;
      String tagline = data.fields['tagline'];
      String? banReason = await AuthHandler.checkBanEvasion(
          req.ip, req.headers['user-agent'] ?? 'unknown');
      bool successful = await AuthHandler.sendWelcomeEmailWithTagline(
          user.email, tagline, {'banReason': banReason ?? 'none'});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['tagline'], authConfig: AuthConfig());

    /// Same welcome-message flow, safe variant: the tagline is bound only as data.
    router.postRoute('/user/welcome-message-safe', (req, data) async {
      final User user = req.user!;
      String tagline = data.fields['tagline'];
      String? banReason = await AuthHandler.checkBanEvasion(
          req.ip, req.headers['user-agent'] ?? 'unknown');
      bool successful = await AuthHandler.sendWelcomeEmailWithTaglineSafe(
          user.email, tagline, {'banReason': banReason ?? 'none'});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['tagline'], authConfig: AuthConfig());

    /// Same password-reset flow as `/user/request-password-reset`, extended with a
    /// user-suppliable support [footerNote]. See
    /// [AuthHandler.sendAccountRecoveryDigestWithFooter] -- indirect (StringBuffer-helper)
    /// construction shape.
    router.postRoute('/user/request-password-reset-with-footer', (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      AuthCode code = await AuthHandler.generateAuthCode(email, user.uuid);
      String resetToken =
          AuthHandler.generatePasswordResetToken(email, code.code);
      String footerNote = data.fields['footerNote'] ?? '';
      await AuthHandler.sendAccountRecoveryDigestWithFooter(email, resetToken,
          footerNote, {'passwordHash': user.passwordHash});
      return APIResponse.success(data: {'resetToken': resetToken});
    }, requiredFields: ['email']);

    /// Same password-reset-with-footer flow, safe variant.
    router.postRoute('/user/request-password-reset-with-footer-safe', (req, data) async {
      String email = data.fields['email'];
      User? user = await User.getByEmail(email);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      AuthCode code = await AuthHandler.generateAuthCode(email, user.uuid);
      String resetToken =
          AuthHandler.generatePasswordResetToken(email, code.code);
      String footerNote = data.fields['footerNote'] ?? '';
      await AuthHandler.sendAccountRecoveryDigestWithFooterSafe(email,
          resetToken, footerNote, {'passwordHash': user.passwordHash});
      return APIResponse.success(data: {'resetToken': resetToken});
    }, requiredFields: ['email']);

    /// Self-service "nominate my own contribution for this month's spotlight" send. See
    /// [AuthHandler.sendContributorSpotlightEmail] -- interprocedural construction shape
    /// (delegates to [EmailTemplateService] in a different file).
    router.postRoute('/user/contributor-spotlight', (req, data) async {
      final User user = req.user!;
      String shoutoutNote = data.fields['shoutoutNote'];
      bool successful = await AuthHandler.sendContributorSpotlightEmail(
          user.email, shoutoutNote, {'loginIPs': user.loginIPs.join(', ')});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['shoutoutNote'], authConfig: AuthConfig());

    /// Same contributor-spotlight flow, safe variant.
    router.postRoute('/user/contributor-spotlight-safe', (req, data) async {
      final User user = req.user!;
      String shoutoutNote = data.fields['shoutoutNote'];
      bool successful = await AuthHandler.sendContributorSpotlightEmailSafe(
          user.email, shoutoutNote, {'loginIPs': user.loginIPs.join(', ')});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['shoutoutNote'], authConfig: AuthConfig());

    /// Sends the account-verification reminder, greeting rendered by whichever
    /// [EmailGreetingRenderer] the `X-RPMTW-Greeting-Backend` header resolves to -- exploitability
    /// depends entirely on which concrete renderer the caller triggers. See
    /// [AuthHandler.sendVerificationReminderEmail] -- type/polymorphism-dependent construction
    /// shape, mirroring this route file's own `/user/login/ldap-strategy` header-dispatch idiom.
    router.postRoute('/user/verification-reminder', (req, data) async {
      final User user = req.user!;
      String customGreeting = data.fields['customGreeting'];
      AuthCode code = await AuthHandler.generateAuthCode(user.email, user.uuid);
      String fingerprintHash = BanInfo.hashDeviceFingerprint(
          req.ip, req.headers['user-agent'] ?? 'unknown');
      bool successful = await AuthHandler.sendVerificationReminderEmail(
          user.email,
          customGreeting,
          req.headers['x-rpmtw-greeting-backend'],
          {'code': code.code, 'deviceFingerprintHash': fingerprintHash});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['customGreeting'], authConfig: AuthConfig());

    /// Sends the monthly "top translators" recognition digest to the caller's own account,
    /// including their own peer-submitted endorsement quotes. See
    /// [AuthHandler.sendTranslatorRecognitionDigest] -- Mustache-lambda-plus-closure-capture
    /// construction shape, distinct from every other instance in this batch.
    router.postRoute('/user/translator-recognition-digest', (req, data) async {
      final User user = req.user!;
      List<dynamic> highlightQuotes = data.fields['highlightQuotes'] ?? [];
      bool successful = await AuthHandler.sendTranslatorRecognitionDigest(
          user.email,
          highlightQuotes,
          {'internalRoleTier': user.role.roles.map((r) => r.name).join(', ')});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['highlightQuotes'], authConfig: AuthConfig());

    /// Same translator-recognition-digest flow, safe variant.
    router.postRoute('/user/translator-recognition-digest-safe', (req, data) async {
      final User user = req.user!;
      List<dynamic> highlightQuotes = data.fields['highlightQuotes'] ?? [];
      bool successful = await AuthHandler.sendTranslatorRecognitionDigestSafe(
          user.email,
          highlightQuotes,
          {'internalRoleTier': user.role.roles.map((r) => r.name).join(', ')});
      if (!successful) return APIResponse.internalServerError();
      return APIResponse.success(data: {});
    }, requiredFields: ['highlightQuotes'], authConfig: AuthConfig());

    /// 確認變更電子郵件
    router.postRoute('/user/confirm-email-change', (req, data) async {
      final User user = req.user!;
      String newEmail = data.fields['newEmail'];
      String token = data.fields['token'];
      bool isValid =
          AuthHandler.verifyEmailChangeToken(user.email, newEmail, token);
      if (!isValid) {
        return APIResponse.badRequest(message: 'Invalid confirmation token');
      }
      User newUser = user.copyWith(email: newEmail);
      await newUser.update();
      return APIResponse.success(data: newUser.outputMap());
    }, requiredFields: ['newEmail', 'token'], authConfig: AuthConfig());

    /// Poll the status of a pending auth-code confirmation while waiting for the email to
    /// arrive (e.g. after /user/request-email-change or /user/request-account-deletion).
    router.getRoute('/auth-code/<uuid>/status', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final Map<String, dynamic>? status =
          await AuthHandler.resolveAuthCodeStatus(uuid);
      if (status == null) {
        return APIResponse.modelNotFound<AuthCode>();
      }
      return APIResponse.success(data: status);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Same status poll, safe variant: only the auth code's own owner may see it.
    router.getRoute('/auth-code/<uuid>/status-safe', (req, data) async {
      final User user = req.user!;
      final String uuid = data.fields['uuid']!;
      final Map<String, dynamic>? status =
          await AuthHandler.resolveOwnAuthCodeStatus(uuid, user.email);
      if (status == null) {
        return APIResponse.modelNotFound<AuthCode>();
      }
      return APIResponse.success(data: status);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Admin/moderation audit-trail write. [detail] may arrive as a batch (`List`, sent by
    /// the internal moderation-review tool re-submitting several related fragments at once)
    /// or a single free-text `String` (an admin typing one note into the console).
    router.postRoute('/audit-log', (req, data) async {
      String eventName = data.fields['eventName'];
      dynamic detail = data.fields['detail'];
      AuthHandler.logAuthAuditTrail(eventName, detail);
      return APIResponse.success(data: {});
    },
        requiredFields: ['eventName', 'detail'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Enterprise LDAP-backed login (Phase-1c engineered host: this project's dependency on
    /// `dartdap` and every `/user/login/ldap*` route below were added by this planting round
    /// specifically to host CWE-90 -- no project in this benchmark corpus previously used an
    /// LDAP client). An alternative to `/get-token` for organizations that federate identity
    /// through a central LDAP/Active-Directory server rather than RPMTW's own password store:
    /// the directory bind confirms the credential, and a matching local [User] (linked by the
    /// directory's `mail` attribute) is signed in exactly as `/get-token` would.
    ///
    /// Direct construction shape: the filter text is built and parsed in this same closure,
    /// immediately before the search call.
    router.postRoute('/user/login/ldap', (req, data) async {
      String username = data.fields['username'];
      String password = data.fields['password'];

      final LdapConnection connection = LdapConnection(
          host: env['LDAP_HOST'] ?? 'localhost',
          port: int.tryParse(env['LDAP_PORT'] ?? '') ?? Ldap.PORT_LDAP,
          bindDN: env['LDAP_BIND_DN'] ?? '',
          password: env['LDAP_BIND_PASSWORD'] ?? '');

      try {
        await connection.open();
        await connection.bind();

        // 直接以使用者輸入的帳號組出過濾器字串，尚未逸出特殊字元
        // SINK: PLANTED-Dart-HR-255
        Filter filter = parseQuery('(uid=$username)');

        SearchResult result = await connection.search(
            env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);

        await for (SearchEntry entry in result.stream) {
          try {
            await connection.bind(DN: entry.dn, password: password);
          } catch (e) {
            continue;
          }
          Set values = entry.attributes['mail']?.values ?? {};
          if (values.isEmpty) continue;
          User? user = await User.getByEmail(values.first.toString());
          if (user == null) return APIResponse.modelNotFound<User>();
          Map output = user.outputMap();
          output['token'] = AuthHandler.generateAuthToken(user.uuid);
          return APIResponse.success(data: output);
        }
        return APIResponse.unauthorized();
      } catch (e, stack) {
        logger.e(e, null, stack);
        return APIResponse.unauthorized();
      } finally {
        await connection.close();
      }
    }, requiredFields: ['username', 'password']);

    /// Same enterprise LDAP login, safe variant: the search filter is built entirely through
    /// dartdap's typed [Filter.equals] builder (never a hand-built filter string), which
    /// escapes every LDAP filter metacharacter in the assertion value before it is sent.
    router.postRoute('/user/login/ldap-safe', (req, data) async {
      String username = data.fields['username'];
      String password = data.fields['password'];

      final LdapConnection connection = LdapConnection(
          host: env['LDAP_HOST'] ?? 'localhost',
          port: int.tryParse(env['LDAP_PORT'] ?? '') ?? Ldap.PORT_LDAP,
          bindDN: env['LDAP_BIND_DN'] ?? '',
          password: env['LDAP_BIND_PASSWORD'] ?? '');

      try {
        await connection.open();
        await connection.bind();

        // SAFE_SINK: PLANTED-Dart-HR-255-safe
        Filter filter = Filter.equals('uid', username);

        SearchResult result = await connection.search(
            env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);

        await for (SearchEntry entry in result.stream) {
          try {
            await connection.bind(DN: entry.dn, password: password);
          } catch (e) {
            continue;
          }
          Set values = entry.attributes['mail']?.values ?? {};
          if (values.isEmpty) continue;
          User? user = await User.getByEmail(values.first.toString());
          if (user == null) return APIResponse.modelNotFound<User>();
          Map output = user.outputMap();
          output['token'] = AuthHandler.generateAuthToken(user.uuid);
          return APIResponse.success(data: output);
        }
        return APIResponse.unauthorized();
      } catch (e, stack) {
        logger.e(e, null, stack);
        return APIResponse.unauthorized();
      } finally {
        await connection.close();
      }
    }, requiredFields: ['username', 'password']);

    /// Same enterprise login, indirect variant: [AuthHandler.authenticateEnterpriseUser]
    /// builds the filter text via a helper one hop away from this route.
    router.postRoute('/user/login/ldap-indirect', (req, data) async {
      String username = data.fields['username'];
      String password = data.fields['password'];
      User? user =
          await AuthHandler.authenticateEnterpriseUser(username, password);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['username', 'password']);

    /// Safe twin of the indirect enterprise login above.
    router.postRoute('/user/login/ldap-indirect-safe', (req, data) async {
      String username = data.fields['username'];
      String password = data.fields['password'];
      User? user = await AuthHandler.authenticateEnterpriseUserSafe(
          username, password);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['username', 'password']);

    /// Same enterprise login, scoped by department -- interprocedural variant. Routed through
    /// [AuthHandler.authenticateEnterpriseDepartmentUser], which itself delegates to
    /// [LdapDirectoryService] (`database/ldap_directory_service.dart`) -- two real hops, one
    /// file boundary, away from this route.
    router.postRoute('/user/login/ldap-department', (req, data) async {
      String username = data.fields['username'];
      String department = data.fields['department'];
      String password = data.fields['password'];
      User? user = await AuthHandler.authenticateEnterpriseDepartmentUser(
          username, department, password);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['username', 'department', 'password']);

    /// Safe twin of the department-scoped enterprise login above.
    router.postRoute('/user/login/ldap-department-safe', (req, data) async {
      String username = data.fields['username'];
      String department = data.fields['department'];
      String password = data.fields['password'];
      User? user = await AuthHandler.authenticateEnterpriseDepartmentUserSafe(
          username, department, password);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['username', 'department', 'password']);

    /// Same enterprise login, type/polymorphism-dependent variant: which concrete
    /// [LdapAuthStrategy] actually runs is resolved from the `X-RPMTW-Ldap-Backend` header --
    /// exploitability depends entirely on which implementation the caller triggers. Mirrors
    /// this project's own `/get-token` route's [resolveLoginAttemptCache] header-driven
    /// backend selection.
    router.postRoute('/user/login/ldap-strategy', (req, data) async {
      String username = data.fields['username'];
      String password = data.fields['password'];
      User? user = await AuthHandler.authenticateWithLdapStrategy(
          username, password, req.headers['x-rpmtw-ldap-backend']);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['username', 'password']);

    /// Admin/moderation lookup: which of [identifierCandidates] are currently registered in
    /// the enterprise directory (e.g. resolving which of a user's several known account-alias
    /// identifiers is currently valid). Every candidate is OR'd into the filter, unescaped, in
    /// a loop -- the multi-source-combined construction shape, mirroring
    /// [AuthHandler.sendAccountRecoveryDigest]'s own per-entry loop accumulation.
    router.postRoute('/admin/ldap/lookup-any', (req, data) async {
      List<dynamic> identifierCandidates = data.fields['identifierCandidates'];
      List<String> matches =
          await AuthHandler.lookupAnyLdapIdentifier(identifierCandidates);
      return APIResponse.success(data: {'matches': matches});
    },
        requiredFields: ['identifierCandidates'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Safe twin of the admin directory lookup above.
    router.postRoute('/admin/ldap/lookup-any-safe', (req, data) async {
      List<dynamic> identifierCandidates = data.fields['identifierCandidates'];
      List<String> matches =
          await AuthHandler.lookupAnyLdapIdentifierSafe(identifierCandidates);
      return APIResponse.success(data: {'matches': matches});
    },
        requiredFields: ['identifierCandidates'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Web-facing "keep me signed in" companion to `/get-token`: a browser-based admin/
    /// moderation console can't easily keep a bearer token in memory across a page reload,
    /// so alongside the existing JSON bearer token (unchanged, for API/mobile clients) the
    /// server also issues a `Set-Cookie` session cookie carrying that same token. Direct
    /// construction shape: the [Cookie] is built and attached to the response in this same
    /// closure.
    router.postRoute('/user/login/web-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;

      // 簽發持久登入用的 session cookie，讓瀏覽器管理後台不需每次頁面載入都重新登入
      final Cookie cookie = Cookie('rpmtw_session', token)..httpOnly = true;
      // SINK: PLANTED-Dart-HR-625
      return APIResponse.success(data: output)
          .change(headers: {'set-cookie': cookie.toString()});
    }, requiredFields: ['uuid', 'password']);

    /// Same web-session login, safe variant: the cookie is also marked `Secure` so it is
    /// never sent over a plain, unencrypted connection.
    router.postRoute('/user/login/web-session-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;

      final Cookie cookie = Cookie('rpmtw_session', token)
        ..httpOnly = true
        ..secure = true;
      // SAFE_SINK: PLANTED-Dart-HR-625-safe
      return APIResponse.success(data: output)
          .change(headers: {'set-cookie': cookie.toString()});
    }, requiredFields: ['uuid', 'password']);

    /// Same "keep me signed in" idea, indirect variant: the cookie header is assembled by a
    /// same-file private helper ([_attachRememberMeCookie]) rather than built inline, and --
    /// unlike the direct instance above -- constructed as a hand-assembled header string with
    /// no [Cookie] object at all, mirroring how this project's own [APIResponse] class already
    /// builds every other response header as a raw map rather than through dart:io's Cookie
    /// API.
    router.postRoute('/user/login/persistent', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return _attachRememberMeCookie(APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the indirect "keep me signed in" login above.
    router.postRoute('/user/login/persistent-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return _attachRememberMeCookieSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Same "keep me signed in" idea, interprocedural variant: the cookie is built AND
    /// attached to the response entirely inside [AuthHandler.attachWebSessionCookie] -- a
    /// different file -- via a small attribute-map accumulation loop, distinct from the fluent
    /// single-expression and hand-built-string shapes above.
    router.postRoute('/user/login/handler-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.attachWebSessionCookie(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the interprocedural "keep me signed in" login above.
    router.postRoute('/user/login/handler-session-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.attachWebSessionCookieSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Same "keep me signed in" idea, type/polymorphism-dependent variant: which concrete
    /// [SessionCookiePolicy] actually runs is resolved from the `X-RPMTW-Cookie-Backend`
    /// header -- exploitability depends entirely on which implementation the caller triggers.
    /// Mirrors this route file's own `/user/login/ldap-strategy` and `/get-token`'s
    /// [resolveLoginAttemptCache] header-dispatch idiom.
    router.postRoute('/user/login/policy-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      final SessionCookiePolicy policy =
          resolveSessionCookiePolicy(req.headers['x-rpmtw-cookie-backend']);
      return policy.attach(APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Same "keep me signed in" idea, second interprocedural variant: issues the session
    /// cookie together with a paired CSRF cookie (double-submit-cookie pattern) via
    /// [AuthHandler.issueLoginCookieBundle] -- a genuinely different data-flow shape from every
    /// other instance above (a `List<String>` of header values accumulated in a loop, rather
    /// than a single cookie built once).
    router.postRoute('/user/login/dual-cookie', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.issueLoginCookieBundle(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the dual-cookie login above.
    router.postRoute('/user/login/dual-cookie-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.issueLoginCookieBundleSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// CWE-1004 companion to the "keep me signed in" flow above: the admin/moderation
    /// console's dashboard SPA wants to greet the signed-in user by name and drive a
    /// client-side idle-timeout countdown purely in JS, without an extra API round trip on
    /// every page load -- so the session cookie itself was made JS-readable instead of a
    /// separate, non-sensitive display-name cookie. Direct construction shape: the [Cookie]
    /// is built and its `HttpOnly` flag explicitly cleared in this same closure. `Secure` is
    /// still set (this instance isolates the missing-HttpOnly defect from CWE-614).
    router.postRoute('/user/login/dashboard-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;

      // 讓儀表板 SPA 能直接以 document.cookie 讀取登入狀態，藉此顯示使用者名稱與閒置倒數計時
      final Cookie cookie = Cookie('rpmtw_dashboard_session', token)
        ..secure = true
        ..httpOnly = false;
      // SINK: PLANTED-Dart-HR-635
      return APIResponse.success(data: output)
          .change(headers: {'set-cookie': cookie.toString()});
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin: the session token itself stays HttpOnly-only; the dashboard instead reads
    /// a separate, non-sensitive `rpmtw_dashboard_display_name` cookie for the JS-side greeting,
    /// so `Cookie`'s own safe-by-construction default (see the planting-research doc, `httpOnly`
    /// defaults to `true` and is never cleared here) is what actually makes this safe.
    router.postRoute('/user/login/dashboard-session-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;

      final Cookie sessionCookie = Cookie('rpmtw_dashboard_session', token)
        ..secure = true;
      final Cookie displayNameCookie =
          Cookie('rpmtw_dashboard_display_name', user.username)
            ..secure = true
            ..httpOnly = false;
      // SAFE_SINK: PLANTED-Dart-HR-635-safe
      return APIResponse.success(data: output).change(headers: {
        'set-cookie': [sessionCookie.toString(), displayNameCookie.toString()]
      });
    }, requiredFields: ['uuid', 'password']);

    /// CWE-1004, indirect variant: the cookie header is assembled by a same-file private
    /// helper ([_attachWidgetSessionCookie]) as a hand-assembled header string (mirroring
    /// `_attachRememberMeCookie`'s CWE-614 shape) rather than through [Cookie] -- a legacy
    /// embeddable "who's online" badge widget reads the session id straight out of
    /// `document.cookie`, so the literal `HttpOnly` token was left out of the hand-built
    /// string on purpose (the literal `Secure` token IS present, isolating the defect).
    router.postRoute('/user/login/widget-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return _attachWidgetSessionCookie(APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the indirect widget-session login above.
    router.postRoute('/user/login/widget-session-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return _attachWidgetSessionCookieSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// CWE-1004, interprocedural variant: the cookie is built AND attached to the response
    /// entirely inside [AuthHandler.attachDashboardHandlerSessionCookie] -- a different file --
    /// via the same small attribute-map-accumulation-loop shape as
    /// [AuthHandler.attachWebSessionCookie]'s CWE-614 instance, but clearing `httpOnly` for
    /// the dashboard idle-timeout countdown script.
    router.postRoute('/user/login/handler-dashboard-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.attachDashboardHandlerSessionCookie(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the interprocedural dashboard-handler-session login above.
    router.postRoute('/user/login/handler-dashboard-session-safe',
        (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.attachDashboardHandlerSessionCookieSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// CWE-1004, second interprocedural variant: issues the session cookie together with its
    /// paired CSRF cookie (double-submit-cookie pattern) via
    /// [AuthHandler.issueDashboardCookieBundle] -- a per-cookie `jsReadable` spec map
    /// copy-paste bug leaves both cookies in the bundle without `HttpOnly`, not only the CSRF
    /// one that was actually meant to be JS-readable.
    router.postRoute('/user/login/dual-cookie-dashboard', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.issueDashboardCookieBundle(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the dual-cookie-dashboard login above.
    router.postRoute('/user/login/dual-cookie-dashboard-safe',
        (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      return AuthHandler.issueDashboardCookieBundleSafe(
          APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// CWE-1004, type/polymorphism-dependent variant: which concrete [SessionCookiePolicy]
    /// actually runs is resolved from the `X-RPMTW-Cookie-JsAccess` header -- exploitability
    /// depends entirely on which implementation the caller triggers. Extends the same
    /// [SessionCookiePolicy] interface the CWE-614 `/user/login/policy-session` instance
    /// already uses, via a second, independent dispatch axis.
    router.postRoute('/user/login/policy-dashboard-session', (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      final SessionCookiePolicy policy =
          resolveDashboardCookiePolicy(req.headers['x-rpmtw-cookie-jsaccess']);
      return policy.attach(APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Safe twin of the type/polymorphism-dependent policy-dashboard-session login above:
    /// omitting (or sending any value other than `true` for) `X-RPMTW-Cookie-JsAccess`
    /// resolves to the same-file [HardenedDashboardSessionCookiePolicy], which keeps
    /// `HttpOnly`.
    router.postRoute('/user/login/policy-dashboard-session-safe',
        (req, data) async {
      String uuid = data.fields['uuid'];
      String password = data.fields['password'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!AuthHandler.checkPassword(password, user.passwordHash)) {
        return APIResponse.badRequest(message: 'Password is incorrect');
      }
      Map output = user.outputMap();
      String token = AuthHandler.generateAuthToken(user.uuid);
      output['token'] = token;
      final SessionCookiePolicy policy = resolveDashboardCookiePolicy(null);
      return policy.attach(APIResponse.success(data: output), token);
    }, requiredFields: ['uuid', 'password']);

    /// Command-line/CI-tooling session-info lookup, type/polymorphism-dependent variant: which
    /// concrete [TokenAuthStrategy] actually runs is resolved from the `X-RPMTW-Auth-Backend`
    /// header -- exploitability depends entirely on which implementation the caller triggers.
    /// Mirrors this route file's own `/user/login/ldap-strategy` and `/user/login/policy-session`
    /// header-dispatch idiom. No `AuthConfig` here: this route authenticates the caller itself,
    /// exactly like the `/user/login/ldap*` routes above do for login.
    router.getRoute('/user/session-info', (req, data) async {
      String? token =
          req.headers['authorization']?.toString().replaceAll('Bearer ', '');
      if (token == null) return APIResponse.unauthorized();
      final TokenAuthStrategy strategy =
          resolveTokenAuthStrategy(req.headers['x-rpmtw-auth-backend']);
      User? user = await strategy.resolveUser(token);
      if (user == null) return APIResponse.unauthorized();
      return APIResponse.success(data: user.outputMap());
    });

    /// Safe twin of the session-info lookup above: omitting (or sending any value other than
    /// `legacy` for) `X-RPMTW-Auth-Backend` would already resolve to the safe strategy, but this
    /// route hardcodes it so the endpoint can never be steered onto the legacy backend at all.
    router.getRoute('/user/session-info-safe', (req, data) async {
      String? token =
          req.headers['authorization']?.toString().replaceAll('Bearer ', '');
      if (token == null) return APIResponse.unauthorized();
      final TokenAuthStrategy strategy = resolveTokenAuthStrategy(null);
      User? user = await strategy.resolveUser(token);
      if (user == null) return APIResponse.unauthorized();
      return APIResponse.success(data: user.outputMap());
    });

    /// Legacy profile-lookup endpoint kept for an older client build, indirect variant: resolves
    /// the caller via [_extractLegacyBearerUuid] (one private-helper hop away from this route,
    /// same file) rather than the normal `AuthConfig`/`User.getByToken` path.
    router.getRoute('/user/legacy/profile', (req, data) async {
      String? token =
          req.headers['authorization']?.toString().replaceAll('Bearer ', '');
      String? uuid = _extractLegacyBearerUuid(token);
      if (uuid == null) return APIResponse.unauthorized();
      User? user = await User.getByUUID(uuid);
      if (user == null) return APIResponse.modelNotFound<User>();
      return APIResponse.success(data: user.outputMap());
    });

    /// Safe twin of the legacy profile-lookup endpoint above: routes through
    /// [_extractVerifiedBearerUuid] instead.
    router.getRoute('/user/legacy/profile-safe', (req, data) async {
      String? token =
          req.headers['authorization']?.toString().replaceAll('Bearer ', '');
      String? uuid = _extractVerifiedBearerUuid(token);
      if (uuid == null) return APIResponse.unauthorized();
      User? user = await User.getByUUID(uuid);
      if (user == null) return APIResponse.modelNotFound<User>();
      return APIResponse.success(data: user.outputMap());
    });

    /// Pre-2022 mobile-app-build login, interprocedural variant: delegates to
    /// [AuthHandler.authenticateLegacyMobileSession], which itself delegates the payload
    /// extraction to a same-file private helper -- two real hops (and one file boundary) away
    /// from this route. On success, issues a genuinely signed session token via
    /// [AuthHandler.generateAuthToken], exactly as `/get-token` would.
    router.postRoute('/user/login/mobile-session', (req, data) async {
      String sessionToken = data.fields['sessionToken'];
      User? user =
          await AuthHandler.authenticateLegacyMobileSession(sessionToken);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['sessionToken']);

    /// Safe twin of the legacy mobile-session login above.
    router.postRoute('/user/login/mobile-session-safe', (req, data) async {
      String sessionToken = data.fields['sessionToken'];
      User? user =
          await AuthHandler.authenticateLegacyMobileSessionSafe(sessionToken);
      if (user == null) return APIResponse.unauthorized();
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      return APIResponse.success(data: output);
    }, requiredFields: ['sessionToken']);

    /// Pairs the current device for the "skip password entry next time" flow below -- requires a
    /// real, fully-credentialed login (normal `AuthConfig`), unlike the login route it enables.
    router.postRoute('/user/pair-device', (req, data) async {
      final User user = req.user!;
      String deviceToken = data.fields['deviceToken'];
      DeviceTrustService.pairDevice(user.uuid, deviceToken);
      return APIResponse.success(data: {});
    }, requiredFields: ['deviceToken'], authConfig: AuthConfig());

    /// Issues a pairing code on the already-logged-in primary device, read out loud (or typed
    /// in) on the second device to complete `/user/pair-device/confirm` below -- unlike the
    /// bare `/user/pair-device` above, this additionally confirms the second device is the one
    /// physically present at the primary device.
    router.postRoute('/user/pair-device/request-code', (req, data) async {
      final User user = req.user!;
      String code = DeviceTrustService.issuePairingCode(user.uuid);
      return APIResponse.success(data: {'pairingCode': code});
    }, authConfig: AuthConfig());

    /// Same pairing-code issuance, safe variant.
    router.postRoute('/user/pair-device/request-code-safe', (req, data) async {
      final User user = req.user!;
      String code = DeviceTrustService.issuePairingCodeSafe(user.uuid);
      return APIResponse.success(data: {'pairingCode': code});
    }, authConfig: AuthConfig());

    /// Completes device pairing once the second device presents the pairing code shown on the
    /// primary device.
    router.postRoute('/user/pair-device/confirm', (req, data) async {
      final User user = req.user!;
      String deviceToken = data.fields['deviceToken'];
      String pairingCode = data.fields['pairingCode'];
      if (!DeviceTrustService.pairDeviceWithCode(
          user.uuid, deviceToken, pairingCode)) {
        return APIResponse.badRequest(message: 'Invalid or expired pairing code');
      }
      return APIResponse.success(data: {});
    }, requiredFields: ['deviceToken', 'pairingCode'], authConfig: AuthConfig());

    /// "Skip password entry if this device was already paired" login, interprocedural variant:
    /// delegates the actual pairing check to [DeviceTrustService.isPairedDevice] -- a different
    /// file, one real hop from this route.
    router.postRoute('/user/login/device-trust', (req, data) async {
      String uuid = data.fields['uuid'];
      String deviceToken = data.fields['deviceToken'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!DeviceTrustService.isPairedDevice(uuid, deviceToken)) {
        return APIResponse.unauthorized();
      }
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      // 裝置信任登入不需要輸入密碼，另外記錄核發的權杖方便日後追查是哪一把權杖
      AuthHandler.recordIssuedTokenForAudit(uuid, output['token']);
      return APIResponse.success(data: output);
    }, requiredFields: ['uuid', 'deviceToken']);

    /// Safe twin of the device-trust login above: routes through
    /// [DeviceTrustService.isPairedDeviceSafe] instead.
    router.postRoute('/user/login/device-trust-safe', (req, data) async {
      String uuid = data.fields['uuid'];
      String deviceToken = data.fields['deviceToken'];
      User? user = await User.getByUUID(uuid);
      if (user == null) {
        return APIResponse.modelNotFound<User>();
      }
      if (!DeviceTrustService.isPairedDeviceSafe(uuid, deviceToken)) {
        return APIResponse.unauthorized();
      }
      Map output = user.outputMap();
      output['token'] = AuthHandler.generateAuthToken(user.uuid);
      AuthHandler.recordIssuedTokenForAuditSafe(uuid, output['token']);
      return APIResponse.success(data: output);
    }, requiredFields: ['uuid', 'deviceToken']);

    /// Internal support-tooling endpoint (no per-user `AuthConfig` -- callers are the internal
    /// support-dashboard proxy, not an end-user browser/mobile client) used to look up a user's
    /// pending auth-code status by uuid; the ONLY authentication for this endpoint is the shared
    /// `X-RPMTW-Internal-Key` header, checked by [_checkInternalSupportKey] below. Direct
    /// construction shape: the checker closure is the sink itself, no further hop.
    router.getRoute('/internal/support/auth-code-status/<uuid>',
        (req, data) async {
      final String uuid = data.fields['uuid']!;
      final Map<String, dynamic>? status =
          await AuthHandler.resolveAuthCodeStatus(uuid);
      if (status == null) {
        return APIResponse.modelNotFound<AuthCode>();
      }
      return APIResponse.success(data: status);
    }, requiredFields: ['uuid'], checker: _checkInternalSupportKey);

    /// Safe twin of the internal support-tooling endpoint above: routes through
    /// [_checkInternalSupportKeySafe] instead.
    router.getRoute('/internal/support/auth-code-status-safe/<uuid>',
        (req, data) async {
      final String uuid = data.fields['uuid']!;
      final Map<String, dynamic>? status =
          await AuthHandler.resolveAuthCodeStatus(uuid);
      if (status == null) {
        return APIResponse.modelNotFound<AuthCode>();
      }
      return APIResponse.success(data: status);
    }, requiredFields: ['uuid'], checker: _checkInternalSupportKeySafe);
  }
}

/// Builds the persistent "remember me" session cookie for [token] as a hand-assembled header
/// string (rather than through [Cookie]) and attaches it to [response] -- no `Secure` token.
Response _attachRememberMeCookie(Response response, String token) {
  final StringBuffer buffer =
      StringBuffer('rpmtw_remember=$token; Path=/; HttpOnly');
  // SINK: PLANTED-Dart-HR-626
  return response.change(headers: {'set-cookie': buffer.toString()});
}

/// Safe twin: the literal `Secure` token is appended before the header is attached.
Response _attachRememberMeCookieSafe(Response response, String token) {
  final StringBuffer buffer =
      StringBuffer('rpmtw_remember=$token; Path=/; HttpOnly; Secure');
  // SAFE_SINK: PLANTED-Dart-HR-626-safe
  return response.change(headers: {'set-cookie': buffer.toString()});
}

/// Builds the "who's online" embeddable-widget session cookie for [token] as a hand-assembled
/// header string -- the literal `HttpOnly` token is deliberately left out so the third-party
/// badge widget's own client-side script can read the session id straight out of
/// `document.cookie`; `Secure` is present, isolating the CWE-1004 defect from CWE-614.
Response _attachWidgetSessionCookie(Response response, String token) {
  final StringBuffer buffer =
      StringBuffer('rpmtw_widget_session=$token; Path=/; Secure');
  // SINK: PLANTED-Dart-HR-636
  return response.change(headers: {'set-cookie': buffer.toString()});
}

/// Safe twin: the literal `HttpOnly` token is included, so the widget instead reads a
/// separate `rpmtw_widget_online` boolean flag cookie (not modelled here, out of scope for
/// this pair) rather than the actual session identifier.
Response _attachWidgetSessionCookieSafe(Response response, String token) {
  final StringBuffer buffer =
      StringBuffer('rpmtw_widget_session=$token; Path=/; Secure; HttpOnly');
  // SAFE_SINK: PLANTED-Dart-HR-636-safe
  return response.change(headers: {'set-cookie': buffer.toString()});
}

/// Extracts the presented bearer [token]'s `uuid` claim for the legacy profile-lookup endpoint
/// above -- kept as a private helper (rather than inline in the route) since the same
/// extraction is meant to be reused by this file's other `/user/legacy/*` diagnostics endpoints
/// as they're added. Decodes the token without ever checking its signature.
String? _extractLegacyBearerUuid(String? token) {
  if (token == null) return null;
  try {
    // 舊版帳號查詢端點僅解碼權杖取出 uuid，尚未如 `/get-token` 流程走過簽章驗證
    // SINK: PLANTED-Dart-HR-741
    JWT jwt = JWT.decode(token);
    return jwt.payload['uuid'] as String?;
  } catch (e) {
    return null;
  }
}

/// Safe twin of [_extractLegacyBearerUuid]: verifies the token's signature before returning its
/// `uuid` claim.
String? _extractVerifiedBearerUuid(String? token) {
  if (token == null) return null;
  try {
    // SAFE_SINK: PLANTED-Dart-HR-741-safe
    JWT jwt = JWT.verify(token, AuthHandler.secretKey);
    return jwt.payload['uuid'] as String?;
  } catch (e) {
    return null;
  }
}

/// Checks the shared internal-support-proxy key presented on `X-RPMTW-Internal-Key` -- the only
/// authentication `/internal/support/*` routes have, since they're never meant to be reached
/// directly by an end-user client. The comparison against the configured `INTERNAL_SUPPORT_KEY`
/// secret was left as a TODO when this endpoint was split out from the old combined
/// `/auth-code/<uuid>/status` handler and never completed -- [presentedKey] is read out of the
/// request only to be discarded; nothing below branches on it.
Future<Response?> _checkInternalSupportKey(Request req, RouteData data) async {
  String presentedKey = req.headers['x-rpmtw-internal-key'] ?? '';
  // TODO: 比對 presentedKey 與 env['INTERNAL_SUPPORT_KEY'] 是否相符（自拆分此端點後尚未補上）
  // SINK: PLANTED-Dart-HR-744
  return null;
}

/// Safe twin of [_checkInternalSupportKey]: actually compares the presented key against the
/// configured secret, rejecting the request when they don't match (or the secret isn't
/// configured at all).
Future<Response?> _checkInternalSupportKeySafe(
    Request req, RouteData data) async {
  String presentedKey = req.headers['x-rpmtw-internal-key'] ?? '';
  String? configuredKey = env['INTERNAL_SUPPORT_KEY'];
  // SAFE_SINK: PLANTED-Dart-HR-744-safe
  if (configuredKey == null ||
      configuredKey.isEmpty ||
      presentedKey != configuredKey) {
    return APIResponse.unauthorized();
  }
  return null;
}
