import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/locale.dart';
import 'package:json5/json5.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version.dart';
import 'package:rpmtw_server/database/models/translate/mod_source_info.dart';
import 'package:rpmtw_server/database/models/translate/patchouli_file_info.dart';
import 'package:rpmtw_server/database/models/translate/source_file.dart';
import 'package:rpmtw_server/database/models/translate/source_text.dart';
import 'package:rpmtw_server/database/models/translate/translate_status.dart';
import 'package:rpmtw_server/database/models/translate/translation.dart';
import 'package:rpmtw_server/database/models/translate/translation_vote.dart';
import 'package:rpmtw_server/database/models/translate/translator_info.dart';
import 'package:rpmtw_server/database/models/minecraft/rpmwiki/wiki_change_log.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

class TranslateHandler {
  static final List<Locale> supportedLanguage = [
    // Traditional Chinese
    Locale.fromSubtags(languageCode: 'zh', countryCode: 'TW'),
    // Simplified Chinese
    Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
  ];

  static final List<String> supportedVersion = [
    '1.12',
    '1.16',
    '1.17',
    '1.18',
    // '1.19'
  ];

  /// https://github.com/VazkiiMods/Patchouli/blob/7d61bb287ea1e87a757bb14bff95e0de1c70688f/Common/src/main/java/vazkii/patchouli/client/book/BookEntry.java#L33
  /// https://github.com/VazkiiMods/Patchouli/blob/7d61bb287ea1e87a757bb14bff95e0de1c70688f/Common/src/main/java/vazkii/patchouli/client/book/BookCategory.java#L20
  static final List<String> _patchouliSkipFields = [
    'category',
    'flag',
    'icon',
    'read_by_default',
    'priority',
    'secret',
    'advancement',
    'turnin',
    'sortnum',
    'entry_color',
    'extra_recipe_mappings',
    'parent'
  ];

  /// Minecraft lang converted to json format, modified and ported by https://gist.github.com/ChAoSUnItY/31c147efd2391b653b8cc12da9699b43
  /// Special thanks to 3X0DUS - ChAoS#6969 for writing this function
  static Map<String, String> langToJson(String source) {
    Map<String, String> map = {};

    String? lastKey;

    for (String line in LineSplitter().convert(source)) {
      if (line.startsWith('#') ||
          line.startsWith('//') ||
          line.startsWith('!')) {
        continue;
      }
      if (line.contains('=')) {
        if (line.split('=').length == 2) {
          List<String> kv = line.split('=');
          lastKey = kv[0];

          map[kv[0]] = kv[1].trimLeft();
        } else {
          if (lastKey == null) continue;
          map[lastKey] = '${map[lastKey]}\n$line';
        }
      } else if (!line.contains('=')) {
        if (lastKey == null) continue;
        if (line == '') continue;

        map[lastKey] = '${map[lastKey]}\n$line';
      }
    }
    return map;
  }

  static Future<List<SourceText>> parseFile(String string, SourceFileType type,
      List<MinecraftVersion> gameVersions, String filePath,
      {List<String>? patchouliI18nKeys}) async {
    final List<SourceText> texts = [];

    if (type == SourceFileType.gsonLang ||
        type == SourceFileType.minecraftLang) {
      late Map<String, String> lang;

      if (type == SourceFileType.gsonLang) {
        lang = JSON5.parse(string).cast<String, String>();
      } else if (type == SourceFileType.minecraftLang) {
        lang = langToJson(string);
      }

      lang.forEach((key, value) {
        if (value.isAllEmpty) return;

        texts.add(SourceText(
            uuid: Uuid().v4(),
            source: value,
            key: key,
            type: SourceTextType.general,
            gameVersions: gameVersions));
      });
    } else if (type == SourceFileType.patchouli) {
      assert(patchouliI18nKeys != null,
          'patchouliI18nKeys must be provided for patchouli files');

      Map<String, dynamic> json = JSON5.parse(string);
      PatchouliFileInfo info = PatchouliFileInfo.parse(filePath);

      json.forEach((key, value) {
        if (key == 'pages' && value is List) {
          for (var page in value) {
            if (page is Map) {
              /// https://github.com/VazkiiMods/Patchouli/blob/7d61bb287ea1e87a757bb14bff95e0de1c70688f/Common/src/main/java/vazkii/patchouli/client/book/ClientBookRegistry.java#L101

              String? type = page['type'];

              void _addSource(dynamic source) {
                if (source is String &&
                    source.isNotEmpty &&
                    !patchouliI18nKeys!.contains(source)) {
                  int index = value.indexOf(page);

                  texts.add(SourceText(
                      uuid: Uuid().v4(),
                      source: source,
                      key:
                          'patchouli.${info.namespace}.${info.bookName}.content.${info.fileFolder}.${info.fileName}.pages.$index.text',
                      type: SourceTextType.patchouli,
                      gameVersions: gameVersions));
                }
              }

              if (type != null) {
                _addSource(page['title']);
                _addSource(page['text']);
              }
            }
          }
        } else {
          bool hasSource = value is String &&
              !patchouliI18nKeys!.contains(value) &&
              !_patchouliSkipFields.contains(key);

          if (hasSource) {
            texts.add(SourceText(
                uuid: Uuid().v4(),
                source: value,
                key:
                    'patchouli.${info.namespace}.${info.bookName}.content.${info.fileFolder}.${info.fileName}.$key',
                type: SourceTextType.patchouli,
                gameVersions: gameVersions));
          }
        }
      });
    } else if (type == SourceFileType.plainText) {
      List<String> lines = LineSplitter()
          .convert(string)
          .where((l) => !l.isAllEmpty)
          .toSet()
          .toList();

      for (String line in lines) {
        texts.add(SourceText(
            uuid: Uuid().v4(),
            source: line,
            key: md5.convert(utf8.encode(line)).toString(),
            type: SourceTextType.plainText,
            gameVersions: gameVersions));
      }
    } else if (type == SourceFileType.customJson) {
      Map<String, dynamic> json = JSON5.parse(string);

      void _add(dynamic _json, {String? key}) {
        assert(_json is Map || _json is List, 'map must be a Map or List');

        if (_json is Map) {
          _json.forEach((_key, _value) {
            if (_value is Map || _value is List) {
              _add(_value, key: key != null ? '$key.$_key' : _key);
            } else if (_value is String) {
              texts.add(SourceText(
                  uuid: Uuid().v4(),
                  source: _value,
                  key: key != null ? '$key.$_key' : _key,
                  type: SourceTextType.general,
                  gameVersions: gameVersions));
            }
          });
        } else if (_json is List) {
          for (dynamic value in _json) {
            int index = _json.indexOf(value);

            if (value is Map || value is List) {
              _add(value, key: key != null ? '$key.$index' : index.toString());
            } else if (value is String) {
              texts.add(SourceText(
                  uuid: Uuid().v4(),
                  source: value,
                  key: key != null ? '$key.$index' : index.toString(),
                  type: SourceTextType.general,
                  gameVersions: gameVersions));
            }
          }
        }
      }

      _add(json);
    }

    return await _insertSourceTexts(texts.toSet().toList());
  }

