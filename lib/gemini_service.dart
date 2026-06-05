import 'dart:convert';
import 'package:http/http.dart' as http;

// API key injected at build time via --dart-define=GEMINI_API_KEY=...
const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

class GeminiService {
  static const String _model = 'gemini-3.1-flash-lite';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models'
      '/$_model:generateContent';

  Future<AgentIntent> classifyIntent(
    String input, {
    String? normalizedHint,
  }) async {
    if (_apiKey.isEmpty) {
      throw GeminiException('GEMINI_API_KEY not set.');
    }

    final hintLine = normalizedHint != null
        ? 'ML Kit normalized: "$normalizedHint"\n'
        : '';
    final prompt =
        '$_kSystemPrompt\n\n${_realtimeContext()}${hintLine}User: "$input"\n\nReturn JSON only.';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.4,   // slightly higher — better for chat responses
        'maxOutputTokens': 512,
      },
    });

    final uri = Uri.parse('$_baseUrl?key=$_apiKey');
    final response = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw GeminiException(
          'API error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw GeminiException('No candidates in response.');
    }

    final rawText =
        candidates[0]['content']['parts'][0]['text'] as String? ?? '';
    final cleaned = rawText
        .replaceAll(RegExp(r'```json\s*'), '')
        .replaceAll(RegExp(r'```\s*'), '')
        .trim();

    try {
      return AgentIntent.fromJson(jsonDecode(cleaned) as Map<String, dynamic>);
    } catch (_) {
      return AgentIntent(intent: IntentType.unknown, raw: cleaned);
    }
  }
}

// ─── Intent model ─────────────────────────────────────────────────────────────

enum IntentType { setAlarm, setReminder, setTimer, chat, unknown }

class AgentIntent {
  final IntentType intent;
  final String? timeString;
  final String? message;
  final int? durationMinutes;
  final String? response;   // populated for CHAT intent
  final String raw;

  const AgentIntent({
    required this.intent,
    required this.raw,
    this.timeString,
    this.message,
    this.durationMinutes,
    this.response,
  });

