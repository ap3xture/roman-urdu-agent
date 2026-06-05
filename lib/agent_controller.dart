import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'gemini_service.dart';
import 'mlkit_extractor.dart';

class AgentController {
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  final _extractor = MlKitExtractor();
  final _gemini = GeminiService();

  // Only used for timers — alarms/reminders go to native Clock/Calendar
  final _notifications = FlutterLocalNotificationsPlugin();

  bool _sttReady = false;

  Future<void> init() async {
    await [Permission.microphone, Permission.notification].request();

    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _sttReady = await _stt.initialize(onError: (_) {}, onStatus: (_) {});

    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(const InitializationSettings(android: android));
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _extractor.ensureModelReady().catchError((_) {});
  }

  Future<void> startListening({
    required void Function(String) onTranscript,
    required void Function(String) onDone,
  }) async {
    if (!_sttReady) {
      onDone('Microphone permission required.');
      return;
    }
    await _stt.listen(
      onResult: (result) {
        if (result.recognizedWords.isNotEmpty) {
          onTranscript(result.recognizedWords);
        }
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          onDone(result.recognizedWords);
        }
      },
      localeId: 'ur_PK',
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(cancelOnError: false),
    );
  }

  Future<void> stopListening() => _stt.stop();

  Future<String> processCommand(String input) async {
    if (input.trim().isEmpty) return 'Kuch bola nahi gaya.';
    try {
      final entities = await _extractor.extract(input);
      final intent = await _gemini.classifyIntent(
        input,
        normalizedHint: entities.normalized,
      );
      return await _execute(intent, entities);
    } on GeminiException catch (e) {
      return 'API error: ${e.message}';
    } catch (e) {
      return 'Maafi, kuch masla ho gaya. Dobara koshish karein.';
    }
  }

  Future<String> _execute(AgentIntent intent, ExtractedEntities entities) async {
    switch (intent.intent) {

      // ── Native Clock alarm ─────────────────────────────────────────────────
      case IntentType.setAlarm:
        final time = _resolveTime(intent.timeString, entities.dateTime);
        if (time == null) {
          return await _say('Waqt samajh nahi aaya. Dobara bolein.');
        }
        if (!kIsWeb) {
          await AndroidIntent(
            action: 'android.intent.action.SET_ALARM',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.HOUR': time.hour,
              'android.intent.extra.alarm.MINUTES': time.minute,
              'android.intent.extra.alarm.MESSAGE': 'Roman Urdu Agent',
              'android.intent.extra.alarm.SKIP_UI': false,
              'android.intent.extra.alarm.VIBRATE': true,
            },
          ).launch();
        }
        return await _say('Clock app mein alarm set ho raha hai ${_fmt(time)} ke liye.');

      // ── Native Calendar reminder ───────────────────────────────────────────
      case IntentType.setReminder:
        final time = _resolveTime(intent.timeString, entities.dateTime);
        if (time == null) {
          return await _say('Waqt samajh nahi aaya. Dobara bolein.');
        }
        final title = intent.message ?? 'Reminder';
        if (!kIsWeb) {
          await AndroidIntent(
            action: 'android.intent.action.INSERT',
            type: 'vnd.android.cursor.item/event',
            arguments: <String, dynamic>{
              'title': title,
              'beginTime': time.millisecondsSinceEpoch,
              'endTime': time.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
              'allDay': false,
              'description': 'Set by Roman Urdu Agent',
            },
          ).launch();
        }
        return await _say('Calendar mein reminder add ho raha hai: "$title" — ${_fmt(time)} ke liye.');

      // ── Native Clock timer ─────────────────────────────────────────────────
      case IntentType.setTimer:
        final mins = intent.durationMinutes ?? 0;
        if (mins <= 0) {
          return await _say('Timer ki muddat samajh nahi aayi.');
        }
        if (!kIsWeb) {
          await AndroidIntent(
            action: 'android.intent.action.SET_TIMER',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.LENGTH': mins * 60,
              'android.intent.extra.alarm.MESSAGE': 'Roman Urdu Agent Timer',
              'android.intent.extra.alarm.SKIP_UI': false,
            },
          ).launch();
        }
        return await _say('Clock app mein $mins minute ka timer set ho raha hai.');

      // ── General chat ───────────────────────────────────────────────────────
      case IntentType.chat:
        final reply = intent.response ?? 'Mujhe samajh nahi aaya, dobara poochein.';
        return await _say(reply);

      // ── Unknown ────────────────────────────────────────────────────────────
      case IntentType.unknown:
        return await _say(
            'Yeh samajh nahi aaya. Alarm, reminder, timer set kar sakte hain, ya kuch bhi pooch sakte hain.');
    }
  }

  DateTime? _resolveTime(String? geminiTime, DateTime? mlKitTime) {
    if (geminiTime != null) {
      final parts = geminiTime.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null && h >= 0 && h < 24 && m >= 0 && m < 60) {
          final now = DateTime.now();
          var t = DateTime(now.year, now.month, now.day, h, m);
          if (t.isBefore(now)) t = t.add(const Duration(days: 1));
          return t;
        }
      }
    }
    return mlKitTime;
  }

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  Future<String> _say(String text) async {
    await _tts.stop();
    await _tts.speak(text);
    return text;
  }

  void dispose() {
    _extractor.close();
    _tts.stop();
    _stt.cancel();
  }
}