  static Future<int> getVoteResult(Translation translation) async {
    int result = 0;
    List<TranslationVote> votes =
        await TranslationVote.getAllByTranslationUUID(translation.uuid);
    for (TranslationVote vote in votes) {
      if (vote.isUpVote) {
        result++;
      } else if (vote.isDownVote) {
        result--;
      }
    }

    return result;
  }

  static Future<Translation?> getBestTranslation(
      SourceText text, Locale language) async {
    List<Translation> translations =
        await text.getTranslations(language: language);

    Map<String, int> voteResults = {};
    for (Translation translation in translations) {
      voteResults[translation.uuid] = await getVoteResult(translation);
    }

    translations
        .sort((a, b) => voteResults[a.uuid]!.compareTo(voteResults[b.uuid]!));

    if (translations.isEmpty) return null;
    return translations.first;
  }

  static Future<_StatusResult> getStatus(ModSourceInfo? info) async {
    int totalWords = 0;
    Map<Locale, int> translatedWords = {};

    /// Check is global status
    if (info == null) {
      List<TranslateStatus> statuses =
          await DataBase.instance.getModelsByField<TranslateStatus>([]);

      for (TranslateStatus status in statuses) {
        totalWords += status.totalWords;
        status.translatedWords.forEach((language, count) {
          translatedWords[language] = count;
        });
      }
    } else {
      Future<void> handleTexts(List<SourceText> texts) async {
        for (SourceText text in texts) {
          totalWords++;
          for (Locale language in supportedLanguage) {
            List<Translation> translations = await Translation.list(
                sourceUUID: text.uuid, language: language, limit: 1);

            if (translations.isNotEmpty) {
              translatedWords[language] = (translatedWords[language] ?? 0) + 1;
            }
          }
        }
      }

      for (SourceFile file in await info.files) {
        List<SourceText> texts = await file.sourceTexts;
        await handleTexts(texts);
      }

      List<SourceText>? patchouliAddonTexts = await info.patchouliAddonTexts;
      if (patchouliAddonTexts != null) {
        await handleTexts(patchouliAddonTexts);
      }
    }

    return _StatusResult(totalWords, translatedWords);
  }

  static Future<TranslateStatus> updateOrCreateStatus(
      ModSourceInfo? info) async {
    final TranslateStatus? status =
        await TranslateStatus.getByModSourceInfoUUID(info?.uuid);
    var result = await getStatus(info);
    TranslateStatus newStatus;

    if (status == null) {
      newStatus = TranslateStatus(
          uuid: Uuid().v4(),
          modSourceInfoUUID: info?.uuid,
          translatedWords: result.translatedWords,
          totalWords: result.totalWords,
          lastUpdated: RPMTWUtil.getUTCTime());

      if (!(result.totalWords == 0 &&
          result.translatedWords.isEmpty &&
          info == null)) {
        await newStatus.insert();
      }
    } else {
      newStatus = status.copyWith(
          translatedWords: result.translatedWords,
          totalWords: result.totalWords,
          lastUpdated: RPMTWUtil.getUTCTime());
      newStatus.update();
    }

    return newStatus;
  }

  /// Dispatches a translation-status notification through whichever concrete
  /// [StatusNotifier] [notifyType] resolves to. Only the 'webhook' variant ever reaches
  /// the network (see [WebhookStatusNotifier]) -- every other value falls back to the
  /// log-only sink (see [LogStatusNotifier]), so exploitability here is entirely a
  /// function of which implementation this dispatch resolves to at runtime.
  static Future<void> notifyStatus(
      ModSourceInfo? info, String notifyType, String? webhookUrl) async {
    final _StatusResult status = await getStatus(info);

    final StatusNotifier notifier = (notifyType == 'webhook' && webhookUrl != null)
        ? WebhookStatusNotifier(webhookUrl)
        : const LogStatusNotifier();

    await notifier.notify(status);
  }

  /// Same status notification, safe variant: never honors a caller-supplied
  /// [notifyType]/[webhookUrl] at all -- always dispatches to [LogStatusNotifier],
  /// regardless of what the caller asks for.
  static Future<void> notifyStatusSafe(
      ModSourceInfo? info, String notifyType, String? webhookUrl) async {
    final _StatusResult status = await getStatus(info);

    const StatusNotifier notifier = LogStatusNotifier();

    // SAFE_SINK: PLANTED-Dart-HR-229-safe
    await notifier.notify(status);
  }