  factory AgentIntent.fromJson(Map<String, dynamic> json) {
    final intentStr = (json['intent'] as String? ?? '').toUpperCase();
    final intent = switch (intentStr) {
      'SET_ALARM' => IntentType.setAlarm,
      'SET_REMINDER' => IntentType.setReminder,
      'SET_TIMER' => IntentType.setTimer,
      'CHAT' => IntentType.chat,
      _ => IntentType.unknown,
    };
    return AgentIntent(
      intent: intent,
      timeString: json['time'] as String?,
      message: json['message'] as String?,
      durationMinutes: json['duration_minutes'] as int?,
      response: json['response'] as String?,
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

// ─── Real-time context ────────────────────────────────────────────────────────

String _realtimeContext() {
  final now = DateTime.now();

  const days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday'
  ];
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];
  const urduDays = [
    'Somwar', 'Mangal', 'Budh', 'Jumerat',
    'Jumma', 'Hafta', 'Itwar'
  ];

  final dayEn  = days[now.weekday - 1];
  final dayUr  = urduDays[now.weekday - 1];
  final month  = months[now.month - 1];
  final hour12 = now.hour == 0 ? 12 : (now.hour > 12 ? now.hour - 12 : now.hour);
  final amPm   = now.hour < 12 ? 'AM' : 'PM';
  final amPmUr = now.hour < 12 ? 'Subah' : (now.hour < 17 ? 'Dopahar' : (now.hour < 20 ? 'Sham' : 'Raat'));
  final min    = now.minute.toString().padLeft(2, '0');
  final time24 = '${now.hour.toString().padLeft(2, '0')}:$min';

  return '''
--- REAL-TIME DEVICE DATA (injected at request time) ---
Current time  : $hour12:$min $amPm  ($time24 in 24h)  [$amPmUr]
Current date  : $dayEn, ${now.day} $month ${now.year}
Day (English) : $dayEn
Day (Roman Urdu): $dayUr
---

''';
}

// ─── System prompt ────────────────────────────────────────────────────────────

const String _kSystemPrompt = '''
You are a smart voice assistant with access to real-time device data.

At the start of each request you receive a block of REAL-TIME DEVICE DATA
(current time, date, day of week). Use it to answer time/date questions accurately.

You handle two types of input:
1. TASK commands in Roman Urdu (set alarms, reminders, timers)
2. GENERAL questions or conversation in any language

Always return a single JSON object — no markdown, no explanation, nothing else.

OUTPUT SCHEMA:
{
  "intent": "SET_ALARM" | "SET_REMINDER" | "SET_TIMER" | "CHAT" | "UNKNOWN",
  "time": "HH:mm" | null,
  "message": "string" | null,
  "duration_minutes": integer | null,
  "response": "string" | null
}

RULES FOR TASKS:
- "baje" = o\'clock. "saat baje" = "07:00"
- "subah" = AM, "sham"/"raat" = PM. "saat baje sham" = "19:00"
- Numbers: ek=1, do=2, teen=3, char=4, paanch=5, chhe=6, saat=7, aath=8, nau=9, das=10, gyarah=11, barah=12
- "aadhay ghantay" = 30 min, "ek ghanta" = 60 min, "do ghante" = 120 min
- "yaad dilao" / "reminder" → SET_REMINDER
- "alarm" / "jagao" → SET_ALARM
- "timer" / duration + "baad" → SET_TIMER
- For tasks: response field = null

RULES FOR CHAT:
- Any general question, greeting, or conversation → CHAT intent
- Put your answer in the "response" field
- Keep response under 3 sentences (it will be read aloud by TTS)
- You may respond in English or Roman Urdu — match the user\'s language
- All task fields (time, message, duration_minutes) = null for CHAT

EXAMPLES:

Input: "mera alarm 7 baje set karo"
Output: {"intent":"SET_ALARM","time":"07:00","message":null,"duration_minutes":null,"response":null}

Input: "subah 6 baje alarm lagao"
Output: {"intent":"SET_ALARM","time":"06:00","message":null,"duration_minutes":null,"response":null}

Input: "raat 10 baje alarm"
Output: {"intent":"SET_ALARM","time":"22:00","message":null,"duration_minutes":null,"response":null}

Input: "sham 5 baje meeting ka reminder"
Output: {"intent":"SET_REMINDER","time":"17:00","message":"meeting","duration_minutes":null,"response":null}

Input: "barah baje lunch ka reminder set karo"
Output: {"intent":"SET_REMINDER","time":"12:00","message":"lunch","duration_minutes":null,"response":null}

Input: "30 minute ka timer lagao"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":30,"response":null}

Input: "ek ghanta baad yaad karna"
Output: {"intent":"SET_TIMER","time":null,"message":null,"duration_minutes":60,"response":null}

Input: "hello, how are you?"
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"I\'m doing great, ready to help you! You can ask me anything or say a command like set an alarm."}

Input: "Pakistan ki capital kya hai?"
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Pakistan ki capital Islamabad hai."}

Input: "tell me a joke"
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Why do programmers prefer dark mode? Because light attracts bugs!"}

Input: "aaj ka mausam kaisa hai?"
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Mujhe real-time mausam ka data nahi milta, lekin aap weather app check kar sakte hain."}

Input: "what is 25 multiplied by 4"
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"25 multiplied by 4 is 100."}

Input: "kitne baje hain?" (assume real-time context shows 3:45 PM)
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Abhi 3:45 baj rahe hain, Sham ka waqt hai."}

Input: "what time is it?" (assume real-time context shows 9:10 AM)
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"It is currently 9:10 AM."}

Input: "aaj kon sa din hai?" (assume real-time context shows Friday)
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Aaj Jumma hai."}

Input: "what is today's date?" (assume real-time context shows 6 June 2026)
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Today is Friday, 6 June 2026."}

Input: "kal kon sa din hoga?" (assume today is Friday)
Output: {"intent":"CHAT","time":null,"message":null,"duration_minutes":null,"response":"Kal Hafta hoga."}
''';
