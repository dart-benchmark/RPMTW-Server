import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartdap/dartdap.dart';
import 'package:dbcrypt/dbcrypt.dart';
import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:mustache_template/mustache_template.dart';
// `hide Filter`: package:dartdap also exports a `Filter` class (used below for the
// LDAP-injection plants, PLANTED-Dart-HR-255/-256/-257/-258/-259) -- this project's own
// mongo_dart `Filter` (from mongo_dart_query, re-exported transitively) is never actually
// referenced anywhere in this file, so hiding it here resolves the ambiguous_import compile
// error without touching any of the many dartdap symbols already used unqualified below.
import 'package:mongo_dart/mongo_dart.dart' hide Filter;
import 'package:rpmtw_server/database/models/auth/auth_code_.dart';
import 'package:rpmtw_server/database/models/auth/ban_info.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:shelf/shelf.dart';
import '../database/database.dart';
import '../database/email_template_service.dart';
import '../database/ldap_directory_service.dart';
import '../database/models/auth/user.dart';
import '../utilities/data.dart';
import '../utilities/email_greeting_renderer.dart';
import '../utilities/ldap_auth_strategy.dart';
import '../utilities/request_extension.dart';

class AuthHandler {
  static SecretKey get secretKey => SecretKey(env['DATA_BASE_SecretKey']!);
  static final int saltRounds = 10;

  static String generateAuthToken(String userUUID) {
    JWT jwt = JWT({'uuid': userUUID});
    return jwt.sign(AuthHandler.secretKey);
  }

  /// Mirrors a freshly-issued auth token into the ops-facing session-activity log, so a
  /// support engineer triaging "why was my session logged out" can correlate the token a
  /// client actually presented against the one this login endpoint most recently handed out.
  /// See the `/user/login/device-trust` route in [AuthRoute].
  static void recordIssuedTokenForAudit(String uuid, String token) {
    // SINK: PLANTED-Dart-HR-829
    logger.i('Issued auth token for $uuid: $token');
  }

  /// Same audit mirror, safe variant: only a short, non-reversible fingerprint of the token
  /// (its own SHA-256 prefix) is recorded, never the bearer value itself -- still enough to
  /// tell two log entries "about the same token" apart from each other.
  static void recordIssuedTokenForAuditSafe(String uuid, String token) {
    String fingerprint =
        sha256.convert(utf8.encode(token)).toString().substring(0, 12);
    // SAFE_SINK: PLANTED-Dart-HR-829-safe
    logger.i('Issued auth token for $uuid: fingerprint=$fingerprint');
  }

  /// Diagnostic helper for a failed real-time-chat token check -- reports the offending
  /// token value alongside the resolution error so a socket-auth outage can be told apart
  /// from an individual bad/expired token from the server logs alone. See
  /// [UniverseChatHandler.eventHandler]'s connection handshake, `handler/universe_chat_handler.dart`.
  static void logChatAuthFailure(String token, Object error) {
    // SINK: PLANTED-Dart-HR-827
    logger.w('Chat auth token rejected: token=$token error=$error');
  }

  static Future<AuthCode> generateAuthCode(
      String email, String userUUID) async {
    AuthCode authCode = AuthCode.create(email);
    await authCode.insert();
    return authCode;
  }

  /// 產生「忘記密碼」信件連結中使用的驗證權杖，權杖與使用者信箱及驗證碼綁定，
  /// 防止連結被用於其他帳號的密碼重設。
  static String generatePasswordResetToken(String email, int code) {
    String secret = env['DATA_BASE_SecretKey']!;
    // SINK: PLANTED-Dart-HR-41
    return md5.convert(utf8.encode('$email:$code:$secret')).toString();
  }

  /// 產生刪除帳號確認信中使用的驗證權杖（改用 sha256，避免弱雜湊碰撞攻擊）
  static String generateAccountDeletionToken(String email, int code) {
    String secret = env['DATA_BASE_SecretKey']!;
    // SAFE_SINK: PLANTED-Dart-HR-41-safe
    return sha256.convert(utf8.encode('$email:$code:$secret')).toString();
  }

  /// Hardcoded compliance-audit collector this instance reports every issued
  /// password-reset token to, so a security review can reconstruct the full reset-token
  /// issuance history independently of the mailer's own delivery log. See
  /// [notifyPasswordResetAudit].
  static const String _kPasswordResetAuditUrl =
      'http://audit.rpmtw.com/password-reset-events';

  /// Same audit collector, safe (TLS) endpoint. See [notifyPasswordResetAuditSafe].
  static const String _kPasswordResetAuditUrlSafe =
      'https://audit.rpmtw.com/password-reset-events';

  /// Reports a just-issued password-reset [token] for [email] to the compliance-audit
  /// collector, alongside [generatePasswordResetToken]'s own return value. The audit event
  /// body is assembled ahead of time so the same `Map` shape can be reused if delivery is
  /// ever retried.
  static Future<void> notifyPasswordResetAudit(
      String email, String token) async {
    final Map<String, String> auditEvent = {};
    auditEvent['email'] = email;
    auditEvent['resetToken'] = token;

    await _postPasswordResetAuditEvent(auditEvent);
  }

  static Future<void> _postPasswordResetAuditEvent(
      Map<String, String> auditEvent) async {
    // SINK: PLANTED-Dart-HR-766
    await http.post(Uri.parse(_kPasswordResetAuditUrl),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(auditEvent));
  }

  /// Same audit report, safe variant.
  static Future<void> notifyPasswordResetAuditSafe(
      String email, String token) async {
    final Map<String, String> auditEvent = {};
    auditEvent['email'] = email;
    auditEvent['resetToken'] = token;

    await _postPasswordResetAuditEventSafe(auditEvent);
  }

  static Future<void> _postPasswordResetAuditEventSafe(
      Map<String, String> auditEvent) async {
    // SAFE_SINK: PLANTED-Dart-HR-766-safe
    await http.post(Uri.parse(_kPasswordResetAuditUrlSafe),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(auditEvent));
  }

  /// 產生變更電子郵件的確認權杖，確保只有收到驗證信的人才能完成變更
  static String generateEmailChangeToken(
      String currentEmail, String newEmail) {
    return _signPayload('$currentEmail>$newEmail');
  }

  /// 驗證變更電子郵件的確認權杖是否正確
  static bool verifyEmailChangeToken(
      String currentEmail, String newEmail, String presentedToken) {
    return _signPayload('$currentEmail>$newEmail') == presentedToken;
  }

  /// 對任意字串內容做簽章，供需要「防止竄改」驗證的功能共用
  static String _signPayload(String payload) {
    String secret = env['DATA_BASE_SecretKey']!;
    // SINK: PLANTED-Dart-HR-42
    return sha1.convert(utf8.encode('$payload:$secret')).toString();
  }

