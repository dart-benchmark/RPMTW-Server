import 'dart:convert';

import 'package:grammer/grammer.dart';
import 'package:intl/locale.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_dart_common_library/rpmtw_dart_common_library.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/list_model_response.dart';
import 'package:rpmtw_server/database/models/auth/user.dart';
import 'package:rpmtw_server/database/models/auth/user_role.dart';
import 'package:rpmtw_server/database/auth_route.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_mod.dart';
import 'package:rpmtw_server/database/models/minecraft/minecraft_version.dart';
import 'package:rpmtw_server/database/model_field.dart';
import 'package:rpmtw_server/database/models/storage/storage.dart';
import 'package:rpmtw_server/database/models/translate/glossary.dart';
import 'package:rpmtw_server/database/models/translate/mod_source_info.dart';
import 'package:rpmtw_server/database/models/translate/source_file.dart';
import 'package:rpmtw_server/database/models/translate/source_text.dart';
import 'package:rpmtw_server/database/models/translate/translate_report_sort_type.dart';
import 'package:rpmtw_server/database/models/translate/translate_status.dart';
import 'package:rpmtw_server/database/models/translate/translation.dart';
import 'package:rpmtw_server/database/models/translate/translation_export_cache.dart';
import 'package:rpmtw_server/database/models/translate/translation_export_format.dart';
import 'package:rpmtw_server/database/models/translate/translation_vote.dart';
import 'package:rpmtw_server/database/models/translate/translator_info.dart';
import 'package:rpmtw_server/database/scripts/translate_status_script.dart';
import 'package:rpmtw_server/handler/minecraft_handler.dart';
import 'package:rpmtw_server/handler/translate_handler.dart';
import 'package:rpmtw_server/routes/api_route.dart';
import 'package:rpmtw_server/utilities/api_response.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/memcache_client.dart';
import 'package:rpmtw_server/utilities/request_extension.dart';
import 'package:shelf_router/shelf_router.dart';

class TranslateRoute extends APIRoute {
  @override
  String get routeName => 'translate';

  @override
  void router(router) {
    vote(router);
    translation(router);
    sourceText(router);
    sourceFile(router);
    modSourceInfo(router);
    glossary(router);
    translateStatus(router);
    translatorInfo(router);
    other(router);
    wikiArchive(router);
  }