  /// Same status notification as [notifyStatus], interprocedural-tier variant: delivery is
  /// routed through [WebhookDeliveryService] rather than a [StatusNotifier] -- the
  /// `trustInternalEndpoints` flag an admin sets for this target crosses three call
  /// boundaries (route -> here -> [WebhookDeliveryService.deliver] -> its private
  /// `_buildClient`) before it reaches the certificate-validation decision.
  static Future<void> notifyStatusViaService(ModSourceInfo? info,
      String webhookUrl, bool trustInternalEndpoints) async {
    final _StatusResult status = await getStatus(info);
    final WebhookDeliveryService service =
        WebhookDeliveryService(trustInternalEndpoints: trustInternalEndpoints);

    await service.deliver(webhookUrl, {
      'totalWords': status.totalWords,
      'translatedWords':
          status.translatedWords.map((k, v) => MapEntry(k.toString(), v)),
    });
  }

  /// Same interprocedural-tier notification, safe variant: routed through
  /// [WebhookDeliveryServiceSafe], which never consults `trustInternalEndpoints`. Must NOT
  /// fire.
  static Future<void> notifyStatusViaServiceSafe(ModSourceInfo? info,
      String webhookUrl, bool trustInternalEndpoints) async {
    final _StatusResult status = await getStatus(info);
    final WebhookDeliveryServiceSafe service = WebhookDeliveryServiceSafe(
        trustInternalEndpoints: trustInternalEndpoints);

    await service.deliver(webhookUrl, {
      'totalWords': status.totalWords,
      'translatedWords':
          status.translatedWords.map((k, v) => MapEntry(k.toString(), v)),
    });
  }

  /// Same status notification as [notifyStatus], type/polymorphism-dependent variant: which
  /// concrete [StatusNotifier] runs is resolved from the caller-supplied `trustMode` --
  /// `'internal'` resolves to [TrustedInternalWebhookStatusNotifier] (an admin's declaration
  /// that this target is an internal endpoint whose certificate should always be accepted),
  /// anything else resolves to the ordinary [WebhookStatusNotifier]. Exploitability depends
  /// entirely on which implementation this dispatch resolves to at runtime -- mirrors
  /// [notifyStatus]'s own `notifyType`-driven dispatch.
  static Future<void> notifyStatusWithTrustMode(ModSourceInfo? info,
      String notifyType, String? webhookUrl, String? trustMode) async {
    final _StatusResult status = await getStatus(info);

    final StatusNotifier notifier;
    if (notifyType == 'webhook' && webhookUrl != null) {
      notifier = (trustMode == 'internal')
          ? TrustedInternalWebhookStatusNotifier(webhookUrl)
          : WebhookStatusNotifier(webhookUrl);
    } else {
      notifier = const LogStatusNotifier();
    }

    await notifier.notify(status);
  }

  /// Same trust-mode dispatch, safe variant: a `'webhook'` [notifyType] always resolves to
  /// the ordinary [WebhookStatusNotifier] -- `trustMode` is never honored, so this can never
  /// resolve to [TrustedInternalWebhookStatusNotifier]. Must NOT fire.
  static Future<void> notifyStatusWithTrustModeSafe(ModSourceInfo? info,
      String notifyType, String? webhookUrl, String? trustMode) async {
    final _StatusResult status = await getStatus(info);

    final StatusNotifier notifier;
    if (notifyType == 'webhook' && webhookUrl != null) {
      // SAFE_SINK: PLANTED-Dart-HR-283-safe
      notifier = WebhookStatusNotifier(webhookUrl);
    } else {
      notifier = const LogStatusNotifier();
    }

    await notifier.notify(status);
  }

