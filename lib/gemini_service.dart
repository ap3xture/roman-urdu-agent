import 'dart:convert';
import 'package:http/http.dart' as http;

const String _apiKey = String.fromEnvironment('GEMINI_API_KEY');

class GeminiService {
  static const String _model = 'gemini-3.1-flash-lite';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models'
      '/$_model:generateContent';

  Future<AgentIntent> classifyIntent(
    String input, {
    String? normalizedHint,
    String? runtimeContext, // date/time/battery injected by AgentController
  }) async {
    if (_apiKey.isEmpty) throw GeminiException('GEMINI_API_KEY not set.');

    final hintLine =
        normalizedHint != null ? 'ML Kit normalized: "$normalizedHint"\n' : '';
    final contextBlock = runtimeContext != null ? '$runtimeContext\n' : '';

    final prompt =
        '$_kSystemPrompt\n\n$contextBlock${hintLine}User: "$input"\n\nReturn JSON only.';

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {'temperature': 0.4, 'maxOutputTokens': 512},
    });

    final uri = Uri.parse('$_baseUrl?key=$_apiKey');
    final response = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw GeminiException('API error ${response.statusCode}: ${response.body}');
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

enum IntentType {
  setAlarm,
  setReminder,
  setTimer,
  makeCall,
  openWhatsApp,
  navigate,
  webSearch,
  openYoutube,
  openCamera,
  openSettings,
  chat,
  unknown,
}

class AgentIntent {
  final IntentType intent;
  // task fields
  final String? timeString;
  final int? durationMinutes;
  final String? message;
  // action fields
  final String? phone;
  final String? query;
  final String? settingType;
  // chat
  final String? response;
  final String raw;

  const AgentIntent({
    required this.intent,
    required this.raw,
    this.timeString,
    this.durationMinutes,
    this.message,
    this.phone,
    this.query,
    this.settingType,
    this.response,
  });

  factory AgentIntent.fromJson(Map<String, dynamic> j) {
    final intent = switch ((j['intent'] as String? ?? '').toUpperCase()) {
      'SET_ALARM' => IntentType.setAlarm,
      'SET_REMINDER' => IntentType.setReminder,
      'SET_TIMER' => IntentType.setTimer,
      'MAKE_CALL' => IntentType.makeCall,
      'OPEN_WHATSAPP' => IntentType.openWhatsApp,
      'NAVIGATE' => IntentType.navigate,
      'WEB_SEARCH' => IntentType.webSearch,
      'OPEN_YOUTUBE' => IntentType.openYoutube,
      'OPEN_CAMERA' => IntentType.openCamera,
      'OPEN_SETTINGS' => IntentType.openSettings,
      'CHAT' => IntentType.chat,
      _ => IntentType.unknown,
    };
    return AgentIntent(
      intent: intent,
      timeString: j['time'] as String?,
      durationMinutes: j['duration_minutes'] as int?,
      message: j['message'] as String?,
      phone: j['phone'] as String?,
      query: j['query'] as String?,
      settingType: j['setting_type'] as String?,
      response: j['response'] as String?,
      raw: j.toString(),
    );
  }
}

class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);
  @override
  String toString() => 'GeminiException: $message';
}

// ─── System prompt ────────────────────────────────────────────────────────────