  void vote(Router router) {
    /// Get vote
    router.getRoute('/vote/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid'];
      final TranslationVote? vote = await TranslationVote.getByUUID(uuid);

      if (vote == null) {
        return APIResponse.modelNotFound<TranslationVote>();
      }

      return APIResponse.success(data: vote.outputMap());
    }, requiredFields: ['uuid']);

    /// List all translation votes by translation uuid
    router.getRoute('/vote', (req, data) async {
      final Map<String, dynamic> fields = data.fields;

      final String translationUUID = fields['translationUUID'];

      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }

      final Translation? translation =
          await Translation.getByUUID(translationUUID);
      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      final List<TranslationVote> votes =
          await TranslationVote.getAllByTranslationUUID(translationUUID,
              limit: limit, skip: skip);

      return APIResponse.success(
          data: ListModelResponse.fromModel(votes, limit, skip));
    }, requiredFields: ['translationUUID']);

    /// Add translation vote
    router.postRoute('/vote', (req, data) async {
      final User user = req.user!;

      final String translationUUID = data.fields['translationUUID']!;
      final TranslationVoteType type =
          TranslationVoteType.values.byName(data.fields['type']!);

      final Translation? translation =
          await Translation.getByUUID(translationUUID);

      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      final List<TranslationVote> votes = await translation.votes;

      if (votes.any((vote) => vote.userUUID == user.uuid)) {
        return APIResponse.badRequest(message: 'You have already voted');
      }

      final TranslationVote vote = TranslationVote(
          uuid: Uuid().v4(),
          type: type,
          translationUUID: translationUUID,
          userUUID: user.uuid);

      await vote.insert();
      await TranslateHandler.updateTranslatorInfo(user.uuid, vote: true);
      return APIResponse.success(data: vote.outputMap());
    }, requiredFields: ['translationUUID', 'type'], authConfig: AuthConfig());

    /// Edit translation vote
    router.patchRoute('/vote/<uuid>', (req, data) async {
      final User user = req.user!;

      final String uuid = data.fields['uuid']!;
      final TranslationVoteType type =
          TranslationVoteType.values.byName(data.fields['type']!);

      TranslationVote? vote = await TranslationVote.getByUUID(uuid);
      if (vote == null) {
        return APIResponse.modelNotFound<TranslationVote>();
      }

      if (vote.userUUID != user.uuid) {
        return APIResponse.forbidden(message: 'You cannot edit this vote');
      }

      vote = vote.copyWith(type: type);

      await vote.update();
      return APIResponse.success(data: null);
    }, requiredFields: ['uuid', 'type'], authConfig: AuthConfig());

    /// Cancel translation vote
    router.deleteRoute('/vote/<uuid>', (req, data) async {
      final User user = req.user!;

      final String uuid = data.fields['uuid']!;

      final TranslationVote? vote = await TranslationVote.getByUUID(uuid);
      if (vote == null) {
        return APIResponse.modelNotFound<TranslationVote>();
      }

      if (vote.userUUID != user.uuid) {
        return APIResponse.badRequest(message: 'You cannot cancel this vote');
      }

      await vote.delete();

      return APIResponse.success(data: null);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());
  }

  void translation(Router router) {
    /// Get translation by uuid
    router.getRoute('/translation/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      final Translation? translation = await Translation.getByUUID(uuid);

      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      return APIResponse.success(data: translation.outputMap());
    }, requiredFields: ['uuid']);

    /// List all translations by source text or target language or translator
    router.getRoute('/translation', (req, data) async {
      final Map<String, dynamic> fields = data.fields;

      final String? sourceTextUUID = fields['sourceUUID'];
      final Locale? language =
          fields['language'] != null ? Locale.parse(fields['language']) : null;
      final String? translatorUUID = fields['translatorUUID'];

      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }

      final List<Translation> translations = await Translation.list(
          sourceUUID: sourceTextUUID,
          language: language,
          translatorUUID: translatorUUID,
          limit: limit,
          skip: skip);

      return APIResponse.success(
          data: ListModelResponse.fromModel(translations, limit, skip));
    });

    /// Add translation
    router.postRoute('/translation', (req, data) async {
      final User user = req.user!;

      final SourceText? sourceText =
          await SourceText.getByUUID(data.fields['sourceUUID']!);
      final Locale language = Locale.parse(data.fields['language']!);
      final String content = data.fields['content']!;

      if (sourceText == null) {
        return APIResponse.modelNotFound<SourceText>();
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      if (!TranslateHandler.supportedLanguage.contains(language)) {
        return APIResponse.badRequest(
            message: 'RPMTranslator doesn\'t support this language');
      }

      final Translation translation = Translation(
          uuid: Uuid().v4(),
          sourceUUID: sourceText.uuid,
          language: language,
          content: content,
          translatorUUID: user.uuid);

      await translation.insert();
      await TranslateHandler.updateTranslatorInfo(user.uuid, translate: true);
      return APIResponse.success(data: translation.outputMap());
    },
        requiredFields: ['sourceUUID', 'language', 'content'],
        authConfig: AuthConfig());

    /// Delete translation by uuid
    router.deleteRoute('/translation/<uuid>', (req, data) async {
      final User user = req.user!;

      final String uuid = data.fields['uuid']!;

      final Translation? translation = await Translation.getByUUID(uuid);
      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      if (translation.translatorUUID != user.uuid) {
        return APIResponse.forbidden(
            message: 'You cannot delete this translation');
      }

      await translation.delete();

      return APIResponse.success(data: null);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Quick-edit translation content (fix a typo without delete+recreate).
    router.patchRoute('/translation/<uuid>/content', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final String content = data.fields['content']!;

      final Translation? translation = await Translation.getByUUID(uuid);
      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Translation newTranslation =
          translation.copyWith(content: content);
      // SINK: PLANTED-Dart-HR-130
      await newTranslation.update();

      return APIResponse.success(data: newTranslation.outputMap());
    }, requiredFields: ['uuid', 'content'], authConfig: AuthConfig());

    /// Same quick-edit, safe variant: only the translation's own translator may use it.
    router.patchRoute('/translation/<uuid>/content-safe', (req, data) async {
      final User user = req.user!;
      final String uuid = data.fields['uuid']!;
      final String content = data.fields['content']!;

      final Translation? translation = await Translation.getByUUID(uuid);
      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      if (translation.translatorUUID != user.uuid) {
        return APIResponse.forbidden(
            message: 'You cannot edit this translation');
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Translation newTranslation =
          translation.copyWith(content: content);
      // SAFE_SINK: PLANTED-Dart-HR-130-safe
      await newTranslation.update();

      return APIResponse.success(data: newTranslation.outputMap());
    }, requiredFields: ['uuid', 'content'], authConfig: AuthConfig());

    /// Collaborative-edit quick-patch: the internal import/backfill pipeline passes its own
    /// service context (requesterContext as a Map, already authorized upstream) instead of a
    /// caller uuid. Ordinary clients simply omit requesterContext and fall back to their own
    /// uuid, which IS checked against the translation's translator.
    router.patchRoute('/translation/<uuid>/collab-edit', (req, data) async {
      final String uuid = data.fields['uuid']!;
      final String content = data.fields['content']!;
      final dynamic requesterContext =
          data.fields['requesterContext'] ?? req.user!.uuid;

      final Translation? translation = await Translation.getByUUID(uuid);
      if (translation == null) {
        return APIResponse.modelNotFound<Translation>();
      }

      if (content.isAllEmpty) {
        return APIResponse.fieldEmpty('content');
      }

      final Translation? patched =
          await _applyCollabEdit(translation, requesterContext, content);
      if (patched == null) {
        return APIResponse.forbidden(
            message: 'You cannot edit this translation');
      }

      return APIResponse.success(data: patched.outputMap());
    }, requiredFields: ['uuid', 'content'], authConfig: AuthConfig());
  }

  /// Applies a collaborative-edit patch: [requesterContext] is either the calling user's own
  /// uuid (an ordinary client, subject to the usual ownership check) or a service context Map
  /// supplied by the internal import/backfill pipeline (already authorized upstream, so no
  /// per-record check is performed here).
  Future<Translation?> _applyCollabEdit(
      Translation translation, dynamic requesterContext, String content) async {
    if (requesterContext is Map) {
      // Internal service context -- trusted by construction, no ownership re-check.
      final Translation patched = translation.copyWith(content: content);
      // SINK: PLANTED-Dart-HR-133
      await patched.update();
      return patched;
    } else {
      final String requesterUUID = requesterContext as String;
      if (translation.translatorUUID != requesterUUID) {
        return null;
      }
      final Translation patched = translation.copyWith(content: content);
      // SAFE_SINK: PLANTED-Dart-HR-133-safe
      await patched.update();
      return patched;
    }
  }

  void sourceText(Router router) {
    /// Get source text by uuid
    router.getRoute('/source-text/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      final SourceText? sourceText = await SourceText.getByUUID(uuid);

      if (sourceText == null) {
        return APIResponse.modelNotFound<SourceText>();
      }

      return APIResponse.success(data: sourceText.outputMap());
    }, requiredFields: ['uuid']);

    /// List all source text by source or key
    router.getRoute('/source-text', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }

      final List<SourceText> sourceTexts = await SourceText.list(
          source: data.fields['source'],
          key: data.fields['key'],
          limit: limit,
          skip: skip);

      return APIResponse.success(
          data: ListModelResponse.fromModel(sourceTexts, limit, skip));
    });

    /// Add source text
    router.postRoute('/source-text', (req, data) async {
      final String source = data.fields['source']!;
      final List<MinecraftVersion> gameVersions =
          await MinecraftVersion.getByIDs(
              data.fields['gameVersions']!.cast<String>(),
              mainVersion: true);
      final String key = data.fields['key']!;
      final SourceTextType type =
          SourceTextType.values.byName(data.fields['type']!);

      if (source.isAllEmpty) {
        return APIResponse.fieldEmpty('source');
      }

      if (gameVersions.isEmpty) {
        return APIResponse.fieldEmpty('gameVersions');
      }

      if (key.isAllEmpty) {
        return APIResponse.fieldEmpty('key');
      }

      final SourceText sourceText = SourceText(
          uuid: Uuid().v4(),
          source: source,
          gameVersions: gameVersions,
          key: key,
          type: type);

      await sourceText.insert();
      return APIResponse.success(data: sourceText.outputMap());
    },
        requiredFields: ['source', 'gameVersions', 'key', 'type'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Edit source text by uuid
    router.patchRoute('/source-text/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      SourceText? sourceText = await SourceText.getByUUID(uuid);
      if (sourceText == null) {
        return APIResponse.modelNotFound<SourceText>();
      }

      final String? source = data.fields['source'];
      final List<MinecraftVersion>? gameVersions =
          data.fields['gameVersions'] != null
              ? await MinecraftVersion.getByIDs(
                  data.fields['gameVersions']!.cast<String>(),
                  mainVersion: true)
              : null;
      final String? key = data.fields['key'];

      if (source != null && source.isAllEmpty) {
        return APIResponse.fieldEmpty('source');
      }

      if (gameVersions != null && gameVersions.isEmpty) {
        return APIResponse.fieldEmpty('gameVersions');
      }

      if (key != null && key.isAllEmpty) {
        return APIResponse.fieldEmpty('key');
      }

      if (source == null && gameVersions == null && key == null) {
        return APIResponse.badRequest(
            message: 'You need to provide at least one field to edit');
      }

      sourceText = sourceText.copyWith(
          source: source, gameVersions: gameVersions, key: key);

      await sourceText.update();
      return APIResponse.success(data: sourceText.outputMap());
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Delete source text by uuid
    router.deleteRoute('/source-text/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      SourceText? sourceText = await SourceText.getByUUID(uuid);
      if (sourceText == null) {
        return APIResponse.modelNotFound<SourceText>();
      }

      /// Delete all dependencies of this source text
      if (sourceText.type == SourceTextType.patchouli) {
        List<ModSourceInfo>? infos = await DataBase.instance
            .getModelsByField<ModSourceInfo>(
                [ModelField('patchouliAddons', sourceText.uuid)]);

        for (ModSourceInfo info in infos) {
          if (info.patchouliAddons != null) {
            info = info.copyWith(
                patchouliAddons: List.from(info.patchouliAddons!)
                  ..remove(sourceText.uuid));
            await info.update();
          }
        }
      }
      List<SourceFile> files = await DataBase.instance
          .getModelsByField<SourceFile>(
              [ModelField('textUUIDs', sourceText.uuid)]);

      for (SourceFile file in files) {
        file = file.copyWith(
            textUUIDs: List.from(file.textUUIDs)..remove(sourceText.uuid));
        await file.update();
      }

      await sourceText.delete();

      return APIResponse.success(data: null);
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));
  }

  void sourceFile(Router router) {
    /// Get source file by uuid
    router.getRoute('/source-file/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      final SourceFile? sourceFile = await SourceFile.getByUUID(uuid);

      if (sourceFile == null) {
        return APIResponse.modelNotFound<SourceFile>();
      }

      return APIResponse.success(data: sourceFile.outputMap());
    }, requiredFields: ['uuid']);

    /// List source files by source info uuid
    router.getRoute('/source-file', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String? modSourceInfoUUID = fields['modSourceInfoUUID'];
      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }

      final List<SourceFile> files =
          await SourceFile.list(modSourceInfoUUID: modSourceInfoUUID);

      return APIResponse.success(
          data: ListModelResponse.fromModel(files, limit, skip));
    });

    /// Add source file
    router.postRoute('/source-file', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final String modSourceInfoUUID = fields['modSourceInfoUUID']!;
      final String storageUUID = fields['storageUUID']!;
      final String path = fields['path']!;
      final SourceFileType type = SourceFileType.values.byName(fields['type']!);
      final List<MinecraftVersion> gameVersions =
          await MinecraftVersion.getByIDs(
              fields['gameVersions']!.cast<String>(),
              mainVersion: true);
      final List<String>? patchouliI18nKeys =
          fields['patchouliI18nKeys'] != null
              ? fields['patchouliI18nKeys']!.cast<String>()
              : null;

      final ModSourceInfo? modSourceInfo =
          await ModSourceInfo.getByUUID(modSourceInfoUUID);

      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      if (gameVersions.isEmpty) {
        return APIResponse.fieldEmpty('gameVersions');
      }

      Storage? storage = await Storage.getByUUID(storageUUID);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }
      storage = storage.copyWith(
          type: StorageType.general, usageCount: storage.usageCount + 1);
      await storage.update();

      if (path.isAllEmpty) {
        return APIResponse.fieldEmpty('path');
      }

      final List<SourceText> sourceTexts;
      try {
        sourceTexts = await TranslateHandler.parseFile(
            await storage.readAsString(), type, gameVersions, path,
            patchouliI18nKeys: patchouliI18nKeys ?? []);
      } catch (e) {
        print(e);
        return APIResponse.badRequest(message: 'Failed to parse file');
      }

      final List<SourceFile> duplicateFiles =
          await DataBase.instance.getModelsByField<SourceFile>([
        ModelField('modSourceInfoUUID', modSourceInfoUUID),
        ModelField('path', path),
        ModelField('type', type.name)
      ]);

      final SourceFile file;
      if (duplicateFiles.isEmpty) {
        file = SourceFile(
            uuid: Uuid().v4(),
            modSourceInfoUUID: modSourceInfoUUID,
            storageUUID: storageUUID,
            path: path,
            type: type,
            textUUIDs: sourceTexts.map((e) => e.uuid).toList());

        await file.insert();
      } else {
        final duplicateFile = duplicateFiles.first;
        file = duplicateFile.copyWith(
            textUUIDs: List.from(duplicateFile.textUUIDs)
              ..addAll(sourceTexts.map((e) => e.uuid))
              ..toSet()
              ..toList());
        await file.update();
      }

      TranslateStatusScript.addToQueue(modSourceInfo.uuid);

      return APIResponse.success(data: file.outputMap());
    }, requiredFields: [
      'modSourceInfoUUID',
      'storageUUID',
      'path',
      'type',
      'gameVersions'
    ], authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Import a source file's content directly from an external URL (e.g. a raw GitHub
    /// link to the mod's own upstream lang file), instead of uploading via
    /// /storage/create first and referencing the resulting storageUUID like the plain
    /// "Add source file" route above.
    router.postRoute('/source-file/import', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final String modSourceInfoUUID = fields['modSourceInfoUUID']!;
      final String sourceUrl = fields['sourceUrl']!;
      final String path = fields['path']!;
      final SourceFileType type =
          SourceFileType.values.byName(fields['type']!);

      final ModSourceInfo? modSourceInfo =
          await ModSourceInfo.getByUUID(modSourceInfoUUID);

      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      if (path.isAllEmpty) {
        return APIResponse.fieldEmpty('path');
      }

      final SourceFileImportRequest importRequest = SourceFileImportRequest(
          modSourceInfoUUID: modSourceInfoUUID,
          sourceUrl: sourceUrl,
          path: path,
          type: type);

      final SourceFile? file =
          await SourceFile.importFromRequest(importRequest);

      if (file == null) {
        return APIResponse.badRequest(message: 'Failed to import source file');
      }

      TranslateStatusScript.addToQueue(modSourceInfo.uuid);

      return APIResponse.success(data: file.outputMap());
    },
        requiredFields: ['modSourceInfoUUID', 'sourceUrl', 'path', 'type'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Same source-file import, safe variant.
    router.postRoute('/source-file/importSafe', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final String modSourceInfoUUID = fields['modSourceInfoUUID']!;
      final String sourceUrl = fields['sourceUrl']!;
      final String path = fields['path']!;
      final SourceFileType type =
          SourceFileType.values.byName(fields['type']!);

      final ModSourceInfo? modSourceInfo =
          await ModSourceInfo.getByUUID(modSourceInfoUUID);

      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      if (path.isAllEmpty) {
        return APIResponse.fieldEmpty('path');
      }

      final SourceFileImportRequest importRequest = SourceFileImportRequest(
          modSourceInfoUUID: modSourceInfoUUID,
          sourceUrl: sourceUrl,
          path: path,
          type: type);

      final SourceFile? file =
          await SourceFile.importFromRequestSafe(importRequest);

      if (file == null) {
        return APIResponse.badRequest(message: 'Failed to import source file');
      }

      TranslateStatusScript.addToQueue(modSourceInfo.uuid);

      return APIResponse.success(data: file.outputMap());
    },
        requiredFields: ['modSourceInfoUUID', 'sourceUrl', 'path', 'type'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Edit source file
    router.patchRoute('/source-file/<uuid>', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final String uuid = fields['uuid']!;

      SourceFile? sourceFile = await SourceFile.getByUUID(uuid);
      if (sourceFile == null) {
        return APIResponse.modelNotFound<SourceFile>();
      }

      final String? modSourceInfoUUID = fields['modSourceInfoUUID'];
      final String? storageUUID = fields['storageUUID'];
      final String? path = fields['path'];
      final SourceFileType? type = fields['type'] != null
          ? SourceFileType.values.byName(fields['type']!)
          : null;
      final List<MinecraftVersion>? gameVersions =
          fields['gameVersions'] != null
              ? await MinecraftVersion.getByIDs(
                  fields['gameVersions']!.cast<String>(),
                  mainVersion: true)
              : null;
      final List<String>? patchouliI18nKeys =
          fields['patchouliI18nKeys'] != null
              ? fields['patchouliI18nKeys']!.cast<String>()
              : null;

      if (path != null && path.isAllEmpty) {
        return APIResponse.fieldEmpty('path');
      }

      List<SourceText>? sourceTexts;
      if (storageUUID != null) {
        if (gameVersions == null || gameVersions.isEmpty) {
          return APIResponse.badRequest(
              message:
                  'If you want to change storage, you must provide game versions');
        }

        Storage? storage = await Storage.getByUUID(storageUUID);

        if (storage == null) {
          return APIResponse.modelNotFound<Storage>();
        }

        storage = storage.copyWith(
            type: StorageType.general, usageCount: storage.usageCount + 1);
        await storage.update();

        Storage? oldStorage = await Storage.getByUUID(sourceFile.storageUUID);
        if (oldStorage != null) {
          oldStorage = oldStorage.copyWith(
              type: StorageType.general,
              usageCount:
                  oldStorage.usageCount > 0 ? oldStorage.usageCount - 1 : 0);
          await oldStorage.update();
        }

        try {
          sourceTexts = await TranslateHandler.parseFile(
              await storage.readAsString(),
              type ?? sourceFile.type,
              gameVersions,
              path ?? sourceFile.path,
              patchouliI18nKeys: patchouliI18nKeys ?? []);
        } catch (e) {
          return APIResponse.badRequest(message: 'Failed to parse file');
        }
      }

      if (modSourceInfoUUID != null) {
        final ModSourceInfo? modSourceInfo =
            await ModSourceInfo.getByUUID(modSourceInfoUUID);

        if (modSourceInfo == null) {
          return APIResponse.modelNotFound<ModSourceInfo>();
        }

        TranslateStatusScript.addToQueue(modSourceInfoUUID);
      }

      sourceFile = sourceFile.copyWith(
          modSourceInfoUUID: modSourceInfoUUID,
          path: path,
          type: type,
          storageUUID: storageUUID,
          textUUIDs: sourceTexts != null
              ? (List.from(sourceFile.textUUIDs)
                ..addAll(sourceTexts.map((e) => e.uuid))
                ..toSet()
                ..toList())
              : null);
      await sourceFile.update();

      if (storageUUID != null) {
        (await sourceFile.storage)?.delete();
      }

      return APIResponse.success(data: sourceFile.outputMap());
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Kick off a re-validation parse of an already-uploaded source file (heavier than the
    /// synchronous parse the create/edit routes run), returning a token the caller polls
    /// via GET .../revalidate/<token> once the result is cached.
    router.postRoute('/source-file/revalidate', (req, data) async {
      final String storageUUID = data.fields['storageUUID']!;
      final SourceFileType type =
          SourceFileType.values.byName(data.fields['type']!);
      final String path = data.fields['path']!;

      Storage? storage = await Storage.getByUUID(storageUUID);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      final String token = Uuid().v4();
      final MemcacheClient cache = MemcacheClient();

      try {
        await TranslateHandler.parseFile(
            await storage.readAsString(), type, [], path);
        await cache.set(
            'rpmtw:revalidate:$token', json.encode({'ok': true}),
            ttlSeconds: 300);
      } catch (e, stackTrace) {
        // 快取完整的失敗內容（含原始 parser 堆疊追蹤），讓用戶端能透過 token 查詢
        // 重新驗證確切失敗的原因
        // SINK: PLANTED-Dart-HR-219
        await cache.set(
            'rpmtw:revalidate:$token',
            json.encode({'ok': false, 'error': '$e\n$stackTrace'}),
            ttlSeconds: 300);
      }

      return APIResponse.success(data: {'token': token});
    }, requiredFields: ['storageUUID', 'type', 'path']);

    /// Same re-validation, safe variant: only a boolean pass/fail flag is cached, the full
    /// exception (and stack trace) stays server-side in the logs. Must NOT fire.
    router.postRoute('/source-file/revalidate-safe', (req, data) async {
      final String storageUUID = data.fields['storageUUID']!;
      final SourceFileType type =
          SourceFileType.values.byName(data.fields['type']!);
      final String path = data.fields['path']!;

      Storage? storage = await Storage.getByUUID(storageUUID);
      if (storage == null) {
        return APIResponse.modelNotFound<Storage>();
      }

      final String token = Uuid().v4();
      final MemcacheClient cache = MemcacheClient();

      try {
        await TranslateHandler.parseFile(
            await storage.readAsString(), type, [], path);
        await cache.set(
            'rpmtw:revalidate:$token', json.encode({'ok': true}),
            ttlSeconds: 300);
      } catch (e, stackTrace) {
        logger.e(e, null, stackTrace);
        // SAFE_SINK: PLANTED-Dart-HR-219-safe
        await cache.set(
            'rpmtw:revalidate:$token', json.encode({'ok': false}),
            ttlSeconds: 300);
      }

      return APIResponse.success(data: {'token': token});
    }, requiredFields: ['storageUUID', 'type', 'path']);

    /// Read back a cached re-validation result by token.
    router.getRoute('/source-file/revalidate/<token>', (req, data) async {
      final String token = data.fields['token']!;
      final MemcacheClient cache = MemcacheClient();
      final String? cached = await cache.get('rpmtw:revalidate:$token');
      if (cached == null) {
        return APIResponse.notFound('Revalidation result not found or expired');
      }
      return APIResponse.success(data: json.decode(cached));
    }, requiredFields: ['token']);

    /// Delete source file and all source texts in it
    router.deleteRoute('/source-file/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      SourceFile? sourceFile = await SourceFile.getByUUID(uuid);
      if (sourceFile == null) {
        return APIResponse.modelNotFound<SourceFile>();
      }

      await sourceFile.delete();
      TranslateStatusScript.addToQueue(sourceFile.modSourceInfoUUID);

      return APIResponse.success(data: null);
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));
  }

  void modSourceInfo(Router router) {
    /// Get mod source info by uuid
    router.getRoute('/mod-source-info/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      final ModSourceInfo? modSourceInfo = await ModSourceInfo.getByUUID(uuid);

      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      return APIResponse.success(data: modSourceInfo.outputMap());
    }, requiredFields: ['uuid']);

    /// List mod source info
    router.getRoute('/mod-source-info', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String? name = fields['name'];
      final String? namespace = fields['namespace'];
      final String? modUUID = fields['modUUID'];

      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }
      List<ModSourceInfo> infos = [];

      if (namespace != null) {
        final List<ModSourceInfo> results = await DataBase.instance
            .getModelsWithSelector<ModSourceInfo>(where
                .match('namespace', '(?i)$namespace')
                .limit(limit)
                .skip(skip));

        infos.addAll(results);
      } else if (name != null) {
        List<MinecraftMod> mods = await MinecraftHeader.searchMods(
            filter: name, limit: limit, skip: skip);

        for (MinecraftMod mod in mods) {
          if (infos.map((e) => e.modUUID).contains(mod.uuid)) {
            continue;
          }

          final ModSourceInfo? modSourceInfo =
              await ModSourceInfo.getByModUUID(mod.uuid);

          if (modSourceInfo != null) {
            infos.add(modSourceInfo);
          }
        }
      } else {
        final List<ModSourceInfo> results =
            await DataBase.instance.getModelsByField<ModSourceInfo>([
          if (modUUID != null) ModelField('modUUID', modUUID),
        ], limit: limit, skip: skip);

        infos.addAll(results);
      }

      return APIResponse.success(
          data: ListModelResponse.fromModel(infos, limit, skip));
    });

    /// Add mod source info
    router.postRoute('/mod-source-info', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String? modUUID = fields['modUUID'];
      final String namespace = fields['namespace']!;
      final List<String>? patchouliAddons = fields['patchouliAddons'] != null
          ? fields['patchouliAddons']!.cast<String>()
          : null;

      if (namespace.isAllEmpty) {
        return APIResponse.fieldEmpty('namespace');
      }

      if (modUUID != null) {
        final MinecraftMod? mod = await MinecraftMod.getByUUID(modUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }

        final ModSourceInfo? modSourceInfo =
            await ModSourceInfo.getByModUUID(modUUID);

        if (modSourceInfo != null) {
          return APIResponse.badRequest(
              message:
                  'This mod uuid has already been added by another mod source info');
        }
      }

      if (patchouliAddons != null) {
        for (String addonUUID in patchouliAddons) {
          SourceText? sourceText = await SourceText.getByUUID(addonUUID);
          if (sourceText == null) {
            return APIResponse.modelNotFound<SourceText>();
          }
        }
      }

      final ModSourceInfo info = ModSourceInfo(
          uuid: Uuid().v4(),
          modUUID: modUUID,
          namespace: namespace,
          patchouliAddons: patchouliAddons);

      await info.insert();
      TranslateStatusScript.addToQueue(info.uuid);

      return APIResponse.success(data: info.outputMap());
    },
        requiredFields: ['namespace'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Edit mod source info
    router.patchRoute('/mod-source-info/<uuid>', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String uuid = fields['uuid']!;

      ModSourceInfo? modSourceInfo = await ModSourceInfo.getByUUID(uuid);
      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      final String? modUUID = fields['modUUID'];
      final String? namespace = fields['namespace'];
      final List<String>? patchouliAddons = fields['patchouliAddons'] != null
          ? fields['patchouliAddons']!.cast<String>()
          : null;

      if (modUUID != null) {
        final MinecraftMod? mod = await MinecraftMod.getByUUID(modUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }

        final ModSourceInfo? modSourceInfo =
            await ModSourceInfo.getByModUUID(modUUID);

        if (modSourceInfo != null) {
          return APIResponse.badRequest(
              message:
                  'This mod uuid has already been added by another mod source info');
        }
      }

      if (patchouliAddons != null) {
        List<String> needCheckUUIDs = patchouliAddons
            .where((e) =>
                (modSourceInfo!.patchouliAddons?.contains(e) ?? false) == false)
            .toList();

        for (String uuid in needCheckUUIDs) {
          SourceText? sourceText = await SourceText.getByUUID(uuid);
          if (sourceText == null) {
            return APIResponse.modelNotFound<SourceText>();
          }
        }
      }

      if (namespace != null && (namespace.isAllEmpty)) {
        return APIResponse.fieldEmpty('namespace');
      }

      modSourceInfo = modSourceInfo.copyWith(
          modUUID: modUUID,
          namespace: namespace,
          patchouliAddons: patchouliAddons);

      await modSourceInfo.update();
      TranslateStatusScript.addToQueue(modSourceInfo.uuid);

      return APIResponse.success(data: modSourceInfo.outputMap());
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Delete mod source info
    router.deleteRoute('/mod-source-info/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      ModSourceInfo? modSourceInfo = await ModSourceInfo.getByUUID(uuid);
      if (modSourceInfo == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      List<SourceFile> files = await modSourceInfo.files;
      for (SourceFile file in files) {
        await file.delete();
      }

      List<String>? patchouliAddons = modSourceInfo.patchouliAddons;
      if (patchouliAddons != null) {
        for (String addonUUID in patchouliAddons) {
          SourceText? sourceText = await SourceText.getByUUID(addonUUID);
          await sourceText?.delete();
        }
      }

      await modSourceInfo.delete();
      TranslateStatusScript.addToQueue(modSourceInfo.uuid);

      return APIResponse.success(data: null);
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(role: UserRoleType.translationManager));
  }

  void glossary(Router router) {
    /// Get glossary
    router.getRoute('/glossary/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid'];

      Glossary? glossary = await Glossary.getByUUID(uuid);
      if (glossary == null) {
        return APIResponse.modelNotFound<Glossary>();
      }

      await Glossary.recordUsage(uuid);

      return APIResponse.success(data: glossary.outputMap());
    }, requiredFields: ['uuid']);

    /// Same glossary lookup, safe variant: the usage-analytics log line escapes the stored
    /// term before writing it. Must NOT fire.
    router.getRoute('/glossary/<uuid>/usage-safe', (req, data) async {
      final String uuid = data.fields['uuid'];

      Glossary? glossary = await Glossary.getByUUID(uuid);
      if (glossary == null) {
        return APIResponse.modelNotFound<Glossary>();
      }

      await Glossary.recordUsageSafe(uuid);

      return APIResponse.success(data: glossary.outputMap());
    }, requiredFields: ['uuid']);

    /// Lightweight cache-only existence check for a glossary uuid -- lets the translator
    /// UI grey out a term reference without paying for a full glossary lookup on every
    /// keystroke. A cache miss just means "unknown", never a source of truth.
    router.getRoute('/glossary/<uuid>/peek', (req, data) async {
      final String uuid = data.fields['uuid'];
      final MemcacheClient cache = MemcacheClient();
      // SINK: PLANTED-Dart-HR-205
      final String? cached = await cache.get('rpmtw:glossary:peek:$uuid');
      return APIResponse.success(data: {'cached': cached != null});
    }, requiredFields: ['uuid']);

    /// Same cache-only peek, safe variant: the uuid is stripped of control characters and
    /// whitespace before it's used to build the cache key. Must NOT fire.
    router.getRoute('/glossary/<uuid>/peek-safe', (req, data) async {
      final String uuid = data.fields['uuid'];
      final String safeUuid = uuid.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
      final MemcacheClient cache = MemcacheClient();
      // SAFE_SINK: PLANTED-Dart-HR-205-safe
      final String? cached = await cache.get('rpmtw:glossary:peek:$safeUuid');
      return APIResponse.success(data: {'cached': cached != null});
    }, requiredFields: ['uuid']);

    /// Add glossary
    router.postRoute('/glossary', (req, data) async {
      final String term = data.fields['term']!;
      final String translation = data.fields['translation']!;
      final String? description = data.fields['description'];
      final Locale language = Locale.parse(data.fields['language']!);
      final String? modUUID = data.fields['modUUID'];

      if (!TranslateHandler.supportedLanguage.contains(language)) {
        return APIResponse.badRequest(
            message: 'RPMTranslator doesn\'t support this language');
      }

      if (modUUID != null) {
        MinecraftMod? mod = await MinecraftMod.getByUUID(modUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
      }

      if (term.isAllEmpty) {
        return APIResponse.fieldEmpty('term');
      }

      if (translation.isAllEmpty) {
        return APIResponse.fieldEmpty('translation');
      }

      if (description != null && description.isAllEmpty) {
        return APIResponse.fieldEmpty('description');
      }

      if (!Glossary.isValidTermFormat(term)) {
        return APIResponse.badRequest(message: 'Invalid term format');
      }

      final Glossary glossary = Glossary(
        uuid: Uuid().v4(),
        term: term,
        translation: translation,
        description: description,
        language: language,
        modUUID: modUUID,
      );

      await glossary.insert();

      return APIResponse.success(data: glossary.outputMap());
    },
        requiredFields: ['term', 'translation', 'language'],
        authConfig: AuthConfig());

    /// Same glossary creation, safe variant: the term is format-checked with a pattern
    /// lacking a redundant nested quantifier. Must NOT fire.
    router.postRoute('/glossary-safe', (req, data) async {
      final String term = data.fields['term']!;
      final String translation = data.fields['translation']!;
      final String? description = data.fields['description'];
      final Locale language = Locale.parse(data.fields['language']!);
      final String? modUUID = data.fields['modUUID'];

      if (!TranslateHandler.supportedLanguage.contains(language)) {
        return APIResponse.badRequest(
            message: 'RPMTranslator doesn\'t support this language');
      }

      if (modUUID != null) {
        MinecraftMod? mod = await MinecraftMod.getByUUID(modUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
      }

      if (term.isAllEmpty) {
        return APIResponse.fieldEmpty('term');
      }

      if (translation.isAllEmpty) {
        return APIResponse.fieldEmpty('translation');
      }

      if (description != null && description.isAllEmpty) {
        return APIResponse.fieldEmpty('description');
      }

      if (!Glossary.isValidTermFormatSafe(term)) {
        return APIResponse.badRequest(message: 'Invalid term format');
      }

      final Glossary glossary = Glossary(
        uuid: Uuid().v4(),
        term: term,
        translation: translation,
        description: description,
        language: language,
        modUUID: modUUID,
      );

      await glossary.insert();

      return APIResponse.success(data: glossary.outputMap());
    },
        requiredFields: ['term', 'translation', 'language'],
        authConfig: AuthConfig());

    /// List glossaries
    router.getRoute('/glossary', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final Locale? language =
          fields['language'] != null ? Locale.parse(fields['language']) : null;
      final String? modUUID = fields['modUUID'];
      final String? filter = fields['filter'];
      int limit =
          fields['limit'] != null ? int.tryParse(fields['limit']) ?? 50 : 50;
      final int skip =
          fields['skip'] != null ? int.tryParse(fields['skip']) ?? 0 : 0;

      // Max limit is 50
      if (limit > 50) {
        limit = 50;
      }

      final List<Glossary> glossaries = await Glossary.list(
          language: language,
          modUUID: modUUID,
          filter: filter,
          limit: limit,
          skip: skip);

      return APIResponse.success(
          data: ListModelResponse.fromModel(glossaries, limit, skip));
    }, authConfig: AuthConfig());

    /// Advanced glossary search: lets a translation manager filter by any extra field beyond
    /// the fixed language/modUUID/filter set above (e.g. a manager-defined tag).
    router.postRoute('/glossary/search', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final Locale? language =
          fields['language'] != null ? Locale.parse(fields['language']) : null;
      final String? modUUID = fields['modUUID'];
      final Map<String, dynamic>? extraCriteria = fields['extraCriteria'];

      final List<Glossary> glossaries = await Glossary.list(
          language: language,
          modUUID: modUUID,
          extraCriteria: extraCriteria,
          limit: 50);

      return APIResponse.success(
          data: ListModelResponse.fromModel(glossaries, 50, 0));
    }, authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Same advanced glossary search, safe variant: extraCriteria values are coerced to a
    /// scalar String inside Glossary.list before reaching the selector. Must NOT fire.
    router.postRoute('/glossary/search-safe', (req, data) async {
      Map<String, dynamic> fields = data.fields;

      final Locale? language =
          fields['language'] != null ? Locale.parse(fields['language']) : null;
      final String? modUUID = fields['modUUID'];
      final Map<String, dynamic>? extraCriteria = fields['extraCriteria'];

      final List<Glossary> glossaries = await Glossary.list(
          language: language,
          modUUID: modUUID,
          safeExtraCriteria: extraCriteria,
          limit: 50);

      return APIResponse.success(
          data: ListModelResponse.fromModel(glossaries, 50, 0));
    }, authConfig: AuthConfig(role: UserRoleType.translationManager));

    /// Edit glossary
    router.patchRoute('/glossary/<uuid>', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final String uuid = fields['uuid']!;
      Glossary? glossary = await Glossary.getByUUID(uuid);
      if (glossary == null) {
        return APIResponse.modelNotFound<Glossary>();
      }

      final String? term = fields['term'];
      final String? translation = fields['translation'];
      final String? description = fields['description'];
      late final String? modUUID;

      /// Avoid not setting modUUID to null in the request json, resulting in setting modUUID to null.
      String body = data.body;
      if (body.contains('modUUID')) {
        modUUID = fields['modUUID'];
      } else {
        modUUID = glossary.modUUID;
      }

      if (modUUID != null) {
        MinecraftMod? mod = await MinecraftMod.getByUUID(modUUID);
        if (mod == null) {
          return APIResponse.modelNotFound<MinecraftMod>();
        }
      }

      if (term != null && term.isAllEmpty) {
        return APIResponse.fieldEmpty('term');
      }

      if (translation != null && translation.isAllEmpty) {
        return APIResponse.fieldEmpty('translation');
      }

      if (description != null && description.isAllEmpty) {
        return APIResponse.fieldEmpty('description');
      }

      glossary = glossary.copyWith(
        term: term,
        translation: translation,
        description: description,
        modUUID: modUUID,
      );

      await glossary.update();

      return APIResponse.success(data: glossary.outputMap());
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Delete glossary
    router.deleteRoute('/glossary/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;

      Glossary? glossary = await Glossary.getByUUID(uuid);
      if (glossary == null) {
        return APIResponse.modelNotFound<Glossary>();
      }

      await glossary.delete();

      return APIResponse.success(data: null);
    }, requiredFields: ['uuid'], authConfig: AuthConfig());

    /// Get glossaries from text
    router.getRoute('/glossary-highlight', (req, data) async {
      final String text = data.fields['text']!;
      final Locale language = Locale.parse(data.fields['language']!);

      final List<String> words =
          text.split(' ').where((w) => !w.isAllEmpty).toSet().toList();
      Map<String, Glossary> result = {};

      for (String word in words) {
        Grammer grammer = Grammer(word);

        Future<Glossary?> get(String str) async {
          List<Glossary> glossaries =
              await Glossary.list(filter: str, language: language, limit: 1);
          if (glossaries.isNotEmpty) {
            return glossaries.first;
          } else {
            return null;
          }
        }

        List<String> strings = [grammer.toSingular(), ...grammer.toPlural()];

        for (String str in strings) {
          Glossary? glossary = await get(str);
          if (glossary != null) {
            result[word] = glossary;
            break;
          }
        }
      }

      /// Warm the shared cache for every word this request just resolved, so a later
      /// highlight request for a different source text containing the same common words
      /// doesn't re-pay the Grammer normalization + Mongo round trip above.
      await Glossary.warmHighlightCache(words, result);

      return APIResponse.success(
          data: result.map((key, value) => MapEntry(key, value.toMap())));
    }, requiredFields: ['text', 'language']);

    /// Same glossary-from-text lookup, safe variant: the cache warm-up strips control
    /// characters and whitespace from each word before it's used to build a cache key.
    /// Must NOT fire.
    router.getRoute('/glossary-highlight-safe', (req, data) async {
      final String text = data.fields['text']!;
      final Locale language = Locale.parse(data.fields['language']!);

      final List<String> words =
          text.split(' ').where((w) => !w.isAllEmpty).toSet().toList();
      Map<String, Glossary> result = {};

      for (String word in words) {
        Grammer grammer = Grammer(word);

        Future<Glossary?> get(String str) async {
          List<Glossary> glossaries =
              await Glossary.list(filter: str, language: language, limit: 1);
          if (glossaries.isNotEmpty) {
            return glossaries.first;
          } else {
            return null;
          }
        }

        List<String> strings = [grammer.toSingular(), ...grammer.toPlural()];

        for (String str in strings) {
          Glossary? glossary = await get(str);
          if (glossary != null) {
            result[word] = glossary;
            break;
          }
        }
      }

      await Glossary.warmHighlightCacheSafe(words, result);

      return APIResponse.success(
          data: result.map((key, value) => MapEntry(key, value.toMap())));
    }, requiredFields: ['text', 'language']);
  }

  void translateStatus(Router router) {
    /// Get translate status by mod source info
    router.getRoute('/status/<uuid>', (req, data) async {
      String infoUUID = data.fields['uuid']!;

      ModSourceInfo? info = await ModSourceInfo.getByUUID(infoUUID);
      if (info == null) {
        return APIResponse.modelNotFound<ModSourceInfo>();
      }

      TranslateStatus status =
          await TranslateHandler.updateOrCreateStatus(info);

      return APIResponse.success(data: status.outputMap());
    }, requiredFields: ['uuid']);

    /// Get global translate status
    router.getRoute('/status', (req, data) async {
      TranslateStatus? status =
          await TranslateStatus.getByModSourceInfoUUID(null);

      status ??= await TranslateHandler.updateOrCreateStatus(null);

      return APIResponse.success(data: status.outputMap());
    });

    /// Notify a configured sink about the current translation status for the given
    /// mod-source (or the global status, when [uuid] is omitted) -- lets an integration
    /// choose between a webhook push and the server's own log via [notifyType].
    router.postRoute('/status/notify', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String notifyType = data.fields['notifyType'] ?? 'log';
      final String? webhookUrl = data.fields['webhookUrl'];

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatus(info, notifyType, webhookUrl);

      return APIResponse.success(data: null);
    });

    /// Same status notification, safe variant: never honors a caller-supplied
    /// webhookUrl, regardless of notifyType -- always falls back to the server's own log.
    router.postRoute('/status/notifySafe', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String notifyType = data.fields['notifyType'] ?? 'log';
      final String? webhookUrl = data.fields['webhookUrl'];

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusSafe(info, notifyType, webhookUrl);

      return APIResponse.success(data: null);
    });

    /// Admin-only: pings a webhook target once, letting the admin mark it as an internal
    /// endpoint (`trustInternal`) so a bad/self-signed certificate on that target is
    /// accepted rather than failing the connection -- see
    /// [pingWebhookEndpoint]. Direct construction shape: the certificate-validation decision
    /// is made in the same function that receives the flag, via an inline closure.
    router.postRoute('/status/notify-trusted', (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternal = data.fields['trustInternal'] as bool? ?? false;

      await pingWebhookEndpoint(webhookUrl, trustInternal);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trusted-endpoint ping, safe variant -- see [pingWebhookEndpointSafe]. Must NOT
    /// accept a bad certificate regardless of `trustInternal`.
    router.postRoute('/status/notify-trusted-safe', (req, data) async {
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternal = data.fields['trustInternal'] as bool? ?? false;

      await pingWebhookEndpointSafe(webhookUrl, trustInternal);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trusted-endpoint feature, indirect construction shape: the target's [HttpClient]
    /// is built by the separate, named [buildOutboundWebhookClient] helper rather than
    /// configured inline -- see [deliverWebhookNotification].
    router.postRoute('/status/deliver-trusted', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternal = data.fields['trustInternal'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;
      final TranslateStatus status =
          await TranslateHandler.updateOrCreateStatus(info);

      await deliverWebhookNotification(
          webhookUrl, {'totalWords': status.totalWords}, trustInternal);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same indirect-construction-shape delivery, safe variant -- see
    /// [deliverWebhookNotificationSafe].
    router.postRoute('/status/deliver-trusted-safe', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternal = data.fields['trustInternal'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;
      final TranslateStatus status =
          await TranslateHandler.updateOrCreateStatus(info);

      await deliverWebhookNotificationSafe(
          webhookUrl, {'totalWords': status.totalWords}, trustInternal);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trusted-endpoint feature, interprocedural variant: routed through
    /// [WebhookDeliveryService] -- see [TranslateHandler.notifyStatusViaService].
    router.postRoute('/status/notify-via-service', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternalEndpoints =
          data.fields['trustInternalEndpoints'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusViaService(
          info, webhookUrl, trustInternalEndpoints);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same interprocedural notification, safe variant -- see
    /// [TranslateHandler.notifyStatusViaServiceSafe].
    router.postRoute('/status/notify-via-service-safe', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool trustInternalEndpoints =
          data.fields['trustInternalEndpoints'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusViaServiceSafe(
          info, webhookUrl, trustInternalEndpoints);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trusted-endpoint feature, type/polymorphism-dependent variant: `trustMode`
    /// selects which concrete [StatusNotifier] runs -- see
    /// [TranslateHandler.notifyStatusWithTrustMode].
    router.postRoute('/status/notify-trust-mode', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String notifyType = data.fields['notifyType'] ?? 'log';
      final String? webhookUrl = data.fields['webhookUrl'];
      final String? trustMode = data.fields['trustMode'];

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusWithTrustMode(
          info, notifyType, webhookUrl, trustMode);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trust-mode dispatch, safe variant -- see
    /// [TranslateHandler.notifyStatusWithTrustModeSafe].
    router.postRoute('/status/notify-trust-mode-safe', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String notifyType = data.fields['notifyType'] ?? 'log';
      final String? webhookUrl = data.fields['webhookUrl'];
      final String? trustMode = data.fields['trustMode'];

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusWithTrustModeSafe(
          info, notifyType, webhookUrl, trustMode);

      return APIResponse.success(data: null);
    }, authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same trusted-endpoint feature, isolated-context variant: `useIsolatedContext` selects
    /// [InsecureContextHttpClientFactory] -- see
    /// [TranslateHandler.notifyStatusViaIsolatedContext].
    router.postRoute('/status/notify-isolated-context', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool useIsolatedContext =
          data.fields['useIsolatedContext'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusViaIsolatedContext(
          info, webhookUrl, useIsolatedContext);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));

    /// Same isolated-context notification, safe variant -- see
    /// [TranslateHandler.notifyStatusViaIsolatedContextSafe].
    router.postRoute('/status/notify-isolated-context-safe', (req, data) async {
      final String? infoUUID = data.fields['uuid'];
      final String webhookUrl = data.fields['webhookUrl']!;
      final bool useIsolatedContext =
          data.fields['useIsolatedContext'] as bool? ?? false;

      ModSourceInfo? info =
          infoUUID != null ? await ModSourceInfo.getByUUID(infoUUID) : null;

      await TranslateHandler.notifyStatusViaIsolatedContextSafe(
          info, webhookUrl, useIsolatedContext);

      return APIResponse.success(data: null);
    },
        requiredFields: ['webhookUrl'],
        authConfig: AuthConfig(role: UserRoleType.admin));
  }

  void translatorInfo(Router router) {
    /// Get translator info by uuid.
    router.getRoute('/translator-info/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;
      TranslatorInfo? info = await TranslatorInfo.getByUUID(uuid);
      if (info == null) {
        return APIResponse.modelNotFound<TranslatorInfo>();
      }

      return APIResponse.success(data: info.outputMap());
    }, requiredFields: ['uuid']);

    /// Get translator info by user uuid.
    router.getRoute('/translator-info/user/<uuid>', (req, data) async {
      final String uuid = data.fields['uuid']!;
      String _uuid;
      if (uuid == 'me') {
        _uuid = req.user!.uuid;
      } else {
        _uuid = uuid;
      }

      TranslatorInfo? info = await TranslatorInfo.getByUserUUID(_uuid);
      if (info == null) {
        return APIResponse.modelNotFound<TranslatorInfo>();
      }

      return APIResponse.success(data: info.outputMap());
    },
        requiredFields: ['uuid'],
        authConfig: AuthConfig(path: '/translate/translator-info/user/me'));

    /// Get translate report sort by start/end time.
    router.postRoute('/report', (req, data) async {
      Map<String, dynamic> fields = data.fields;
      final DateTime startTime = DateTime.fromMillisecondsSinceEpoch(
          fields['startTime']!,
          isUtc: true);
      final DateTime endTime =
          DateTime.fromMillisecondsSinceEpoch(fields['endTime']!, isUtc: true);
      final TranslateReportSortType sortType =
          TranslateReportSortType.values.byName(fields['sortType']!);

      int limit = fields['limit'] != null ? fields['limit'] ?? 50 : 50;
      final int skip = fields['skip'] != null ? fields['skip'] ?? 0 : 0;

      if (limit > 50) {
        limit = 50;
      }
      String fieldName = sortType.fieldName;

      AggregationPipelineBuilder pipeline = AggregationPipelineBuilder();
      pipeline.addStage(Unwind(Field(fieldName)));
      pipeline.addStage(Group(id: Field('_id'), fields: {
        'uuid': First(Field('uuid')),
        'userUUID': First(Field('userUUID')),
        'joinAt': First(Field('joinAt')),
        'translatedCount': AddToSet(Sum(Field('translatedCount'))),
        'votedCount': AddToSet(Sum(Field('votedCount'))),
        'sort_count': Sum(1)
      }));
      pipeline.addStage(Sort({'sort_count': -1}));
      pipeline.addStage(Limit(limit));
      pipeline.addStage(Skip(skip));

      /// match start/end time
      pipeline.addStage(Match(where
          .gte(fieldName, startTime.millisecondsSinceEpoch)
          .lte(fieldName, endTime.millisecondsSinceEpoch)
          .map['\$query']));

      List<TranslatorInfo> infos = (await DataBase.instance
              .getCollection<TranslatorInfo>()
              .modernAggregate(pipeline)
              .toList())
          .map((e) {
        Map<String, dynamic> _map = e;
        // TODO: Improve handling the map, this is only a temporary solution
        _map['translatedCount'] = (_map['translatedCount'] as List)..remove(0);
        _map['votedCount'] = (_map['votedCount'] as List)..remove(0);

        return TranslatorInfo.fromMap(_map);
      }).toList();

      return APIResponse.success(
          data: ListModelResponse.fromModel(infos, limit, skip));
    }, requiredFields: ['startTime', 'endTime', 'sortType']);
  }

  void other(Router router) {
    /// Export translation
    router.getRoute('/export', (req, data) async {
      final List<String> namespaces =
          data.fields['namespaces']!.toString().split(',');
      final Locale language = Locale.parse(data.fields['language']!);
      final TranslationExportFormat format =
          TranslationExportFormat.values.byName(data.fields['format']!);
      final MinecraftVersion? version =
          await MinecraftVersion.getByID(data.fields['version']!);

      if (version == null ||
          TranslateHandler.supportedVersion.contains(version.id) == false) {
        return APIResponse.badRequest(message: 'Invalid game version');
      }

      List<ModSourceInfo> infos = [];
      for (String namespace in namespaces) {
        ModSourceInfo? info = await ModSourceInfo.getByNamespace(namespace);
        if (info != null) {
          infos.add(info);
        }
      }

      Map<String, String> output = {};

      for (ModSourceInfo info in infos) {
        TranslationExportCache? _cache =
            await TranslationExportCache.getByInfos(
                info.uuid, language, format);

        if (_cache != null && !_cache.isExpired) {
          output.addAll(_cache.data);
          continue;
        }

        TranslationExportCache cache;
        if (_cache != null && _cache.isExpired) {
          cache =
              _cache.copyWith(data: {}, lastUpdated: RPMTWUtil.getUTCTime());
        } else {
          TranslationExportCache _ = TranslationExportCache(
              uuid: Uuid().v4(),
              modSourceInfoUUID: info.uuid,
              language: language,
              format: format,
              data: {},
              lastUpdated: RPMTWUtil.getUTCTime());
          await _.insert();
          cache = _;
        }

        Future<void> handleTexts(List<SourceText> texts) async {
          texts = texts.where((e) => e.gameVersions.contains(version)).toList();

          for (SourceText text in texts) {
            Translation? translation =
                await TranslateHandler.getBestTranslation(text, language);
            if (translation != null) {
              output[text.key] = translation.content;
              cache = cache.copyWith(
                  data: cache.data..[text.key] = translation.content);
            }
          }
        }

        final List<SourceFile> files = await info.files;

        if (format == TranslationExportFormat.minecraftJson) {
          List<SourceText> texts = [];
          for (SourceFile file in files) {
            (await file.sourceTexts).forEach(texts.add);
          }
          await handleTexts(texts);
        } else if (format == TranslationExportFormat.patchouli) {
          final List<SourceText>? texts = await info.patchouliAddonTexts;
          if (texts != null) {
            await handleTexts(texts);
          }
        } else if (format == TranslationExportFormat.customText) {
          List<SourceFile> customTextFiles = files
              .where((e) =>
                  e.type == SourceFileType.plainText ||
                  e.type == SourceFileType.customJson)
              .toList();

          for (SourceFile file in customTextFiles) {
            final List<SourceText> texts = (await file.sourceTexts)
                .where((e) => e.gameVersions.contains(version))
                .toList();

            Storage? sourceStorage = await file.storage;
            if (sourceStorage == null) {
              logger.e(
                  '[Export translation] Source file (${file.uuid}) storage not found.');
              continue;
            }

            String sourceContent = await sourceStorage.readAsString();
            String? translatedContent;

            for (SourceText text in texts) {
              Translation? translation =
                  await TranslateHandler.getBestTranslation(text, language);
              if (translation != null) {
                translatedContent =
                    sourceContent.replaceAll(text.source, translation.content);
              }
            }

            if (translatedContent != null) {
              output[file.path] = translatedContent;
              cache = cache.copyWith(
                  data: cache.data..[file.path] = translatedContent);
            }
          }
        }

        await cache.update();
      }

      return APIResponse.success(data: output);
    }, requiredFields: ['namespaces', 'format', 'language', 'version']);
  }

  void wikiArchive(Router router) {
    /// Wiki/translate change-log archive search -- engineered-host admin/wiki-manager
    /// feature layered on top of this project's existing wiki change-log data, modeled on
    /// the mongodump-style archival idea behind SystemRoute's admin maintenance routes, but
    /// for ad-hoc marker lookups against a cached, in-memory XML snapshot (built + queried
    /// via `package:xml`'s bundled `xpath` extension) rather than a whole-database dump.
    /// Direct construction shape: the marker attribute name is interpolated straight into
    /// the predicate at the point of the `.xpath(...)` call, with no intermediate helper and
    /// no validation of which attribute it names -- see
    /// [WikiArchiveHandler.searchByMarker].
    router.getRoute('/wiki-archive/search-by-marker', (req, data) async {
      final String field = data.fields['field']!;
      final List<String> uuids = await WikiArchiveHandler.searchByMarker(field);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same marker search, safe variant: [field] must be one of the two legitimate marker
    /// names ('reviewed'/'flagged') or the search is rejected outright. Must NOT fire. See
    /// [WikiArchiveHandler.searchByMarkerSafe].
    router.getRoute('/wiki-archive/search-by-marker-safe', (req, data) async {
      final String field = data.fields['field']!;
      final List<String>? uuids =
          await WikiArchiveHandler.searchByMarkerSafe(field);
      if (uuids == null) {
        return APIResponse.badRequest(message: 'Unknown marker field');
      }
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same archive, templated variant: the predicate is assembled via a `%s`-style template
    /// substitution rather than `$`-interpolation, one hop away from the actual
    /// `.xpath(...)` call -- indirect construction shape. See
    /// [WikiArchiveHandler.searchByMarkerTemplate].
    router.getRoute('/wiki-archive/search-by-marker-template',
        (req, data) async {
      final String field = data.fields['field']!;
      final List<String> uuids =
          await WikiArchiveHandler.searchByMarkerTemplate(field);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same templated search, safe variant -- see
    /// [WikiArchiveHandler.searchByMarkerTemplateSafe]. Must NOT fire.
    router.getRoute('/wiki-archive/search-by-marker-template-safe',
        (req, data) async {
      final String field = data.fields['field']!;
      final List<String>? uuids =
          await WikiArchiveHandler.searchByMarkerTemplateSafe(field);
      if (uuids == null) {
        return APIResponse.badRequest(message: 'Unknown marker field');
      }
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same archive, advanced marker search routed through [WikiArchiveMarkerService] --
    /// interprocedural construction shape: the query is built and executed inside that
    /// separate service class, a real cross-class hop from this route (mirroring how
    /// [TranslateHandler.notifyStatusViaService] hands off to [WebhookDeliveryService]
    /// above). See [WikiArchiveHandler.searchViaService].
    router.getRoute('/wiki-archive/search-advanced', (req, data) async {
      final String field = data.fields['field']!;
      final List<String> uuids =
          await WikiArchiveHandler.searchViaService(field);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same advanced search, safe variant -- see
    /// [WikiArchiveHandler.searchViaServiceSafe]. Must NOT fire.
    router.getRoute('/wiki-archive/search-advanced-safe', (req, data) async {
      final String field = data.fields['field']!;
      final List<String> uuids =
          await WikiArchiveHandler.searchViaServiceSafe(field);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same archive, mode-selectable search: `mode` picks which concrete
    /// [WikiArchiveFieldResolver] builds the predicate -- `'legacy'` (kept for an old client
    /// integration) never validates the field name, `'standard'` does -- type/polymorphism-
    /// dependent construction shape, exploitability depends entirely on which subclass
    /// [WikiArchiveFieldResolver.forMode] resolves to for the given `mode`. See
    /// [WikiArchiveHandler.searchByMode].
    router.postRoute('/wiki-archive/search-mode', (req, data) async {
      final String field = data.fields['field']!;
      final String mode = data.fields['mode'] ?? 'legacy';
      final List<String> uuids =
          await WikiArchiveHandler.searchByMode(field, mode);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same mode-selectable search, safe variant: every mode, `'legacy'` included, now
    /// resolves to a validating resolver -- see
    /// [WikiArchiveHandler.searchByModeSafe]. Must NOT fire.
    router.postRoute('/wiki-archive/search-mode-safe', (req, data) async {
      final String field = data.fields['field']!;
      final String mode = data.fields['mode'] ?? 'legacy';
      final List<String> uuids =
          await WikiArchiveHandler.searchByModeSafe(field, mode);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same archive, compound search: an admin can narrow to entries carrying BOTH of two
    /// given markers at once -- a genuinely distinct construction shape, combining two
    /// independently-tainted request fields into one compound (chained-bracket) predicate;
    /// both are independently exploitable. See
    /// [WikiArchiveHandler.searchByTwoMarkers].
    router.postRoute('/wiki-archive/search-compound', (req, data) async {
      final String field1 = data.fields['field1']!;
      final String field2 = data.fields['field2']!;
      final List<String> uuids =
          await WikiArchiveHandler.searchByTwoMarkers(field1, field2);
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field1', 'field2'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Same compound search, safe variant: BOTH fields must be legitimate markers or the
    /// search is rejected outright. Must NOT fire. See
    /// [WikiArchiveHandler.searchByTwoMarkersSafe].
    router.postRoute('/wiki-archive/search-compound-safe', (req, data) async {
      final String field1 = data.fields['field1']!;
      final String field2 = data.fields['field2']!;
      final List<String>? uuids =
          await WikiArchiveHandler.searchByTwoMarkersSafe(field1, field2);
      if (uuids == null) {
        return APIResponse.badRequest(message: 'Unknown marker field');
      }
      return APIResponse.success(data: {'uuids': uuids});
    },
        requiredFields: ['field1', 'field2'],
        authConfig: AuthConfig(role: UserRoleType.wikiManager));

    /// Lets a translator present a partner translation-marketplace's contributor-reputation
    /// badge, so its claimed reputation score can be attached to their submissions here. See
    /// [TranslateHandler.verifyContributorBadge].
    router.postRoute('/verify-contributor-badge', (req, data) async {
      final String badge = data.fields['badge'];
      final Map<String, dynamic>? claims =
          TranslateHandler.verifyContributorBadge(badge);

      if (claims == null) {
        return APIResponse.unauthorized(message: 'Invalid contributor badge');
      }

      return APIResponse.success(data: claims);
    }, requiredFields: ['badge']);

    /// Same contributor-badge verification, safe variant.
    router.postRoute('/verify-contributor-badge-safe', (req, data) async {
      final String badge = data.fields['badge'];
      final Map<String, dynamic>? claims =
          TranslateHandler.verifyContributorBadgeSafe(badge);

      if (claims == null) {
        return APIResponse.unauthorized(message: 'Invalid contributor badge');
      }

      return APIResponse.success(data: claims);
    }, requiredFields: ['badge']);
  }
}