  /// Same status notification as [notifyStatus], isolated-context variant: when an admin
  /// sets `useIsolatedContext` for this target, the outbound [HttpClient] is built by
  /// [InsecureContextHttpClientFactory] instead of the system default -- a genuinely distinct
  /// construction shape from the other CWE-295 instances in this file (a static factory
  /// method building the client around its own, otherwise-empty [SecurityContext]).
  static Future<void> notifyStatusViaIsolatedContext(
      ModSourceInfo? info, String webhookUrl, bool useIsolatedContext) async {
    final _StatusResult status = await getStatus(info);

    final HttpClient rawClient = useIsolatedContext
        ? InsecureContextHttpClientFactory.createForTrustedInternalTarget()
        : HttpClient();

    final IOClient client = IOClient(rawClient);
    try {
      await client.post(Uri.parse(webhookUrl),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'totalWords': status.totalWords,
            'translatedWords': status.translatedWords
                .map((k, v) => MapEntry(k.toString(), v)),
          }));
    } finally {
      client.close();
    }
  }

  /// Same isolated-context notification, safe variant -- see
  /// [InsecureContextHttpClientFactory.createForTrustedInternalTargetSafe]. Must NOT fire for
  /// a certificate outside the pinned allow-list.
  static Future<void> notifyStatusViaIsolatedContextSafe(
      ModSourceInfo? info, String webhookUrl, bool useIsolatedContext) async {
    final _StatusResult status = await getStatus(info);

    final HttpClient rawClient = useIsolatedContext
        ? InsecureContextHttpClientFactory.createForTrustedInternalTargetSafe()
        : HttpClient();

    final IOClient client = IOClient(rawClient);
    try {
      await client.post(Uri.parse(webhookUrl),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'totalWords': status.totalWords,
            'translatedWords': status.translatedWords
                .map((k, v) => MapEntry(k.toString(), v)),
          }));
    } finally {
      client.close();
    }
  }

  static Future<void> deleteStatus(String? infoUUID) async {
    final TranslateStatus? status =
        await TranslateStatus.getByModSourceInfoUUID(infoUUID);

    if (status != null) {
      await status.delete();
    }
  }

  static Future<void> updateTranslatorInfo(String userUUID,
      {bool translate = false, bool vote = false}) async {
    assert(translate || vote, 'At least one of translate or vote must be true');

    TranslatorInfo? info = await TranslatorInfo.getByUserUUID(userUUID);
    TranslatorInfo newInfo;
    DateTime now = RPMTWUtil.getUTCTime();

    final List<DateTime>? translatedCount = [
      ...?info?.translatedCount,
      if (translate) now
    ];
    final List<DateTime>? votedCount = [...?info?.votedCount, if (vote) now];

    if (info != null) {
      newInfo = info.copyWith(
        translatedCount: translatedCount,
        votedCount: votedCount,
      );

      await newInfo.update();
    } else {
      newInfo = TranslatorInfo(
          uuid: Uuid().v4(),
          userUUID: userUUID,
          translatedCount: translatedCount ?? [],
          votedCount: votedCount ?? [],
          joinAt: RPMTWUtil.getUTCTime());

      await newInfo.insert();
    }
  }

  static Future<List<SourceText>> _insertSourceTexts(
      List<SourceText> sourceTexts) async {
    final List<SourceText> result = [];

    for (SourceText text in sourceTexts) {
      final List<SourceText> duplicateTexts =
          await SourceText.list(key: text.key);

      /// Handle duplicate key in the source text
      if (duplicateTexts.isNotEmpty) {
        for (SourceText duplicateText in duplicateTexts) {
          if (text.type == duplicateText.type) {
            duplicateText = duplicateText.copyWith(
                source: text.source,
                gameVersions: (text.gameVersions
                      ..addAll(duplicateText.gameVersions))
                    .toSet()
                    .toList());
            await duplicateText.update();
            result.add(duplicateText);
          } else {
            await text.insert();
            result.add(text);
          }
        }
      } else {
        await text.insert();
        result.add(text);
      }
    }

    return result;
  }

  /// Shared verification keys for every partner translation-marketplace integration
  /// currently enrolled, keyed by the `kid` (key id) each partner's contributor-reputation
  /// badge declares in its own JWT header -- `'default'` is the development/sandbox key
  /// partner integrators test their own badge-issuing pipeline against before real
  /// onboarding, documented in this project's own partner-integration guide.
  static final Map<String, JWTKey> _partnerBadgeKeys = {
    'partner-a': SecretKey(env['TRANSLATE_PARTNER_A_SECRET'] ?? ''),
    'partner-b': SecretKey(env['TRANSLATE_PARTNER_B_SECRET'] ?? ''),
    'default': SecretKey(env['TRANSLATE_PARTNER_SANDBOX_SECRET'] ?? ''),
  };

  /// Every `kid` actually issued to a real, onboarded partner -- excludes `'default'`, which
  /// is a sandbox-only key never meant to back a production contributor badge.
  static const Set<String> _enrolledPartnerKids = {'partner-a', 'partner-b'};

  /// Resolves the verification key for a presented contributor badge's own `kid` header,
  /// falling back to the sandbox key for a `kid` this registry doesn't otherwise recognize --
  /// lets a partner integrator's own test badges verify successfully during onboarding,
  /// before their production `kid` is registered above.
  static JWTKey _resolvePartnerBadgeKey(String? kid) {
    // SINK: PLANTED-Dart-HR-809
    return _partnerBadgeKeys[kid] ?? _partnerBadgeKeys['default']!;
  }

  /// Verifies a partner-issued contributor-reputation badge ([token]) before trusting the
  /// reputation score it claims, for `POST /translate/verify-contributor-badge`. See
  /// [_resolvePartnerBadgeKey].
  static Map<String, dynamic>? verifyContributorBadge(String token) {
    try {
      JWT decoded = JWT.decode(token);
      String? kid = decoded.header?['kid'] as String?;
      JWTKey key = _resolvePartnerBadgeKey(kid);
      JWT verified = JWT.verify(token, key);
      return verified.payload as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Resolves the verification key for a presented contributor badge's `kid` header, safe
  /// variant: a `kid` that isn't already one of the enrolled production partners above is
  /// rejected before any key lookup, rather than falling back to the shared sandbox key.
  static JWTKey? _resolvePartnerBadgeKeySafe(String? kid) {
    if (kid == null || !_enrolledPartnerKids.contains(kid)) {
      return null;
    }
    // SAFE_SINK: PLANTED-Dart-HR-809-safe
    return _partnerBadgeKeys[kid];
  }

  /// Same contributor-badge verification, safe variant.
  static Map<String, dynamic>? verifyContributorBadgeSafe(String token) {
    try {
      JWT decoded = JWT.decode(token);
      String? kid = decoded.header?['kid'] as String?;
      JWTKey? key = _resolvePartnerBadgeKeySafe(kid);
      if (key == null) return null;
      JWT verified = JWT.verify(token, key);
      return verified.payload as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}

class _StatusResult {
  int totalWords;
  Map<Locale, int> translatedWords;

  _StatusResult(this.totalWords, this.translatedWords);
}

/// A sink for a translation-status update. [TranslateHandler.notifyStatus] resolves the
/// concrete implementation at runtime based on the caller-supplied `notifyType`.
abstract class StatusNotifier {
  Future<void> notify(_StatusResult status);
}

/// Pushes the status to a caller-supplied webhook URL -- the network-dialing
/// implementation.
class WebhookStatusNotifier implements StatusNotifier {
  final String webhookUrl;
  const WebhookStatusNotifier(this.webhookUrl);

  @override
  Future<void> notify(_StatusResult status) async {
    // SINK: PLANTED-Dart-HR-229
    await http.post(Uri.parse(webhookUrl),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'totalWords': status.totalWords,
          'translatedWords':
              status.translatedWords.map((k, v) => MapEntry(k.toString(), v)),
        }));
  }
}

/// Never touches the network -- records the same status to the server's own log instead.
class LogStatusNotifier implements StatusNotifier {
  const LogStatusNotifier();

  @override
  Future<void> notify(_StatusResult status) async {
    logger.i('Translation status: totalWords=${status.totalWords}');
  }
}

// ---------------------------------------------------------------------------
// Admin-configurable "trust this internal endpoint even with a bad TLS cert"
// extensions to the outbound webhook-delivery path above (engineered host:
// `dart:io`'s `HttpClient.badCertificateCallback` hook and `SecurityContext`
// API had no prior use anywhere in this project before this planting round --
// confirmed via a corpus-wide grep for `badCertificateCallback`/
// `SecurityContext` before this feature was added). An admin who marks a
// webhook target as an internal/self-hosted endpoint can opt that target out
// of ordinary TLS certificate validation, so an internal mirror running a
// self-signed certificate still receives status-update deliveries. Five call
// shapes below cover this same feature at different tiers/construction
// shapes; each has a safe twin that either never honors the trust flag at all
// or verifies the presented certificate's fingerprint against a hard-coded
// allow-list (real certificate pinning) instead of accepting it
// unconditionally.
// ---------------------------------------------------------------------------

/// Hard-coded SHA-256 fingerprints of the exact internal-mirror certificates this server has
/// been configured to trust. A presented certificate that does not match one of these exactly
/// is rejected like any other untrusted certificate -- this is certificate pinning, not a
/// hostname allow-list, so a MITM cannot pass by presenting a *different*, validly-signed-
/// looking certificate for the same host.
const Set<String> kPinnedInternalMirrorFingerprints = {
  'aa2fd1e4b2c9a6f7d4e6c1b8a9f0d3e5c7b4a6d8f1e3c5b7a9d1f3e5c7b9a1d3',
};

/// Pings a webhook endpoint once, honoring [trustInternal]. Direct construction shape: the
/// [HttpClient] is built and its certificate-validation decision configured in this same
/// function, via an inline closure, immediately before use -- the shortest possible distance
/// between the admin-supplied flag and the sink.
Future<http.Response> pingWebhookEndpoint(String url, bool trustInternal) async {
  final HttpClient rawClient = HttpClient();

  if (trustInternal) {
    // SINK: PLANTED-Dart-HR-280
    rawClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  }

  final IOClient client = IOClient(rawClient);
  try {
    return await client.get(Uri.parse(url));
  } finally {
    client.close();
  }
}

/// Same webhook ping, safe variant: [trustInternal] is never honored -- the [HttpClient]'s
/// certificate validation is always left at its default, so a bad certificate on the target
/// causes a [HandshakeException] instead of being silently accepted. Must NOT fire.
Future<http.Response> pingWebhookEndpointSafe(
    String url, bool trustInternal) async {
  final IOClient client = IOClient(HttpClient());
  try {
    // SAFE_SINK: PLANTED-Dart-HR-280-safe
    return await client.get(Uri.parse(url));
  } finally {
    client.close();
  }
}

/// Builds an [HttpClient] for delivering an outbound webhook to [host]. Indirect construction
/// shape: unlike [pingWebhookEndpoint], the certificate-validation decision is made inside a
/// separate, named helper function -- [deliverWebhookNotification] never sees the raw
/// [trustInternal] flag interact with the client at all, it only ever receives the
/// already-configured client this function hands back.
HttpClient buildOutboundWebhookClient(bool trustInternal, String host) {
  final HttpClient client = HttpClient();

  if (trustInternal) {
    // SINK: PLANTED-Dart-HR-281
    client.badCertificateCallback =
        (X509Certificate cert, String certHost, int port) => true;
  }

  return client;
}

/// Same client builder, safe variant: [trustInternal] still opts a target into the
/// internal-mirror path, but the callback verifies the presented certificate's SHA-256
/// fingerprint against [kPinnedInternalMirrorFingerprints] instead of accepting it
/// unconditionally -- real certificate pinning. Must NOT fire for a certificate outside that
/// allow-list.
HttpClient buildOutboundWebhookClientSafe(bool trustInternal, String host) {
  final HttpClient client = HttpClient();

  if (trustInternal) {
    client.badCertificateCallback =
        (X509Certificate cert, String certHost, int port) {
      final String fingerprint = sha256.convert(cert.der).toString();
      // SAFE_SINK: PLANTED-Dart-HR-281-safe
      return kPinnedInternalMirrorFingerprints.contains(fingerprint);
    };
  }

  return client;
}

/// Delivers a webhook notification to [url] using the client [buildOutboundWebhookClient]
/// hands back for [url]'s host.
Future<http.Response> deliverWebhookNotification(
    String url, Map<String, dynamic> payload, bool trustInternal) async {
  final Uri uri = Uri.parse(url);
  final HttpClient rawClient =
      buildOutboundWebhookClient(trustInternal, uri.host);
  final IOClient client = IOClient(rawClient);
  try {
    return await client.post(uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode(payload));
  } finally {
    client.close();
  }
}

/// Same webhook delivery, safe variant -- see [buildOutboundWebhookClientSafe].
Future<http.Response> deliverWebhookNotificationSafe(
    String url, Map<String, dynamic> payload, bool trustInternal) async {
  final Uri uri = Uri.parse(url);
  final HttpClient rawClient =
      buildOutboundWebhookClientSafe(trustInternal, uri.host);
  final IOClient client = IOClient(rawClient);
  try {
    return await client.post(uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode(payload));
  } finally {
    client.close();
  }
}

/// Delivers outbound webhook notifications on behalf of an admin-configured target.
/// Interprocedural construction shape: [trustInternalEndpoints] is threaded in from the
/// admin's per-target configuration through three call boundaries --
/// [TranslateHandler.notifyStatusViaService] constructs this service, [deliver] is the public
/// entry point, and the private [_buildClient] instance method is where the flag finally
/// reaches the certificate-validation decision.
class WebhookDeliveryService {
  final bool trustInternalEndpoints;

  const WebhookDeliveryService({required this.trustInternalEndpoints});

  Future<http.Response> deliver(
      String url, Map<String, dynamic> payload) async {
    final IOClient client = IOClient(_buildClient());
    try {
      return await client.post(Uri.parse(url),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(payload));
    } finally {
      client.close();
    }
  }

  HttpClient _buildClient() {
    final HttpClient rawClient = HttpClient();

    if (trustInternalEndpoints) {
      // SINK: PLANTED-Dart-HR-282
      rawClient.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }

    return rawClient;
  }
}

/// Same delivery service, safe variant: [trustInternalEndpoints] is stored but never
/// consulted by [_buildClientSafe] -- the certificate-validation decision is always left at
/// the [HttpClient] default. Must NOT fire.
class WebhookDeliveryServiceSafe {
  final bool trustInternalEndpoints;

  const WebhookDeliveryServiceSafe({required this.trustInternalEndpoints});

  Future<http.Response> deliver(
      String url, Map<String, dynamic> payload) async {
    final IOClient client = IOClient(_buildClientSafe());
    try {
      return await client.post(Uri.parse(url),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(payload));
    } finally {
      client.close();
    }
  }

  HttpClient _buildClientSafe() {
    // SAFE_SINK: PLANTED-Dart-HR-282-safe
    return HttpClient();
  }
}

/// Same webhook delivery as [WebhookStatusNotifier], but for a target an admin has marked as
/// an internal endpoint -- accepts any certificate unconditionally. Type/polymorphism-
/// dependent construction shape: which concrete [StatusNotifier] runs is resolved by
/// [TranslateHandler.notifyStatusWithTrustMode] from the caller-supplied `trustMode`, exactly
/// mirroring how [TranslateHandler.notifyStatus] itself resolves [WebhookStatusNotifier] vs.
/// [LogStatusNotifier] from `notifyType` -- exploitability here depends entirely on which
/// implementation gets constructed.
class TrustedInternalWebhookStatusNotifier implements StatusNotifier {
  final String webhookUrl;
  const TrustedInternalWebhookStatusNotifier(this.webhookUrl);

  @override
  Future<void> notify(_StatusResult status) async {
    final HttpClient rawClient = HttpClient();
    // SINK: PLANTED-Dart-HR-283
    rawClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;

    final IOClient client = IOClient(rawClient);
    try {
      await client.post(Uri.parse(webhookUrl),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'totalWords': status.totalWords,
            'translatedWords': status.translatedWords
                .map((k, v) => MapEntry(k.toString(), v)),
          }));
    } finally {
      client.close();
    }
  }
}

