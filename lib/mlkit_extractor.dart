import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';

class MlKitExtractor {
  late final EntityExtractor _extractor;
  bool _isModelDownloaded = false;

  MlKitExtractor() {
    _extractor = EntityExtractor(language: EntityExtractorLanguage.english);
  }

  Future<void> ensureModelReady() async {
    if (_isModelDownloaded) return;
    // Warm up extractor — triggers model download on first run (needs internet)
    await _extractor.extractEntities('test 10 AM tomorrow');
    _isModelDownloaded = true;
  }

  Future<void> close() async {
    await _extractor.close();
  }

  /// Translates common Roman Urdu time/date tokens into English so ML Kit
  /// can find DateTime entities in the normalized string.
  String normalizeRomanUrdu(String input) {
    const Map<String, String> timeMap = {
      'ek baje': '1 o\'clock',
      'do baje': '2 o\'clock',
      'teen baje': '3 o\'clock',
      'char baje': '4 o\'clock',
      'paanch baje': '5 o\'clock',
      'chhe baje': '6 o\'clock',
      'saat baje': '7 o\'clock',
      'aath baje': '8 o\'clock',
      'nau baje': '9 o\'clock',
      'das baje': '10 o\'clock',
      'gyarah baje': '11 o\'clock',
      'barah baje': '12 o\'clock',
      'subah': 'AM',
      'sham': 'PM',
      'dopahar': 'PM',
      'raat ko': 'PM',
      'raat': 'PM',
      'aaj': 'today',
      'kal': 'tomorrow',
      'parso': 'day after tomorrow',
      'somwar': 'monday',
      'mangal': 'tuesday',
      'budh': 'wednesday',
      'jumerat': 'thursday',
      'jumma': 'friday',
      'hafta': 'saturday',
      'itwar': 'sunday',
    };

    String normalized = input.toLowerCase();
    // Longest match first to avoid partial replacements
    final keys = timeMap.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      normalized = normalized.replaceAll(key, timeMap[key]!);
    }
    return normalized;
  }

  Future<ExtractedEntities> extract(String romanUrduText) async {
    final normalized = normalizeRomanUrdu(romanUrduText);

    List<EntityAnnotation> annotations = [];
    try {
      annotations = await _extractor.extractEntities(normalized);
    } catch (_) {
      // Model not yet downloaded or no entities found — Gemini handles intent anyway
    }

    DateTime? dateTime;
    String? address;

    for (final annotation in annotations) {
      for (final entity in annotation.entities) {
        if (entity is DateTimeEntity && dateTime == null) {
          final ts = entity.timestamp;
          if (ts > 0) {
            dateTime = DateTime.fromMillisecondsSinceEpoch(ts);
          }
        }
        if (entity is AddressEntity && address == null) {
          address = annotation.text;
        }
      }
    }

    return ExtractedEntities(
      original: romanUrduText,
      normalized: normalized,
      dateTime: dateTime,
      address: address,
      rawAnnotations: annotations,
    );
  }
}

class ExtractedEntities {
  final String original;
  final String normalized;
  final DateTime? dateTime;
  final String? address;
  final List<EntityAnnotation> rawAnnotations;

  const ExtractedEntities({
    required this.original,
    required this.normalized,
    this.dateTime,
    this.address,
    required this.rawAnnotations,
  });
}