  /// Builds the persistent "keep me signed in" session cookie for [token] and attaches it to
  /// [response] via a small attribute-accumulation loop -- interprocedural counterpart to the
  /// direct/indirect "keep me signed in" variants in `auth_route.dart`, which this method is
  /// called from (a different file).
  static Response attachWebSessionCookie(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_handler_session', token);
    final Map<String, dynamic> attributes = {'path': '/', 'httpOnly': true};
    for (final entry in attributes.entries) {
      if (entry.key == 'path') cookie.path = entry.value as String;
      if (entry.key == 'httpOnly') cookie.httpOnly = entry.value as bool;
    }
    // SINK: PLANTED-Dart-HR-627
    return response.change(headers: {'set-cookie': cookie.toString()});
  }

  /// Safe twin: the attribute map also carries `secure: true`.
  static Response attachWebSessionCookieSafe(Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_handler_session', token);
    final Map<String, dynamic> attributes = {
      'path': '/',
      'httpOnly': true,
      'secure': true
    };
    for (final entry in attributes.entries) {
      if (entry.key == 'path') cookie.path = entry.value as String;
      if (entry.key == 'httpOnly') cookie.httpOnly = entry.value as bool;
      if (entry.key == 'secure') cookie.secure = entry.value as bool;
    }
    // SAFE_SINK: PLANTED-Dart-HR-627-safe
    return response.change(headers: {'set-cookie': cookie.toString()});
  }

  /// Issues both the session cookie and its paired CSRF cookie (double-submit-cookie
  /// pattern, bound to the session token via the existing [_signPayload] helper) for [token]
  /// in one response, built by looping over a small cookie-spec map -- list-accumulation
  /// construction shape, distinct from every other "keep me signed in" variant.
  static Response issueLoginCookieBundle(Response response, String token) {
    final String csrfToken = _signPayload(token);
    final Map<String, String> cookieSpecs = {
      'rpmtw_session': token,
      'rpmtw_csrf': csrfToken,
    };
    final List<String> cookieHeaders = [];
    for (final entry in cookieSpecs.entries) {
      final Cookie cookie = Cookie(entry.key, entry.value)..path = '/';
      cookieHeaders.add(cookie.toString());
    }
    // SINK: PLANTED-Dart-HR-629
    return response.change(headers: {'set-cookie': cookieHeaders});
  }

  /// Safe twin: every cookie in the bundle is also marked `Secure`.
  static Response issueLoginCookieBundleSafe(Response response, String token) {
    final String csrfToken = _signPayload(token);
    final Map<String, String> cookieSpecs = {
      'rpmtw_session': token,
      'rpmtw_csrf': csrfToken,
    };
    final List<String> cookieHeaders = [];
    for (final entry in cookieSpecs.entries) {
      final Cookie cookie = Cookie(entry.key, entry.value)
        ..path = '/'
        ..secure = true;
      cookieHeaders.add(cookie.toString());
    }
    // SAFE_SINK: PLANTED-Dart-HR-629-safe
    return response.change(headers: {'set-cookie': cookieHeaders});
  }

  /// CWE-1004 counterpart to [attachWebSessionCookie]: interprocedural, same small
  /// attribute-accumulation-loop construction shape, but the map is threaded from a caller
  /// that wants the dashboard's idle-timeout countdown script to read the session cookie
  /// directly -- 'httpOnly': false was set for the whole map instead of only for a separate,
  /// non-sensitive UI-state cookie, so the actual session token ends up JS-readable too.
  static Response attachDashboardHandlerSessionCookie(
      Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_dashboard_handler_session', token);
    final Map<String, dynamic> attributes = {
      'path': '/',
      'secure': true,
      'httpOnly': false,
    };
    for (final entry in attributes.entries) {
      if (entry.key == 'path') cookie.path = entry.value as String;
      if (entry.key == 'secure') cookie.secure = entry.value as bool;
      if (entry.key == 'httpOnly') cookie.httpOnly = entry.value as bool;
    }
    // SINK: PLANTED-Dart-HR-637
    return response.change(headers: {'set-cookie': cookie.toString()});
  }

  /// Safe twin: the attribute map corrects `httpOnly` back to `true` for the actual session
  /// cookie -- the countdown script instead reads a separate
  /// `rpmtw_dashboard_handler_ui_state` cookie (not modelled here, out of scope for this pair).
  static Response attachDashboardHandlerSessionCookieSafe(
      Response response, String token) {
    final Cookie cookie = Cookie('rpmtw_dashboard_handler_session', token);
    final Map<String, dynamic> attributes = {
      'path': '/',
      'secure': true,
      'httpOnly': true,
    };
    for (final entry in attributes.entries) {
      if (entry.key == 'path') cookie.path = entry.value as String;
      if (entry.key == 'secure') cookie.secure = entry.value as bool;
      if (entry.key == 'httpOnly') cookie.httpOnly = entry.value as bool;
    }
    // SAFE_SINK: PLANTED-Dart-HR-637-safe
    return response.change(headers: {'set-cookie': cookie.toString()});
  }

  /// CWE-1004 counterpart to [issueLoginCookieBundle]: same list-accumulation-loop
  /// construction shape (a bundle of two cookies built from a shared spec map), but here the
  /// bug is a copy-paste one -- the CSRF cookie in this bundle is legitimately meant to be
  /// JS-readable (the SPA mirrors it into a request header for the double-submit-cookie CSRF
  /// check), so its spec entry carries `jsReadable: true`; the *session* cookie's entry was
  /// copied from the CSRF one and the `jsReadable` flag was never flipped back, so both cookies
  /// in the bundle end up without `HttpOnly`.
  static Response issueDashboardCookieBundle(Response response, String token) {
    final String csrfToken = _signPayload(token);
    final Map<String, Map<String, dynamic>> cookieSpecs = {
      'rpmtw_dashboard_session': {'value': token, 'jsReadable': true},
      'rpmtw_dashboard_csrf': {'value': csrfToken, 'jsReadable': true},
    };
    final List<String> cookieHeaders = [];
    for (final entry in cookieSpecs.entries) {
      final Cookie cookie = Cookie(entry.key, entry.value['value'] as String)
        ..path = '/'
        ..secure = true
        ..httpOnly = !(entry.value['jsReadable'] as bool);
      cookieHeaders.add(cookie.toString());
    }
    // SINK: PLANTED-Dart-HR-638
    return response.change(headers: {'set-cookie': cookieHeaders});
  }

  /// Safe twin: only the CSRF cookie's spec entry carries `jsReadable: true`; the session
  /// cookie's stays `false`, so it keeps `HttpOnly`.
  static Response issueDashboardCookieBundleSafe(
      Response response, String token) {
    final String csrfToken = _signPayload(token);
    final Map<String, Map<String, dynamic>> cookieSpecs = {
      'rpmtw_dashboard_session': {'value': token, 'jsReadable': false},
      'rpmtw_dashboard_csrf': {'value': csrfToken, 'jsReadable': true},
    };
    final List<String> cookieHeaders = [];
    for (final entry in cookieSpecs.entries) {
      final Cookie cookie = Cookie(entry.key, entry.value['value'] as String)
        ..path = '/'
        ..secure = true
        ..httpOnly = !(entry.value['jsReadable'] as bool);
      cookieHeaders.add(cookie.toString());
    }
    // SAFE_SINK: PLANTED-Dart-HR-638-safe
    return response.change(headers: {'set-cookie': cookieHeaders});
  }