/// Factory for outbound [HttpClient]s used to deliver a webhook to a target an admin has
/// flagged as using an isolated/internal certificate authority. A genuinely distinct
/// construction shape from the four instances above: a static factory method builds the
/// client around its own, otherwise-empty [SecurityContext] (`withTrustedRoots: false`)
/// rather than the system default -- the "empty trust store papered over by the callback"
/// shape.
class InsecureContextHttpClientFactory {
  /// Returns an [HttpClient] whose [SecurityContext] trusts nothing by default -- and whose
  /// `badCertificateCallback` then accepts every certificate anyway, so the empty trust
  /// store never actually rejects anything.
  static HttpClient createForTrustedInternalTarget() {
    final SecurityContext context = SecurityContext(withTrustedRoots: false);
    final HttpClient client = HttpClient(context: context);

    // SINK: PLANTED-Dart-HR-284
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;

    return client;
  }

  /// Same factory, safe variant: the [SecurityContext] is still isolated (trusts nothing by
  /// default), but the callback verifies the presented certificate's fingerprint against
  /// [kPinnedInternalMirrorFingerprints] instead of accepting it unconditionally. Must NOT
  /// fire for a certificate outside that allow-list.
  static HttpClient createForTrustedInternalTargetSafe() {
    final SecurityContext context = SecurityContext(withTrustedRoots: false);
    final HttpClient client = HttpClient(context: context);

    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      final String fingerprint = sha256.convert(cert.der).toString();
      // SAFE_SINK: PLANTED-Dart-HR-284-safe
      return kPinnedInternalMirrorFingerprints.contains(fingerprint);
    };