const String _kSystemPrompt = r'''
You are a smart Android voice assistant with access to real-time device data.
A REAL-TIME DEVICE DATA block is injected at the top of each request — use it
for time, date, battery, and day questions.

Always return a SINGLE JSON object. No markdown. No explanation.

─── OUTPUT SCHEMA ───
{
  "intent": one of the values below,
  "time": "HH:mm" | null,
  "duration_minutes": integer | null,
  "message": string | null,
  "phone": string (digits only) | null,
  "query": string | null,
  "setting_type": "wifi" | "bluetooth" | "mobile_data" | "display" | "sound" | "general" | null,
  "response": string | null
}

─── INTENTS ───
SET_ALARM        → set alarm in Clock app
SET_REMINDER     → add event in Calendar app
SET_TIMER        → start countdown timer in Clock app
MAKE_CALL        → dial / call a phone number
OPEN_WHATSAPP    → open WhatsApp (optionally to a number with a message)
NAVIGATE         → open Google Maps to a destination
WEB_SEARCH       → search the web on Google
OPEN_YOUTUBE     → search or play on YouTube
OPEN_CAMERA      → open device camera
OPEN_SETTINGS    → open a device settings page
CHAT             → general question / conversation (put answer in "response")
UNKNOWN          → cannot determine intent

─── ROMAN URDU RULES ───
Time:
  "baje" = o'clock | ek=1 do=2 teen=3 char=4 paanch=5 chhe=6 saat=7 aath=8 nau=9 das=10 gyarah=11 barah=12
  subah=AM | sham/raat=PM | dopahar=noon-PM
Duration:
  aadhay ghantay=30min | ek ghanta=60min | do ghante=120min
Actions:
  "alarm/jagao" → SET_ALARM
  "yaad dilao/reminder" → SET_REMINDER
  "timer" → SET_TIMER
  "call karo/phone karo/ring karo" → MAKE_CALL
  "WhatsApp karo/WhatsApp pe bhejo" → OPEN_WHATSAPP
  "rasta dikhao/navigate/maps" → NAVIGATE
  "search karo/dhundo/Google pe" → WEB_SEARCH
  "YouTube pe/video dhundo" → OPEN_YOUTUBE
  "camera/selfie/photo" → OPEN_CAMERA
  "settings kholo/WiFi/Bluetooth/silent mode" → OPEN_SETTINGS
  anything else → CHAT

─── EXAMPLES ───

Input: "mera alarm 7 baje set karo"
Output: {"intent":"SET_ALARM","time":"07:00","duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":null}

Input: "sham 5 baje meeting ka reminder"
Output: {"intent":"SET_REMINDER","time":"17:00","duration_minutes":null,"message":"meeting","phone":null,"query":null,"setting_type":null,"response":null}

Input: "30 minute ka timer"
Output: {"intent":"SET_TIMER","time":null,"duration_minutes":30,"message":null,"phone":null,"query":null,"setting_type":null,"response":null}

Input: "03001234567 pe call karo"
Output: {"intent":"MAKE_CALL","time":null,"duration_minutes":null,"message":null,"phone":"03001234567","query":null,"setting_type":null,"response":null}

Input: "Ali ko WhatsApp karo"
Output: {"intent":"OPEN_WHATSAPP","time":null,"duration_minutes":null,"message":"Ali ko","phone":null,"query":null,"setting_type":null,"response":null}

Input: "0311 ko WhatsApp pe salam bhejo"
Output: {"intent":"OPEN_WHATSAPP","time":null,"duration_minutes":null,"message":"salam","phone":"0311","query":null,"setting_type":null,"response":null}

Input: "Lahore ka rasta dikhao"
Output: {"intent":"NAVIGATE","time":null,"duration_minutes":null,"message":null,"phone":null,"query":"Lahore","setting_type":null,"response":null}

Input: "nearest hospital maps pe dikhao"
Output: {"intent":"NAVIGATE","time":null,"duration_minutes":null,"message":null,"phone":null,"query":"nearest hospital","setting_type":null,"response":null}

Input: "cricket score Google pe search karo"
Output: {"intent":"WEB_SEARCH","time":null,"duration_minutes":null,"message":null,"phone":null,"query":"cricket score","setting_type":null,"response":null}

Input: "Atif Aslam ka gana YouTube pe lagao"
Output: {"intent":"OPEN_YOUTUBE","time":null,"duration_minutes":null,"message":null,"phone":null,"query":"Atif Aslam","setting_type":null,"response":null}

Input: "camera kholo"
Output: {"intent":"OPEN_CAMERA","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":null}

Input: "WiFi settings kholo"
Output: {"intent":"OPEN_SETTINGS","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":"wifi","response":null}

Input: "Bluetooth on karo"
Output: {"intent":"OPEN_SETTINGS","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":"bluetooth","response":null}

Input: "phone silent karo"
Output: {"intent":"OPEN_SETTINGS","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":"sound","response":null}

Input: "kitne baje hain?" (use REAL-TIME DEVICE DATA for answer)
Output: {"intent":"CHAT","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":"Abhi 3:45 baj rahe hain, Sham ka waqt hai."}

Input: "battery kitni hai?" (use REAL-TIME DEVICE DATA for answer)
Output: {"intent":"CHAT","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":"Aapki battery 72% hai aur charge ho rahi hai."}

Input: "aaj kon sa din hai?"
Output: {"intent":"CHAT","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":"Aaj Jumma hai."}

Input: "Pakistan ki capital kya hai?"
Output: {"intent":"CHAT","time":null,"duration_minutes":null,"message":null,"phone":null,"query":null,"setting_type":null,"response":"Pakistan ki capital Islamabad hai."}
''';
