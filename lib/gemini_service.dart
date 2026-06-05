import 'dart:convert';
import 'package:http/http.dart' as http;

// API key is injected at build time via --dart-define=GEMINI_API_KEY=...
// Set it as a GitHub Secret named GEMINI_API_KEY — never hardcode here.
const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

class GeminiService {
  static const String _model = 'gemini-2.5-flash';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models'
      '/$_model:generateContent';

  Future<AgentIntent> classifyIntent(
    String romanUrduInput, {
    String? normalizedHint,
  }) async {
    if (_apiKey.isEmpty) {
      throw GeminiException(
          'GEMINI_API_KEY not set. Build with --dart-define=GEMINI_API_KEY=YOUR_KEY');
    }

    final prompt = _buildPrompt(romanUrduInput, normalizedHint);

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 256,
      },
    });

    final uri = Uri.parse('$_baseUrl?key=$_apiKey');
    final response = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw GeminiException(
          'API error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw GeminiException('No candidates in response: ${response.body}');
    }

    final rawText =
        candidates[0]['content']['parts'][0]['text'] as String? ?? '';

    // Strip markdown fences if Gemini wrapped them anyway
    final cleaned = rawText
        .replaceAll(RegExp(r'```json\s*'), '')
        .replaceAll(RegExp(r'```\s*'), '')
        .trim();

    try {
      final json = jsonDecode(cleaned) as Map<String, dynamic>;
      return AgentIntent.fromJson(json);
    } catch (_) {
      return AgentIntent(intent: IntentType.unknown, raw: cleaned);
    }
  }

  String _buildPrompt(String input, String? hint) {
    final hintLine =
        hint != null ? 'ML Kit normalized text: "$hint"\n' : '';
    return '$_kSystemPrompt\n\n${hintLine}User input: "$input"\n\nReturn JSON only.';
  }
}

// ─── Intent model ─────────────────────────────────────────────────────────────

enum IntentType { setAlarm, setReminder, setTimer, unknown }

class AgentIntent {
  final IntentType intent;
  final String? timeString;
  final String? message;
  final int? durationMinutes;
  final String raw;

  const AgentIntent({
    required this.intent,
    required this.raw,
    this.timeString,
    this.message,
    this.durationMinutes,
  });

  factory AgentIntent.fromJson(Map<String, dynamic> json) {
    final intentStr = (json['intent'] as String? ?? '').toUpperCase();
    final intent = switch (intentStr) {
      'SET_ALARM' => IntentType.setAlarm,
      'SET_REMINDER' => IntentType.setReminder,
      'SET_TIMER' => IntentType.setTimer,
      _ => IntentType.unknown,
    };
    return AgentIntent(
      intent: intent,
      timeString: json['time'] as String?,
      message: json['message'] as String?,
      durationMinutes: json['duration_minutes'] as int?,
      raw: json.toString(),
    );
  }
}

class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);
  @override
  String toString() => 'GeminiException: $message';
}

// ─── Few-shot system prompt ───────────────────────────────────────────────────

const String _kSystemPrompt = '''
You are a strict intent-parsing engine for Roman Urdu voice commands.
Your ONLY job is to return a JSON object — nothing else. No explanation, no markdown, no code fences.

INTENTS you must classify:
- SET_ALARM      → User wants to set an alarm at a specific time
- SET_REMINDER   → User wants a reminder with a message at a time
- SET_TIMER      → User wants a countdown timer for N minutes/hours
- UNKNOWN        → Cannot determine a supported intent

OUTPUT SCHEMA (always return all fields, use null if not applicable):
{
  "intent": "SET_ALARM" | "SET_REMINDER" | "SET_TIMER" | "UNKNOWN",
  "time": "HH:mm" | null,
  "message": "string" | null,
  "duration_minutes": integer | null
}

RULES:
- "baje" means o\'clock. "7 baje" = "07:00"
- "subah" = AM, "sham" / "raat" = PM. "saat baje sham" = "19:00"
- "aadhay ghantay" = 30 minutes, "ek ghanta" = 60 minutes
- "do ghante" = 120 minutes, "teen ghante" = 180 minutes
- Numbers in Roman Urdu: ek=1, do=2, teen=3, char=4, paanch=5, chhe=6, saat=7, aath=8, nau=9, das=10, gyarah=11, barah=12
- "yaad dilao" or "reminder" → SET_REMINDER
- "alarm" or "jagao" → SET_ALARM
- "timer" or "baad" with duration → SET_TIMER
- Keep the reminder message text in "message" as the task topic (English or Roman Urdu)
- If time is ambiguous and no AM/PM clue, prefer the next upcoming time

EXAMPLES — study these carefully:

Input: "mera alarm 7 baje set karo"
Output: {"intent":"SET_ALARM","time":"07:00","message":null,"duration_minutes":null}

Input: "subah 6 baje alarm lagao"
Output: {"intent":"SET_ALARM","time":"06:00","message":null,"duration_minutes":null}

Input: "raat 10 baje alarm"
Output: {"intent":"SET_ALARM","time":"22:00","message":null,"duration_minutes":null}

Input: "sham 5 baje mujhe meeting ki yaad dilao"
Output: {"intent":"SET_REMINDER","time":"17:00","message":"meeting","duration_minutes":null}

Input: "kal subah 8:30 baje doctor appointment ka reminder set karo"
Output: {"intent":"SET_REMINDER","time":"08:30","message":"doctor appointment","duration_minutes":null}

Input: "namaz ki yaad 1 baje dopahar ko dilao"
Output: {"intent":"SET_REMINDER","time":"13:00","message":"namaz","duration_minutes":null}

Input: "30 minute ka timer lagao"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":30}

Input: "ek ghanta baad yaad karna"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":60}

Input: "paanch minute ka timer"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":5}

Input: "do ghante baad alarm"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":120}

Input: "barah baje lunch ka reminder"
Output: {"intent":"SET_REMINDER","time":"12:00","message":"lunch","duration_minutes":null}

Input: "hello"
Output: {"intent":"UNKNOWN","time":null,"message":null,"duration_minutes":null}

Input: "aaj ka mausam kaisa hai"
Output: {"intent":"UNKNOWN","time":null,"message":null,"duration_minutes":null}
''';