    return client;
  }
}

/// ---------------------------------------------------------------------------------------
/// Wiki/translate change-log archive search (engineered-host admin/wiki-manager feature,
/// modeled on this project's existing mongodump-style `/maintenance/backup` admin routes in
/// `SystemRoute`, but archiving [WikiChangeLog] rather than triggering a whole-database
/// snapshot): lets a wiki manager run repeated ad-hoc marker lookups against a cached,
/// in-memory XML snapshot of the change-log without re-querying Mongo per search.
///
/// [getArchiveDocument] builds (and caches) one `<entry>` element per [WikiChangeLog]
/// record, with `uuid`/`editor`/`category`/`time` always present and two OPTIONAL marker
/// attributes set only when the underlying record qualifies:
///  - `reviewed="true"` when the record carries a [WikiChangeLog.changelog] annotation.
///  - `flagged="true"` when the record's [WikiChangeLogType] is `removedMod` (removals are
///    sensitive enough to warrant follow-up).
///
/// The search helpers below run a real `XmlNode.xpath(String expression)` query (see
/// `package:xml`'s bundled, experimental `xpath` extension) asking whether a caller-named
/// marker ATTRIBUTE is present on each `<entry>` -- e.g. `"//entry[@$field]"` for
/// `field == 'reviewed'` returns only annotated entries. The marker name is meant to be
/// restricted to the small set of legitimate, optional marker attributes
/// ([kWikiArchiveMarkerFields]) -- when it is not, an attacker can name any of the
/// ALWAYS-present identity attributes (`uuid`, `editor`, `category`, `time`) instead, whose
/// existence check is trivially true for every record, so the query silently widens from
/// "the handful of entries carrying this marker" to the entire archive. (This project's
/// resolvable `package:xml` release -- see `pubspec.yaml`'s comment on the `xml` entry --
/// only ships an experimental XPath subset with no boolean `or`/`and` operators, so the
/// classic `' or '1'='1'`-shaped literal-breakout idiom does not parse here; the same
/// unescaped-interpolation defect instead manifests as this attribute-existence widening,
/// confirmed empirically -- see this CWE's planting-research notes.)
/// ---------------------------------------------------------------------------------------