  /// 檢查此次註冊的裝置是否與已知規避封鎖的裝置指紋相符，
  /// 若相符則回傳原本的封鎖原因。
  static Future<String?> checkBanEvasion(String ip, String userAgent) async {
    String fingerprintHash = BanInfo.hashDeviceFingerprint(ip, userAgent);
    BanInfo? banInfo = await BanInfo.getByFingerprint(fingerprintHash);
    return banInfo?.reason;
  }

  /// 為可疑的驗證碼嘗試產生防竄改的稽核簽章，供安全稽核記錄使用。
  /// 新版用戶端以 JSON POST 傳遞驗證碼（型別為 int），舊版（2021 年前）行動
  /// 用戶端仍以查詢字串傳遞驗證碼（型別為 String），依型別分開簽章以維持相容。
  static String signAuthAttempt(String email, dynamic submittedCode) {
    String secret = env['DATA_BASE_SecretKey']!;
    if (submittedCode is int) {
      // 新版用戶端：驗證碼以 JSON 數字傳入
      // SAFE_SINK: PLANTED-Dart-HR-44-safe
      return sha256
          .convert(utf8.encode('$email:$submittedCode:$secret'))
          .toString();
    } else {
      // 舊版（2021 年前）行動用戶端仍以查詢字串傳入驗證碼，維持回溯相容
      // SINK: PLANTED-Dart-HR-44
      return md5
          .convert(utf8.encode('$email:$submittedCode:$secret'))
          .toString();
    }
  }

  static Middleware handleBanIP() => (innerHandler) {
        return (request) {
          return Future.sync(() async {
            try {
              BanInfo? banInfo = await BanInfo.getByIP(request.ip);
              if (banInfo != null) {
                // 檢查是否被封鎖
                return APIResponse.banned(reason: banInfo.reason);
              }
            } catch (e) {
              return APIResponse.internalServerError();
            }

            return await innerHandler(request);
          }).then((response) {
            return response;
          });
        };
      };

  static Future<_EmailValidatedResult> validateEmail(String email,
      {bool skipDuplicate = false}) async {
    String splitter = '@';
    List<String> topEmails = [
      'gmail.com',
      'yahoo.com',
      'yahoo.com.tw',
      'yahoo.com.hk',
      'yahoo.co.uk',
      'yahoo.co.jp',
      'hotmail.com',
      'hotmail.co.uk',
      'hotmail.fr',
      'aol.com',
      'outlook.com',
      'icloud.com',
      'mail.com',
      'me.com',
      'msn.com',
      'live.com',
      'mac.com',
      'qq.com',
      'wanadoo.fr',
    ];

    _EmailValidatedResult successful =
        _EmailValidatedResult(true, 0, 'no issue');
    _EmailValidatedResult unknownDomain =
        _EmailValidatedResult(false, 1, 'unknown email domain');
    _EmailValidatedResult invalid =
        _EmailValidatedResult(false, 2, 'invalid email');
    _EmailValidatedResult duplicate =
        _EmailValidatedResult(false, 3, 'the email has already been used');

    if (email.contains(splitter)) {
      String domain = email.split(splitter)[1];
      //驗證網域格式
      if (domain.contains('.')) {
        //驗證網域是否為已知 Email 網域
        if (topEmails.contains(domain)) {
          if (skipDuplicate) return successful;
          User? user = await DataBase.instance
              .getModelWithSelector<User>(where.eq('email', email));
          if (user == null) {
            // 如果為空代表尚未被使用過
            return successful;
          } else {
            return duplicate;
          }
        } else {
          // 未知網域
          return unknownDomain;
        }
      } else {
        return invalid;
      }
    } else {
      return invalid;
    }
  }

  static _PasswordValidatedResult validatePassword(String password) {
    if (password.length < 6) {
      //密碼至少需要6個字元
      return _PasswordValidatedResult(
          false, 1, 'Password must be at least 6 characters long');
    } else if (password.length > 30) {
      // 密碼最多30個字元
      return _PasswordValidatedResult(
          false, 2, 'Password must be less than 30 characters long');
    } else if (!password.contains(RegExp(r'[A-Za-z]'))) {
      // 密碼必須至少包含一個英文字母
      return _PasswordValidatedResult(
          false, 3, 'Password must contain at least one letter of English');
    } else if (!password.contains(RegExp(r'[0-9]'))) {
      // 密碼必須至少包含一個數字
      return _PasswordValidatedResult(
          false, 4, 'Password must contain at least one number');
    } else {
      return _PasswordValidatedResult(true, 0, 'no issue');
    }
  }

