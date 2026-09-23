import 'package:intl/locale.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:rpmtw_server/database/database.dart';
import 'package:rpmtw_server/database/db_model.dart';
import 'package:rpmtw_server/database/index_fields.dart';
import 'package:rpmtw_server/utilities/data.dart';
import 'package:rpmtw_server/utilities/memcache_client.dart';

class Glossary extends DBModel {
  static const String collectionName = 'glossaries';
  static const List<IndexField> indexFields = [
    IndexField('term', unique: false),
    IndexField('language', unique: false),
    IndexField('modUUID', unique: false),
  ];

  final String term;
  final String translation;
  final String? description;
  final Locale language;
  final String? modUUID;

  const Glossary({
    required String uuid,
    required this.term,
    required this.translation,
    this.description,
    required this.language,
    this.modUUID,
  }) : super(uuid: uuid);

  Glossary copyWith({
    String? term,
    String? translation,
    String? description,
    String? modUUID,
  }) {
    return Glossary(
      uuid: uuid,
      term: term ?? this.term,
      translation: translation ?? this.translation,
      description: description ?? this.description,
      language: language,
      modUUID: modUUID ?? this.modUUID,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'term': term,
      'translation': translation,
      'description': description,
      'language': language.toLanguageTag(),
      'modUUID': modUUID,
    };
  }

  factory Glossary.fromMap(Map<String, dynamic> map) {
    return Glossary(
      uuid: map['uuid'],
      term: map['term'],
      translation: map['translation'],
      description: map['description'],
      language: Locale.parse(map['language']),
      modUUID: map['modUUID'],
    );
  }

  static Future<Glossary?> getByUUID(String uuid) =>
      DataBase.instance.getModelByUUID<Glossary>(uuid);

  /// Whether [term] looks like a well-formed dotted mod-translation key (e.g.
  /// "item.mymod.diamond_sword.name") before it's stored -- lets an obviously malformed key
  /// be rejected without a DB round trip.
  static bool isValidTermFormat(String term) {
    final String normalized = term.trim();
    // SINK: PLANTED-Dart-HR-237
    return RegExp(r'^(([a-zA-Z0-9_]+)+\.)+[a-zA-Z]{2,}$').hasMatch(normalized);
  }

  /// Same check, safe variant: the same accepted key shape, without the redundant nested
  /// quantifier. Must NOT fire.
  static bool isValidTermFormatSafe(String term) {
    final String normalized = term.trim();
    // SAFE_SINK: PLANTED-Dart-HR-237-safe
    return RegExp(r'^([a-zA-Z0-9_]+\.)+[a-zA-Z]{2,}$').hasMatch(normalized);
  }

  static Future<List<Glossary>> list(
      {Locale? language,
      String? modUUID,
      String? filter,
      Map<String, dynamic>? extraCriteria,
      Map<String, dynamic>? safeExtraCriteria,
      int? limit,
      int? skip}) async {
    SelectorBuilder selector = SelectorBuilder();

    if (language != null) {
      selector.eq('language', language.toLanguageTag());
    }

    if (modUUID != null) {
      selector.eq('modUUID', modUUID);
    }

    if (filter != null) {
      selector
          .match('term', '(?i)$filter')
          .or(where.match('translation', '(?i)$filter'));
    }

    /// Advanced search: let a translation manager filter glossaries by any additional field
    /// (e.g. a manager-defined tag added later) beyond the fixed language/modUUID/filter set
    /// above.
    if (extraCriteria != null) {
      extraCriteria.forEach((key, value) {
        // SINK: PLANTED-Dart-HR-91
        selector.eq(key, value);
      });
    }

    /// Same advanced-search feature, safe variant: every value is coerced to a scalar String
    /// before it reaches the selector. Must NOT allow an operator-shaped value through.
    if (safeExtraCriteria != null) {
      safeExtraCriteria.forEach((key, value) {
        final String scalarValue = value is String ? value : value.toString();
        // SAFE_SINK: PLANTED-Dart-HR-91-safe
        selector.eq(key, scalarValue);
      });
    }

    if (limit != null) {
      selector.limit(limit);
    }

    if (skip != null) {
      selector.skip(skip);
    }

    return DataBase.instance.getModelsWithSelector(selector);
  }

  /// Records a glossary lookup for translator-analytics purposes (which terms are queried
  /// most often). [term] was written once, at glossary-creation time (the `/glossary` POST
  /// route, which never checks it for control characters beyond "not empty") and is only
  /// read back here, on a later, unrelated request -- a stored value, not a same-request
  /// source.
  static Future<void> recordUsage(String uuid) async {
    final Glossary? glossary = await getByUUID(uuid);
    if (glossary == null) return;
    // SINK: PLANTED-Dart-HR-193
    logger.i('Glossary lookup: term="${glossary.term}" (uuid=$uuid)');
  }

  /// Same usage record, safe variant: the stored term is CRLF-escaped before being logged.
  /// Must NOT fire.
  static Future<void> recordUsageSafe(String uuid) async {
    final Glossary? glossary = await getByUUID(uuid);
    if (glossary == null) return;
    final String safeTerm =
        glossary.term.replaceAll('\r', '\\r').replaceAll('\n', '\\n');
    // SAFE_SINK: PLANTED-Dart-HR-193-safe
    logger.i('Glossary lookup: term="$safeTerm" (uuid=$uuid)');
  }

  /// Cache-warms the per-word glossary lookups `/glossary-highlight` performs -- the same
  /// handful of common words recur across many highlight requests for different source
  /// texts, so queuing one memcache `set` per resolved word (flushed together in one
  /// write) avoids re-querying Mongo for a word this cache has already resolved recently.
  /// [words] is the caller-supplied list of words extracted from the submitted text; a
  /// missing entry in [resolved] (no glossary match for that word) is simply skipped.
  static Future<void> warmHighlightCache(
      List<String> words, Map<String, Glossary> resolved) async {
    final MemcacheClient cache = MemcacheClient();
    for (final String word in words) {
      final Glossary? glossary = resolved[word];
      if (glossary == null) continue;
      // SINK: PLANTED-Dart-HR-208
      cache.queueSet('rpmtw:glossary:hl:$word', glossary.translation,
          ttlSeconds: 120);
    }
    await cache.flushPending();
  }

  /// Same cache warm-up, safe variant: every word is stripped of control characters and
  /// whitespace before it's used to build its cache key. Must NOT fire.
  static Future<void> warmHighlightCacheSafe(
      List<String> words, Map<String, Glossary> resolved) async {
    final MemcacheClient cache = MemcacheClient();
    for (final String word in words) {
      final Glossary? glossary = resolved[word];
      if (glossary == null) continue;
      final String safeWord = word.replaceAll(RegExp(r'[\x00-\x20\x7f]'), '');
      // SAFE_SINK: PLANTED-Dart-HR-208-safe
      cache.queueSet('rpmtw:glossary:hl:$safeWord', glossary.translation,
          ttlSeconds: 120);
    }
    await cache.flushPending();
  }
}