/// The only legitimate marker attribute names an admin is meant to search by.
const Set<String> kWikiArchiveMarkerFields = {'reviewed', 'flagged'};

class WikiArchiveHandler {
  static XmlDocument? _cachedArchive;

  /// Builds (or returns the cached) in-memory XML snapshot of the wiki change-log.
  static Future<XmlDocument> getArchiveDocument(
      {bool forceRebuild = false}) async {
    if (_cachedArchive != null && !forceRebuild) {
      return _cachedArchive!;
    }

    final List<WikiChangeLog> logs =
        await DataBase.instance.getModelsByField<WikiChangeLog>([], limit: 500);

    final XmlBuilder builder = XmlBuilder();
    builder.element('archive', nest: () {
      for (final WikiChangeLog log in logs) {
        builder.element('entry', nest: () {
          builder.attribute('uuid', log.uuid);
          builder.attribute('editor', log.userUUID);
          builder.attribute('category', log.type.name);
          builder.attribute('time', log.time.millisecondsSinceEpoch.toString());
          if (log.changelog != null) {
            builder.attribute('reviewed', 'true');
          }
          if (log.type == WikiChangeLogType.removedMod) {
            builder.attribute('flagged', 'true');
          }
        });
      }
    });

    return _cachedArchive = builder.buildDocument();
  }