  static Future<bool> sendVerifyEmail(String email, int authCode) async {
    if (kTestMode) return true;
    SmtpServer smtpServer;
    String smtpEmail;
    int randomInt = Random.secure().nextInt(100);

    /// 隨機選擇一種 smtp 服務使用
    if (randomInt % 2 == 0) {
      // 偶數
      String _qqSmtpEmail = env['SMTP_QQ_User']!;
      SmtpServer _qqSmtp = qq(_qqSmtpEmail, env['SMTP_QQ_Password']!);

      smtpEmail = _qqSmtpEmail;
      smtpServer = _qqSmtp;
    } else {
      // 奇數
      String _zohoSmtpEmail = env['SMTP_ZOHO_User']!;
      SmtpServer _zohoSmtp = SmtpServer(
        'smtppro.zoho.com',
        port: 587,
        username: _zohoSmtpEmail,
        password: env['SMTP_ZOHO_Password']!,
      );

      smtpEmail = _zohoSmtpEmail;
      smtpServer = _zohoSmtp;
    }

    String html = '''
Thank you for registering for an account on this site. Below is the verification code to complete registration for this account, which will expire in 30 minutes.<br>
感謝您註冊本網站的帳號，下方是完成註冊此帳號的驗證碼，此驗證碼將於 30 分鐘後失效。

<h1 style='color:orange'>${authCode.toString()}<br></h1>

You are receiving this email to verify that the account is registered by you and that you can use the RPMTW account after verification.<br>
If you have not requested an RPMTW account, please ignore this email.<br><br>

您收到這封電子郵件是因為要驗證該帳號是否由您註冊，通過驗證後您才能使用 RPMTW 帳號。<br>
如果您並未提出註冊 RPMTW 帳號的請求，則請忽略此封電子郵件。<br><br>

<strong>Copyright © RPMTW 2021-2022 Powered by The RPMTW Team.</strong>
      ''';

    final message = Message()
      ..from = Address(smtpEmail, 'RPMTW Team Support')
      // SINK: PLANTED-Dart-HR-155
      ..recipients.add(email)
      ..ccRecipients.add(email)
      ..bccRecipients.add(email)
      ..subject = '驗證您的 RPMTW 帳號電子郵件地址'
      ..html = html;
    // TODO:製作更美觀的驗證信件

    try {
      if (kTestMode) return true; //在測試模式下不發送訊息
      await send(message, smtpServer);
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// A request-supplied email address is only "safe enough to look up a domain" for
  /// [validateEmail] -- it does NOT confirm the whole string is free of header-injection
  /// control characters (see the mail-relay planting research). This strict, full-string
  /// validator is the recognized-safe pattern used by every mail-relay safe twin below: it
  /// anchors the check to the ENTIRE string, so a value can no longer sneak a CRLF sequence
  /// past validation just because a clean domain happens to appear somewhere in it.
  static bool _isStrictlyValidEmail(String email) {
    return RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
        .hasMatch(email);
  }

  /// Resend the registration verification email to an already-registered, unverified
  /// account. Unlike [sendVerifyEmail] (used only once, at registration time, on a value
  /// [validateEmail] has already domain-checked), this path can be triggered repeatedly by
  /// an end user who lost the original email, so it re-validates the stored address against
  /// the strict, full-string format check before it is ever placed in a mail header.
  static Future<bool> resendVerifyEmailSafe(String email, int authCode) async {
    if (kTestMode) return true;
    if (!_isStrictlyValidEmail(email)) return false;

    SmtpServer smtpServer;
    String smtpEmail;
    int randomInt = Random.secure().nextInt(100);

    if (randomInt % 2 == 0) {
      String _qqSmtpEmail = env['SMTP_QQ_User']!;
      SmtpServer _qqSmtp = qq(_qqSmtpEmail, env['SMTP_QQ_Password']!);
      smtpEmail = _qqSmtpEmail;
      smtpServer = _qqSmtp;
    } else {
      String _zohoSmtpEmail = env['SMTP_ZOHO_User']!;
      SmtpServer _zohoSmtp = SmtpServer(
        'smtppro.zoho.com',
        port: 587,
        username: _zohoSmtpEmail,
        password: env['SMTP_ZOHO_Password']!,
      );
      smtpEmail = _zohoSmtpEmail;
      smtpServer = _zohoSmtp;
    }

    final message = Message()
      ..from = Address(smtpEmail, 'RPMTW Team Support')
      // SAFE_SINK: PLANTED-Dart-HR-155-safe
      ..recipients.add(email)
      ..subject = '重新寄送：驗證您的 RPMTW 帳號電子郵件地址'
      ..html = '<h1>${authCode.toString()}</h1>';

    try {
      if (kTestMode) return true;
      await send(message, smtpServer);
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the confirmation email for a pending email-address change (completes the
  /// dangling TODO previously left in [AuthRoute]). Routed through this single helper from
  /// the route handler -- the source (the request-supplied [newEmail], already only
  /// domain-checked by [validateEmail] before this is called) reaches the sink here, one
  /// hop away from the route.
  static Future<bool> sendEmailChangeConfirmation(
      String newEmail, String token) async {
    if (kTestMode) return true;
    if (token.isEmpty) return false; // nothing to confirm

    final buffer = StringBuffer();
    buffer.write('請確認您的電子郵件變更 - ');
    buffer.write(token.substring(0, min(6, token.length)));
    final String subjectLine = buffer.toString();

    final String recipientAddress = newEmail;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..subject = subjectLine
      // SINK: PLANTED-Dart-HR-156
      ..recipients.add(recipientAddress)
      ..html = 'Confirm token: $token';

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendEmailChangeConfirmation]: the destination address is stripped of
  /// any CRLF/control characters before it is ever assigned to the message, per the
  /// mail-relay planting research's documented CRLF-stripping sanitizer.
  static Future<bool> sendEmailChangeConfirmationSafe(
      String newEmail, String token) async {
    if (kTestMode) return true;
    if (token.isEmpty) return false;

    final String sanitizedAddress =
        newEmail.replaceAll(RegExp(r'[\r\n]'), '');

    final buffer = StringBuffer();
    buffer.write('請確認您的電子郵件變更 - ');
    buffer.write(token.substring(0, min(6, token.length)));
    final String subjectLine = buffer.toString();

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..subject = subjectLine
      // SAFE_SINK: PLANTED-Dart-HR-156-safe
      ..recipients.add(sanitizedAddress)
      ..html = 'Confirm token: $token';

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the confirmation email for a pending account-deletion request. Called from
  /// [User.notifyPendingAccountDeletion] (a real cross-file, model-layer hop from the
  /// route -- see that method) rather than directly from a route handler.
  static Future<bool> sendAccountDeletionConfirmation(
      Map<String, dynamic> pendingDeletion) async {
    if (kTestMode) return true;
    final String email = pendingDeletion['email'] as String;
    final String token = pendingDeletion['token'] as String;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..subject = '確認刪除您的 RPMTW 帳號'
      // SINK: PLANTED-Dart-HR-157
      ..bccRecipients.add(email)
      ..html = 'Deletion token: $token';

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendAccountDeletionConfirmation]: re-validates the address against the
  /// strict full-string format check before it is placed in the message.
  static Future<bool> sendAccountDeletionConfirmationSafe(
      Map<String, dynamic> pendingDeletion) async {
    if (kTestMode) return true;
    final String email = pendingDeletion['email'] as String;
    final String token = pendingDeletion['token'] as String;
    if (!_isStrictlyValidEmail(email)) return false;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..subject = '確認刪除您的 RPMTW 帳號'
      // SAFE_SINK: PLANTED-Dart-HR-157-safe
      ..bccRecipients.add(email)
      ..html = 'Deletion token: $token';

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends an account-moderation notice. [recipientContext] may arrive as a `Map` (an
  /// internal service call already carrying a resolved, pre-verified user context -- e.g.
  /// dispatched from the moderation queue) or a `String` (an admin typed a raw address
  /// into the moderation console's free-text field). Mirrors this project's own existing
  /// internal-context dispatch idiom (see `Storage.adminSearch` /
  /// `TranslateRoute._applyCollabEdit`): the `Map` branch trusts the internal caller and
  /// skips re-validation, the `String` branch re-checks a value that did not arrive
  /// through the internal service boundary.
  static Future<bool> sendModerationNotice(
      dynamic recipientContext, String subject, String bodyHtml) async {
    if (kTestMode) return true;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..subject = subject
      ..html = bodyHtml;

    if (recipientContext is Map) {
      // Internal service context is assumed already resolved/trusted -- no re-check here.
      // SINK: PLANTED-Dart-HR-158
      message.recipients.add(recipientContext['email'].toString());
    } else {
      final String rawEmail = recipientContext as String;
      if (!_isStrictlyValidEmail(rawEmail)) return false;
      // SAFE_SINK: PLANTED-Dart-HR-158-safe
      message.recipients.add(rawEmail);
    }

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the password-reset link email, CC'ing this account's configured security-audit
  /// list (completes the dangling TODO previously left in [AuthRoute]). Every entry of
  /// [auditCcList] is appended to the message's CC recipients in a loop -- a construction
  /// shape distinct from the single-value sinks above, and a realistic "open relay via
  /// recipient list" variant of mail-relay: a single malicious list entry is enough.
  static Future<bool> sendAccountRecoveryDigest(String primaryEmail,
      String resetToken, List<dynamic> auditCcList) async {
    if (kTestMode) return true;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '密碼重設請求'
      ..html = 'Reset token: $resetToken';

    for (final cc in auditCcList) {
      // Every password-reset attempt CCs this account's configured compliance/security
      // audit recipients, so support can review contested resets.
      // SINK: PLANTED-Dart-HR-159
      message.ccRecipients.add(cc.toString());
    }

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendAccountRecoveryDigest]: each CC entry is validated against the
  /// strict full-string format check before being added; a malicious entry is skipped
  /// rather than appended.
  static Future<bool> sendAccountRecoveryDigestSafe(String primaryEmail,
      String resetToken, List<dynamic> auditCcList) async {
    if (kTestMode) return true;

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '密碼重設請求'
      ..html = 'Reset token: $resetToken';

    for (final cc in auditCcList) {
      final String ccString = cc.toString();
      if (!_isStrictlyValidEmail(ccString)) continue;
      // SAFE_SINK: PLANTED-Dart-HR-159-safe
      message.ccRecipients.add(ccString);
    }

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the "welcome, you're verified" email, including the user's own custom welcome-page
  /// [tagline] (a short profile setting the user picks themselves, shown back to them in this
  /// email). [internalContext] is a small data bag the caller already resolved (mirrors
  /// [sendAccountDeletionConfirmation]'s own pre-resolved-map idiom) -- here it carries this
  /// account's [checkBanEvasion] result, present because the SAME base render call is reused by
  /// an internal support-tooling variant of this email that does need to show it. Direct
  /// construction shape: the template SOURCE is built and compiled in this one function.
  static Future<bool> sendWelcomeEmailWithTagline(
      String email, String tagline, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final String templateSource =
        'Welcome back! $tagline<br>Your account is now verified.';

    // SINK: PLANTED-Dart-HR-325
    final Template template = Template(templateSource, htmlEscapeValues: false);
    final String html = template.renderString({...internalContext});

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(email)
      ..subject = '歡迎回來 RPMTW'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendWelcomeEmailWithTagline]: the template source is a fixed literal with a
  /// named `{{tagline}}` tag -- [tagline] is bound only as a data value, never spliced into the
  /// compiled source, so an embedded `{{...}}` fragment renders as inert literal text.
  static Future<bool> sendWelcomeEmailWithTaglineSafe(
      String email, String tagline, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    const String templateSource =
        'Welcome back! {{tagline}}<br>Your account is now verified.';

    // SAFE_SINK: PLANTED-Dart-HR-325-safe
    final Template template = Template(templateSource, htmlEscapeValues: false);
    final String html =
        template.renderString({'tagline': tagline, ...internalContext});

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(email)
      ..subject = '歡迎回來 RPMTW'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Builds the template SOURCE for [sendAccountRecoveryDigestWithFooter] -- assembled across
  /// several [StringBuffer] writes (indirect construction shape, one helper hop away from the
  /// sink, distinct from [sendWelcomeEmailWithTagline]'s single-expression interpolation).
  /// [footerNote] is a free-text "additional context for support" field the account holder may
  /// attach to their own password-reset request.
  static String _buildAccountRecoveryFooterSource(String footerNote) {
    final StringBuffer buffer = StringBuffer();
    buffer.write('Reset token: {{resetToken}}<br>');
    buffer.write('Support note: ');
    buffer.write(footerNote);
    return buffer.toString();
  }

  /// Safe twin of [_buildAccountRecoveryFooterSource]: the note is left as a named tag in the
  /// static source rather than being written in verbatim.
  static String _buildAccountRecoveryFooterSourceSafe() {
    final StringBuffer buffer = StringBuffer();
    buffer.write('Reset token: {{resetToken}}<br>');
    buffer.write('Support note: {{footerNote}}');
    return buffer.toString();
  }

  /// Same password-reset flow as [sendAccountRecoveryDigest], extended with a user-suppliable
  /// support [footerNote]. [internalContext] carries this account's [User.passwordHash] --
  /// present because the same data bag is reused by an internal support-tooling variant of this
  /// digest that legitimately needs it, not because this end-user-facing send is meant to
  /// expose it.
  static Future<bool> sendAccountRecoveryDigestWithFooter(String primaryEmail,
      String resetToken, String footerNote, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final String source = _buildAccountRecoveryFooterSource(footerNote);
    // SINK: PLANTED-Dart-HR-326
    final Template template = Template(source, htmlEscapeValues: false);
    final String html =
        template.renderString({'resetToken': resetToken, ...internalContext});

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '密碼重設請求'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendAccountRecoveryDigestWithFooter]: routes through
  /// [_buildAccountRecoveryFooterSourceSafe] instead, binding [footerNote] only as data.
  static Future<bool> sendAccountRecoveryDigestWithFooterSafe(String primaryEmail,
      String resetToken, String footerNote, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final String source = _buildAccountRecoveryFooterSourceSafe();
    // SAFE_SINK: PLANTED-Dart-HR-326-safe
    final Template template = Template(source, htmlEscapeValues: false);
    final String html = template.renderString(
        {'resetToken': resetToken, 'footerNote': footerNote, ...internalContext});

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '密碼重設請求'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the "featured contributor of the month" recognition email. Delegates the actual
  /// template rendering to [EmailTemplateService] (a different file,
  /// `database/email_template_service.dart`) -- the request-originated [shoutoutNote] reaches
  /// that service's sink one real hop (and one file) away from this method, the same
  /// "route -> handler -> service" shape [authenticateEnterpriseDepartmentUser] already uses.
  static Future<bool> sendContributorSpotlightEmail(String email,
      String shoutoutNote, Map<String, dynamic> moderationContext) async {
    if (kTestMode) return true;

    final String html = EmailTemplateService()
        .renderContributorSpotlightEmail(shoutoutNote, moderationContext);

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(email)
      ..subject = '本月精選貢獻者'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendContributorSpotlightEmail]: routes through
  /// [EmailTemplateService.renderContributorSpotlightEmailSafe] instead.
  static Future<bool> sendContributorSpotlightEmailSafe(String email,
      String shoutoutNote, Map<String, dynamic> moderationContext) async {
    if (kTestMode) return true;

    final String html = EmailTemplateService()
        .renderContributorSpotlightEmailSafe(shoutoutNote, moderationContext);

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(email)
      ..subject = '本月精選貢獻者'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the account-verification reminder email, greeting rendered by whichever
  /// [EmailGreetingRenderer] [backendHeader] resolves to (see
  /// `utilities/email_greeting_renderer.dart`) -- exploitability depends entirely on which
  /// concrete renderer implementation the caller triggers, mirroring this class's own
  /// [authenticateWithLdapStrategy] header-dispatched-implementation idiom. [internalContext]
  /// carries this account's own auth [code] plus a [BanInfo.hashDeviceFingerprint] value,
  /// present because the same data bag is reused by an internal support-tooling variant of
  /// this reminder.
  static Future<bool> sendVerificationReminderEmail(String email,
      String customGreeting, String? backendHeader,
      Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final EmailGreetingRenderer renderer = resolveEmailGreetingRenderer(backendHeader);
    final String html = renderer.renderGreeting(customGreeting, internalContext);

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(email)
      ..subject = '請完成您的帳號驗證'
      ..html = html;

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Sends the monthly "top translators" recognition digest. Every entry of [highlightQuotes]
  /// (a peer-submitted one-line endorsement about that translator's work this month) is
  /// rendered through its own single-use Mustache lambda -- the lambda closes over that
  /// iteration's quote text (captured as a closure/upvalue, a construction shape distinct from
  /// every other instance in this batch) and re-parses it as template SOURCE via
  /// `LambdaContext.renderSource`, rather than writing it out verbatim. [internalContext]
  /// carries this translator's internal moderation role tier, present because the same digest
  /// is reused, unmodified, by an internal moderation-review variant that does need it.
  static Future<bool> sendTranslatorRecognitionDigest(String primaryEmail,
      List<dynamic> highlightQuotes, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final StringBuffer body = StringBuffer();
    body.write('Thank you for your contributions this month!<br>');
    for (final quote in highlightQuotes) {
      final String quoteText = quote.toString();
      Object quoteLambda(LambdaContext ctx) {
        // SINK: PLANTED-Dart-HR-329
        ctx.write(ctx.renderSource(quoteText));
        return '';
      }

      final Template quoteTemplate = Template('{{#q}}{{/q}}', htmlEscapeValues: false);
      body.write(
          quoteTemplate.renderString({'q': quoteLambda, ...internalContext}));
      body.write('<br>');
    }

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '本月翻譯貢獻回顧'
      ..html = body.toString();

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  /// Safe twin of [sendTranslatorRecognitionDigest]: each lambda writes the quote text out
  /// verbatim (`ctx.write(quoteText)`) instead of re-parsing it as template source.
  static Future<bool> sendTranslatorRecognitionDigestSafe(String primaryEmail,
      List<dynamic> highlightQuotes, Map<String, dynamic> internalContext) async {
    if (kTestMode) return true;

    final StringBuffer body = StringBuffer();
    body.write('Thank you for your contributions this month!<br>');
    for (final quote in highlightQuotes) {
      final String quoteText = quote.toString();
      Object quoteLambda(LambdaContext ctx) {
        // SAFE_SINK: PLANTED-Dart-HR-329-safe
        ctx.write(quoteText);
        return '';
      }

      final Template quoteTemplate = Template('{{#q}}{{/q}}', htmlEscapeValues: false);
      body.write(
          quoteTemplate.renderString({'q': quoteLambda, ...internalContext}));
      body.write('<br>');
    }

    final message = Message()
      ..from = Address(env['SMTP_ZOHO_User']!, 'RPMTW Team Support')
      ..recipients.add(primaryEmail)
      ..subject = '本月翻譯貢獻回顧'
      ..html = body.toString();

    try {
      await send(
          message,
          SmtpServer(
            'smtppro.zoho.com',
            port: 587,
            username: env['SMTP_ZOHO_User']!,
            password: env['SMTP_ZOHO_Password']!,
          ));
      return true;
    } catch (e, stack) {
      logger.e(e, null, stack);
      return false;
    }
  }

  static bool checkPassword(String password, String hash) {
    DBCrypt dbCrypt = DBCrypt();
    return dbCrypt.checkpw(password, hash);
  }

  static Future<bool> validateAuthCode(String email, int authCode) async {
    try {
      AuthCode? model = await AuthCode.getByCode(authCode);
      if (model == null) {
        return false;
      } else {
        if (model.email == email) {
          //驗證碼的 email 與輸入的 email 是否相同
          if (model.isExpired) {
            //驗證碼過期
            return false;
          } else {
            //驗證碼未過期
            if (kTestMode) return true; //在測試模式下略過確認使用者
            User? user = await User.getByEmail(email);
            if (user != null) {
              user = user.copyWith(emailVerified: true);
              await user.update();
              return true;
            } else {
              return false;
            }
          }
        } else {
          return false;
        }
      }
    } catch (e) {
      return false;
    }
  }

  /// Lets the client poll the status of a pending auth code while waiting for the
  /// confirmation email to arrive (used by the email-change / account-deletion
  /// confirmation flows above, both of which hold a token tied to an [AuthCode] the
  /// client cannot otherwise inspect).
  static Future<Map<String, dynamic>?> resolveAuthCodeStatus(
      String uuid) async {
    AuthCode? authCode = await AuthCode.getByUUID(uuid);
    if (authCode == null) {
      return null;
    }

    // SINK: PLANTED-Dart-HR-132
    return {
      'email': authCode.email,
      'code': authCode.code,
      'isExpired': authCode.isExpired,
    };
  }

  /// Same status lookup, safe variant: only the auth code's own owner (matched by the
  /// requester's verified email) may see it.
  static Future<Map<String, dynamic>?> resolveOwnAuthCodeStatus(
      String uuid, String requesterEmail) async {
    AuthCode? authCode = await AuthCode.getByUUID(uuid);
    if (authCode == null || authCode.email != requesterEmail) {
      return null;
    }

    // SAFE_SINK: PLANTED-Dart-HR-132-safe
    return {
      'email': authCode.email,
      'code': authCode.code,
      'isExpired': authCode.isExpired,
    };
  }

  /// Writes a single audit-trail entry for a security-sensitive auth event. [detail] may
  /// arrive as a `List<dynamic>` (the internal moderation-review tool re-submitting several
  /// already-known-safe audit fragments in one batch) or a single `String` (an admin typing
  /// one free-text note into the moderation console) -- mirrors this class's own
  /// [signAuthAttempt] dynamic-dispatch-by-type idiom.
  static void logAuthAuditTrail(String eventName, dynamic detail) {
    if (detail is List) {
      // Internal batch-replay path: each fragment is assumed already-vetted by the
      // upstream tool, so the whole batch is joined and written as-is.
      // SINK: PLANTED-Dart-HR-194
      logger.w('Auth audit [$eventName]: ${detail.join(" | ")}');
    } else {
      final String safeDetail =
          detail.toString().replaceAll('\r', '\\r').replaceAll('\n', '\\n');
      // SAFE_SINK: PLANTED-Dart-HR-194-safe
      logger.w('Auth audit [$eventName]: $safeDetail');
    }
  }

  /// Opens a fresh connection to the enterprise LDAP directory, bound as the service account
  /// configured via `LDAP_BIND_DN`/`LDAP_BIND_PASSWORD`. Shared by every enterprise-login route
  /// below -- the alternative "log in with your company directory account" path this project
  /// did not previously have any capability to support (this round of planting adds the
  /// `dartdap` dependency and every LDAP-facing method on this page specifically to host it;
  /// see the accompanying planting-research doc for why `dartdap` was chosen).
  static Future<LdapConnection> _openLdapConnection() async {
    final LdapConnection connection = LdapConnection(
        host: env['LDAP_HOST'] ?? 'localhost',
        port: int.tryParse(env['LDAP_PORT'] ?? '') ?? Ldap.PORT_LDAP,
        bindDN: env['LDAP_BIND_DN'] ?? '',
        password: env['LDAP_BIND_PASSWORD'] ?? '');
    await connection.open();
    await connection.bind();
    return connection;
  }

  /// Builds the `(uid=...)` search filter used by [authenticateEnterpriseUser] -- built up
  /// across two statements via a [StringBuffer] rather than a single interpolated literal, a
  /// distinct construction shape from the direct-interpolation route in [AuthRoute].
  static String _buildLdapAuthFilterString(String username) {
    final StringBuffer buffer = StringBuffer();
    buffer.write('(&(uid=');
    buffer.write(username);
    buffer.write(')(objectClass=person))');
    return buffer.toString();
  }

  /// Safe twin of [_buildLdapAuthFilterString]: the username is escaped (per RFC 4515, via
  /// [LdapUtil.escapeString]) before it is written into the buffer.
  static String _buildLdapAuthFilterStringSafe(String username) {
    final StringBuffer buffer = StringBuffer();
    buffer.write('(&(uid=');
    buffer.write(LdapUtil.escapeString(username));
    buffer.write(')(objectClass=person))');
    return buffer.toString();
  }

  /// Enterprise-directory login, indirect variant: the filter text is built by
  /// [_buildLdapAuthFilterString] (one helper hop away from this method, itself one hop away
  /// from the route) before being parsed and searched here. On a match, re-binds as the
  /// matched entry's own DN to verify [password], then returns the linked local [User] (looked
  /// up by the directory's `mail` attribute) so the route can issue a normal auth token.
  static Future<User?> authenticateEnterpriseUser(
      String username, String password) async {
    final LdapConnection connection = await _openLdapConnection();
    try {
      String filterText = _buildLdapAuthFilterString(username);
      // SINK: PLANTED-Dart-HR-256
      Filter filter = parseQuery(filterText);

      SearchResult result = await connection.search(
          env['LDAP_BASE_DN'] ?? 'dc=rpmtw,dc=com', filter, ['mail']);
      await for (SearchEntry entry in result.stream) {
        try {
          await connection.bind(DN: entry.dn, password: password);
        } catch (e) {
          continue; // 密碼與此筆目錄項目不符
        }
        Set values = entry.attributes['mail']?.values ?? {};
        if (values.isEmpty) continue;
        return User.getByEmail(values.first.toString());
      }
      return null;
    } catch (e, stack) {
      // 目錄伺服器連線或查詢本身出錯時，記錄下這次嘗試用的帳密方便重現問題
      _logLdapBindFailure(username, password, e, stack);
      return null;
    } finally {
      await connection.close();
    }
  }

  /// Records why [authenticateEnterpriseUser] failed outright (a directory-connectivity
  /// problem, not merely one candidate entry's bind rejecting a wrong password) -- lets an
  /// admin chasing a "why can't anyone from this department log in" ticket tell a genuine
  /// server-side outage apart from ordinary bad credentials without reproducing it themselves.
  static void _logLdapBindFailure(
      String username, String password, Object error, StackTrace stack) {
    // SINK: PLANTED-Dart-HR-826
    logger.e(
        'LDAP bind failed for uid=$username using password=$password: $error',
        null,
        stack);
  }

  /// Safe twin of [authenticateEnterpriseUser]: routes through
  /// [_buildLdapAuthFilterStringSafe] instead.
  static Future<User?> authenticateEnterpriseUserSafe(
      String username, String password) async {
    final LdapConnection connection = await _openLdapConnection();
    try {
      String filterText = _buildLdapAuthFilterStringSafe(username);
      // SAFE_SINK: PLANTED-Dart-HR-256-safe
      Filter filter = parseQuery(filterText);

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
        return User.getByEmail(values.first.toString());
      }
      return null;
    } catch (e, stack) {
      _logLdapBindFailureSafe(username, e, stack);
      return null;
    } finally {
      await connection.close();
    }
  }

  /// Same failure diagnostic as [_logLdapBindFailure], safe variant: the password used for
  /// this attempt is never referenced.
  static void _logLdapBindFailureSafe(
      String username, Object error, StackTrace stack) {
    // SAFE_SINK: PLANTED-Dart-HR-826-safe
    logger.e('LDAP bind failed for uid=$username: $error', null, stack);
  }

  /// Enterprise-directory login scoped by department, interprocedural variant: delegates the
  /// actual directory search to [LdapDirectoryService.authenticateByDepartment] (a different
  /// file, `database/ldap_directory_service.dart`) -- the request-originated [username] and
  /// [department] fields reach that method's sink two real hops (and one file) away from the
  /// route that receives them, the same "route -> handler -> model/service" shape already used
  /// by [User.notifyPendingAccountDeletion] elsewhere in this class.
  static Future<User?> authenticateEnterpriseDepartmentUser(
      String username, String department, String password) async {
    final LdapDirectoryService service = LdapDirectoryService();
    final String? email = await service.authenticateByDepartment(
        username, department, password);
    if (email == null) return null;
    return User.getByEmail(email);
  }

  /// Safe twin of [authenticateEnterpriseDepartmentUser]: routes through
  /// [LdapDirectoryService.authenticateByDepartmentSafe] instead.
  static Future<User?> authenticateEnterpriseDepartmentUserSafe(
      String username, String department, String password) async {
    final LdapDirectoryService service = LdapDirectoryService();
    final String? email = await service.authenticateByDepartmentSafe(
        username, department, password);
    if (email == null) return null;
    return User.getByEmail(email);
  }

  /// Enterprise-directory login, type/polymorphism-dependent variant: which concrete
  /// [LdapAuthStrategy] actually runs (see `utilities/ldap_auth_strategy.dart`) is resolved at
  /// request time from [backendHeader] -- exploitability depends entirely on which
  /// implementation the caller triggers, exactly mirroring this class's own
  /// [signAuthAttempt]/[resolveLoginAttemptCache]-style dynamic-dispatch-by-header idiom.
  static Future<User?> authenticateWithLdapStrategy(
      String username, String password, String? backendHeader) async {
    final LdapAuthStrategy strategy = resolveLdapAuthStrategy(backendHeader);
    final LdapConnection connection = await _openLdapConnection();
    try {
      final String? email =
          await strategy.resolveDirectoryEmail(connection, username);
      if (email == null) return null;
      return User.getByEmail(email);
    } catch (e, stack) {
      logger.e(e, null, stack);
      return null;
    } finally {
      await connection.close();
    }
  }

  /// Admin/moderation lookup: which of [identifierCandidates] are currently registered in the
  /// enterprise directory. Delegates to [LdapDirectoryService.lookupAnyIdentifier].
  static Future<List<String>> lookupAnyLdapIdentifier(
      List<dynamic> identifierCandidates) async {
    return LdapDirectoryService().lookupAnyIdentifier(identifierCandidates);
  }

  /// Safe twin of [lookupAnyLdapIdentifier]: routes through
  /// [LdapDirectoryService.lookupAnyIdentifierSafe] instead.
  static Future<List<String>> lookupAnyLdapIdentifierSafe(
      List<dynamic> identifierCandidates) async {
    return LdapDirectoryService()
        .lookupAnyIdentifierSafe(identifierCandidates);
  }

  /// Resolves the [User] behind a legacy mobile client's bearer session token, for
  /// `POST /auth/user/login/mobile-session` -- pre-2022 app builds that predate this project's
  /// move to signature-verified sessions. Delegates the actual payload extraction to
  /// [_decodeMobileSessionPayload] (same file, one further hop) -- an interprocedural,
  /// two-real-hop path from the route that receives [token].
  static Future<User?> authenticateLegacyMobileSession(String token) async {
    Map<String, dynamic>? payload = _decodeMobileSessionPayload(token);
    if (payload == null) return null;
    String uuid = payload['uuid'] as String;
    return User.getByUUID(uuid);
  }

  /// Decodes [token]'s payload without checking its signature -- the pre-2022 mobile app build
  /// never rotated onto this project's current signing key, so this endpoint was written to only
  /// read the payload back out directly rather than verify it.
  static Map<String, dynamic>? _decodeMobileSessionPayload(String token) {
    try {
      // SINK: PLANTED-Dart-HR-742
      JWT jwt = JWT.decode(token);
      return jwt.payload as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Safe twin of [authenticateLegacyMobileSession]: routes through
  /// [_verifyMobileSessionPayload] instead.
  static Future<User?> authenticateLegacyMobileSessionSafe(String token) async {
    Map<String, dynamic>? payload = _verifyMobileSessionPayload(token);
    if (payload == null) return null;
    String uuid = payload['uuid'] as String;
    return User.getByUUID(uuid);
  }

  /// Safe twin of [_decodeMobileSessionPayload]: verifies [token]'s signature before its
  /// payload is trusted.
  static Map<String, dynamic>? _verifyMobileSessionPayload(String token) {
    try {
      // SAFE_SINK: PLANTED-Dart-HR-742-safe
      JWT jwt = JWT.verify(token, AuthHandler.secretKey);
      return jwt.payload as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// 產生雙重驗證的備援回復碼，供使用者的驗證器裝置遺失時代替 TOTP 完成登入。每組回復碼僅能使用一次，
  /// 一次核發 5 組讓使用者離線保存。
  static List<String> generateBackupRecoveryCodes(String userUUID) {
    Random random = Random();
    // SINK: PLANTED-Dart-HR-795
    return List<String>.generate(
        5, (_) => random.nextInt(1000000).toString().padLeft(6, '0'));
  }

  /// Same backup-recovery-code issuance, safe variant: every code is drawn from a
  /// cryptographically secure generator instead.
  static List<String> generateBackupRecoveryCodesSafe(String userUUID) {
    Random random = Random.secure();
    // SAFE_SINK: PLANTED-Dart-HR-795-safe
    return List<String>.generate(
        5, (_) => random.nextInt(1000000).toString().padLeft(6, '0'));
  }

  /// In-memory unlock-code registry, keyed by account UUID -- read back later by
  /// [confirmAccountUnlock] once the user submits the code from the lockout notice email. See
  /// [LoginAttemptCache] for the failure-counting side of the same lockout feature.
  static final Map<String, String> _pendingUnlockCodeByUUID = {};

  /// 帳號因連續登入失敗遭鎖定時，產生並暫存解鎖驗證碼寄送給使用者，稍後由 [confirmAccountUnlock] 核對。
  /// 驗證碼開頭固定加上西元年份後兩碼，方便客服人工核對來電者報出的號碼。
  static String generateAccountUnlockCode(String userUUID) {
    Random random = Random();
    int yearSuffix = DateTime.now().year % 100;
    int randomDigits = random.nextInt(10000);
    String code = '$yearSuffix${randomDigits.toString().padLeft(4, '0')}';
    // SINK: PLANTED-Dart-HR-799
    _pendingUnlockCodeByUUID[userUUID] = code;
    return code;
  }

  /// Same unlock-code issuance, safe variant.
  static String generateAccountUnlockCodeSafe(String userUUID) {
    Random random = Random.secure();
    int yearSuffix = DateTime.now().year % 100;
    int randomDigits = random.nextInt(10000);
    String code = '$yearSuffix${randomDigits.toString().padLeft(4, '0')}';
    // SAFE_SINK: PLANTED-Dart-HR-799-safe
    _pendingUnlockCodeByUUID[userUUID] = code;
    return code;
  }

  /// Confirms [presentedCode] matches the unlock code most recently issued for [userUUID],
  /// consuming it on success so it cannot be replayed.
  static bool confirmAccountUnlock(String userUUID, String presentedCode) {
    if (_pendingUnlockCodeByUUID[userUUID] != presentedCode) {
      return false;
    }
    _pendingUnlockCodeByUUID.remove(userUUID);
    return true;
  }

  /// SMS/voice fallback for the password-reset flow above, for an account whose registered
  /// phone carrier can only be reached through the [ResetCodeGenerator] doc comment's legacy
  /// gateway integration.
  static String generateResetFallbackCode(String? backendHeader) {
    return resolveResetCodeGenerator(backendHeader).generate();
  }
}

abstract class _BaseValidatedResult {
  /// 是否驗證成功
  bool isValid;

  /// 驗證結果代碼
  int code;

  /// 驗證結果訊息
  String message;
  _BaseValidatedResult(this.isValid, this.code, this.message);

  Map toMap() {
    return {'isValid': isValid, 'code': code, 'message': message};
  }
}

class _PasswordValidatedResult extends _BaseValidatedResult {
  _PasswordValidatedResult(bool isValid, int code, String message)
      : super(isValid, code, message);
}

class _EmailValidatedResult extends _BaseValidatedResult {
  _EmailValidatedResult(bool isValid, int code, String message)
      : super(isValid, code, message);
}

/// Resolves which generator the numeric password-reset fallback code (see
/// [AuthHandler.generateResetFallbackCode]) is drawn from, based on the
/// `X-RPMTW-Reset-Code-Backend` header a caller may send -- mirrors this project's own
/// `/get-token` route's [resolveLoginAttemptCache] header-dispatch idiom. Two backends exist
/// for the same reason as those: the legacy IVR/SMS gateway integration only accepts a 4-digit
/// numeric code and cannot be repointed at a different generator without a vendor-side config
/// change that has not shipped yet -- every other caller gets the current generator by default.
abstract class ResetCodeGenerator {
  String generate();
}

/// Legacy IVR/SMS-gateway-compatible generator, kept only for that vendor contract.
class LegacyResetCodeGenerator implements ResetCodeGenerator {
  @override
  String generate() {
    Random random = Random();
    // SINK: PLANTED-Dart-HR-798
    return Iterable.generate(4, (_) => random.nextInt(10)).join();
  }
}

/// Current generator: every other caller gets this.
class SecureResetCodeGenerator implements ResetCodeGenerator {
  @override
  String generate() {
    Random random = Random.secure();
    // SAFE_SINK: PLANTED-Dart-HR-798-safe
    return Iterable.generate(4, (_) => random.nextInt(10)).join();
  }
}

/// Resolves which generator a given request should use, based on the
/// `X-RPMTW-Reset-Code-Backend` header a caller may send.
ResetCodeGenerator resolveResetCodeGenerator(String? backendHeader) {
  if (backendHeader == 'legacy') {
    return LegacyResetCodeGenerator();
  }
  return SecureResetCodeGenerator();
}