  /// Direct construction shape: [field] is interpolated straight into the attribute-existence
  /// predicate at the point of the `.xpath(...)` call, with no intermediate helper and no
  /// validation of which attribute name it names.
  static Future<List<String>> searchByMarker(String field) async {
    final XmlDocument archive = await getArchiveDocument();
    // SINK: PLANTED-Dart-HR-310
    final Iterable<XmlNode> matches = archive.xpath("//entry[@$field]");
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Same marker search, safe variant: [field] is checked against the closed
  /// [kWikiArchiveMarkerFields] allow-list before it is ever substituted into the predicate --
  /// a name that isn't one of the two legitimate markers is rejected outright, so an identity
  /// attribute like `uuid` can never be named here. Must NOT fire.
  static Future<List<String>?> searchByMarkerSafe(String field) async {
    if (!kWikiArchiveMarkerFields.contains(field)) {
      return null;
    }
    final XmlDocument archive = await getArchiveDocument();
    // SAFE_SINK: PLANTED-Dart-HR-310-safe
    final Iterable<XmlNode> matches = archive.xpath("//entry[@$field]");
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Indirect construction shape, %s-template substitution: the predicate is assembled from a
  /// literal template via [String.replaceFirst] rather than `$`-interpolation, in a separate
  /// builder function one hop away from the actual `.xpath(...)` call.
  static String _buildMarkerQuery(String field) {
    const String template = '//entry[@%s]';
    return template.replaceFirst('%s', field);
  }

  static Future<List<String>> searchByMarkerTemplate(String field) async {
    final XmlDocument archive = await getArchiveDocument();
    final String query = _buildMarkerQuery(field);
    // SINK: PLANTED-Dart-HR-311
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Same templated search, safe variant: same allow-list check as
  /// [searchByMarkerSafe], applied before the template substitution. Must NOT fire.
  static Future<List<String>?> searchByMarkerTemplateSafe(String field) async {
    if (!kWikiArchiveMarkerFields.contains(field)) {
      return null;
    }
    final XmlDocument archive = await getArchiveDocument();
    final String query = _buildMarkerQuery(field);
    // SAFE_SINK: PLANTED-Dart-HR-311-safe
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Interprocedural construction shape: routed through the separate [WikiArchiveMarkerService]
  /// class below (a real cross-class hop from [TranslateRoute]), mirroring how
  /// [notifyStatusViaService] hands off to [WebhookDeliveryService] above.
  static Future<List<String>> searchViaService(String field) async {
    final XmlDocument archive = await getArchiveDocument();
    return WikiArchiveMarkerService(archive).findByMarker(field);
  }

  /// Same interprocedural search, safe variant -- see [WikiArchiveMarkerServiceSafe]. Must
  /// NOT fire.
  static Future<List<String>> searchViaServiceSafe(String field) async {
    final XmlDocument archive = await getArchiveDocument();
    return WikiArchiveMarkerServiceSafe(archive).findByMarker(field);
  }

  /// Type/polymorphism-dependent construction shape: `mode` selects which concrete
  /// [WikiArchiveFieldResolver] builds the predicate -- `'legacy'` resolves to
  /// [_LegacyFieldResolver] (kept for an old client integration that named the marker
  /// attribute directly, with no validation), anything else resolves to the validated
  /// [_StandardFieldResolver]. Exploitability here depends entirely on which subclass
  /// [WikiArchiveFieldResolver.forMode] returns for the given `mode` -- exactly mirroring how
  /// [notifyStatusWithTrustMode] resolves a concrete [StatusNotifier] from a caller-supplied
  /// string above.
  static Future<List<String>> searchByMode(String field, String mode) async {
    final XmlDocument archive = await getArchiveDocument();
    final WikiArchiveFieldResolver resolver =
        WikiArchiveFieldResolver.forMode(mode);
    final String? query = resolver.buildQuery(field);
    if (query == null) {
      return const [];
    }
    // SINK: PLANTED-Dart-HR-313
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Same mode-selectable search, safe variant: `'legacy'` now also resolves to a validating
  /// resolver -- see [WikiArchiveFieldResolverSafe]. Must NOT fire.
  static Future<List<String>> searchByModeSafe(
      String field, String mode) async {
    final XmlDocument archive = await getArchiveDocument();
    final WikiArchiveFieldResolverSafe resolver =
        WikiArchiveFieldResolverSafe.forMode(mode);
    final String? query = resolver.buildQuery(field);
    if (query == null) {
      return const [];
    }
    // SAFE_SINK: PLANTED-Dart-HR-313-safe
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Distinct construction shape: combines TWO independently-tainted marker fields into one
  /// compound predicate (`"//entry[@$field1][@$field2]"`, chained brackets -- the ANDed
  /// multi-predicate form this experimental XPath subset actually supports) so an admin can
  /// narrow to entries carrying BOTH markers at once. Neither field is validated here, and
  /// each is independently exploitable: naming an always-present identity attribute for
  /// either one defeats that half of the AND.
  static Future<List<String>> searchByTwoMarkers(
      String field1, String field2) async {
    final XmlDocument archive = await getArchiveDocument();
    // SINK: PLANTED-Dart-HR-314
    final Iterable<XmlNode> matches =
        archive.xpath("//entry[@$field1][@$field2]");
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }

  /// Same compound search, safe variant: BOTH fields are checked against
  /// [kWikiArchiveMarkerFields] before being combined into the predicate -- either one failing
  /// the check rejects the whole search. Must NOT fire.
  static Future<List<String>?> searchByTwoMarkersSafe(
      String field1, String field2) async {
    if (!kWikiArchiveMarkerFields.contains(field1) ||
        !kWikiArchiveMarkerFields.contains(field2)) {
      return null;
    }
    final XmlDocument archive = await getArchiveDocument();
    // SAFE_SINK: PLANTED-Dart-HR-314-safe
    final Iterable<XmlNode> matches =
        archive.xpath("//entry[@$field1][@$field2]");
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }
}

/// Interprocedural construction shape: the actual query building + `.xpath(...)` call happens
/// inside this separate service class (a real cross-file/cross-class hop from the route),
/// mirroring how [WebhookDeliveryService] separates delivery from [TranslateHandler] above.
/// [field] is concatenated (via `+`) into the predicate with no validation.
class WikiArchiveMarkerService {
  final XmlDocument archive;
  const WikiArchiveMarkerService(this.archive);

  Future<List<String>> findByMarker(String field) async {
    final String query = '//entry[@' + field + ']';
    // SINK: PLANTED-Dart-HR-312
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }
}

/// Same interprocedural marker search, safe variant: [field] is checked against
/// [kWikiArchiveMarkerFields] before being concatenated into the predicate. Must NOT fire.
class WikiArchiveMarkerServiceSafe {
  final XmlDocument archive;
  const WikiArchiveMarkerServiceSafe(this.archive);

  Future<List<String>> findByMarker(String field) async {
    if (!kWikiArchiveMarkerFields.contains(field)) {
      return const [];
    }
    final String query = '//entry[@' + field + ']';
    // SAFE_SINK: PLANTED-Dart-HR-312-safe
    final Iterable<XmlNode> matches = archive.xpath(query);
    return matches
        .whereType<XmlElement>()
        .map((e) => e.getAttribute('uuid')!)
        .toList();
  }
}

/// See [WikiArchiveHandler.searchByMode]: `mode` picks the concrete resolver.
abstract class WikiArchiveFieldResolver {
  /// Returns the XPath query for [field], or `null` to refuse the search entirely.
  String? buildQuery(String field);

  static WikiArchiveFieldResolver forMode(String mode) {
    switch (mode) {
      case 'legacy':
        return const _LegacyFieldResolver();
      case 'standard':
      default:
        return const _StandardFieldResolver();
    }
  }
}

/// Kept for an old client integration that names the marker attribute directly -- never
/// validates [field] against [kWikiArchiveMarkerFields].
class _LegacyFieldResolver implements WikiArchiveFieldResolver {
  const _LegacyFieldResolver();
  @override
  String? buildQuery(String field) => '//entry[@$field]';
}

class _StandardFieldResolver implements WikiArchiveFieldResolver {
  const _StandardFieldResolver();
  @override
  String? buildQuery(String field) =>
      kWikiArchiveMarkerFields.contains(field) ? '//entry[@$field]' : null;
}

/// Safe sibling of [WikiArchiveFieldResolver]: every mode, `'legacy'` included, now validates
/// [field]. See [WikiArchiveHandler.searchByModeSafe].
abstract class WikiArchiveFieldResolverSafe {
  String? buildQuery(String field);

  static WikiArchiveFieldResolverSafe forMode(String mode) {
    switch (mode) {
      case 'legacy':
      case 'standard':
      default:
        return const _ValidatingFieldResolverSafe();
    }
  }
}

class _ValidatingFieldResolverSafe implements WikiArchiveFieldResolverSafe {
  const _ValidatingFieldResolverSafe();
  @override
  String? buildQuery(String field) =>
      kWikiArchiveMarkerFields.contains(field) ? '//entry[@$field]' : null;
}
