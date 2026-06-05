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
  final _notifications = FlutterLocalNotificationsPlugin();

  bool _sttReady = false;

  Future<void> init() async {
    // Permissions
    await [Permission.microphone, Permission.notification].request();

    // TTS — Indian English approximates Roman Urdu pronunciation well
    await _tts.setLanguage('en-IN');
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    // STT
    _sttReady = await _stt.initialize(
      onError: (_) {},
      onStatus: (_) {},
    );

    // Notifications
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
      const InitializationSettings(android: android),
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    // Warm up ML Kit model in background
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
      // Try Urdu locale first; falls back gracefully on devices without it
      localeId: 'ur_PK',
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
      cancelOnError: false,
    );
  }

  Future<void> stopListening() => _stt.stop();

  Future<String> processCommand(String input) async {
    if (input.trim().isEmpty) return 'Kuch bola nahi gaya.';

    try {
      // Step 1: ML Kit entity extraction
      final entities = await _extractor.extract(input);

      // Step 2: Gemini intent classification
      final intent = await _gemini.classifyIntent(
        input,
        normalizedHint: entities.normalized,
      );

      // Step 3: Execute and confirm
      return await _executeIntent(intent, entities);
    } on GeminiException catch (e) {
      return 'API error: ${e.message}';
    } catch (e) {
      return 'Maafi, kuch masla ho gaya. Dobara koshish karein.';
    }
  }

  Future<String> _executeIntent(
    AgentIntent intent,
    ExtractedEntities entities,
  ) async {
    switch (intent.intent) {
      case IntentType.setAlarm:
        final time = _resolveScheduledTime(intent.timeString, entities.dateTime);
        if (time == null) {
          const msg = 'Waqt samajh nahi aaya. Mثال: "saat baje alarm lagao"';
          await _speak(msg);
          return msg;
        }
        await _postNotification(
          id: time.millisecondsSinceEpoch ~/ 1000,
          title: 'Alarm',
          body: 'Aapka alarm baj raha hai!',
          scheduledTime: time,
        );
        final alarmMsg =
            'Alarm set ho gaya ${_fmt(time)} ke liye.';
        await _speak(alarmMsg);
        return alarmMsg;

      case IntentType.setReminder:
        final time = _resolveScheduledTime(intent.timeString, entities.dateTime);
        if (time == null) {
          const msg = 'Waqt samajh nahi aaya. Mثال: "5 baje meeting ka reminder"';
          await _speak(msg);
          return msg;
        }
        final reminderBody = intent.message ?? 'Aapka reminder!';
        await _postNotification(
          id: time.millisecondsSinceEpoch ~/ 1000 + 1,
          title: 'Reminder',
          body: reminderBody,
          scheduledTime: time,
        );
        final reminderMsg =
            'Reminder set ho gaya: "$reminderBody" — ${_fmt(time)} ke liye.';
        await _speak(reminderMsg);
        return reminderMsg;

      case IntentType.setTimer:
        final mins = intent.durationMinutes ?? 0;
        if (mins <= 0) {
          const msg = 'Timer ki muddat samajh nahi aayi.';
          await _speak(msg);
          return msg;
        }
        final fireAt = DateTime.now().add(Duration(minutes: mins));
        await _postNotification(
          id: fireAt.millisecondsSinceEpoch ~/ 1000 + 2,
          title: 'Timer khatam!',
          body: '$mins minute poore ho gaye!',
          scheduledTime: fireAt,
        );
        final timerMsg = '$mins minute ka timer shuru ho gaya.';
        await _speak(timerMsg);
        return timerMsg;

      case IntentType.unknown:
        const msg =
            'Yeh command samajh nahi aayi. Alarm, reminder, ya timer set karein.';
        await _speak(msg);
        return msg;
    }
  }

  DateTime? _resolveScheduledTime(String? geminiTime, DateTime? mlKitTime) {
    if (geminiTime != null) {
      final parts = geminiTime.split(':');
      if (parts.length == 2) {
        final h = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        if (h != null && m != null && h >= 0 && h < 24 && m >= 0 && m < 60) {
          final now = DateTime.now();
          var scheduled = DateTime(now.year, now.month, now.day, h, m);
          if (scheduled.isBefore(now)) {
            scheduled = scheduled.add(const Duration(days: 1));
          }
          return scheduled;
        }
      }
    }
    return mlKitTime;
  }

  Future<void> _postNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'roman_urdu_agent_channel',
      'Roman Urdu Agent',
      channelDescription: 'Alarms and reminders from Roman Urdu Agent',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const details = NotificationDetails(android: androidDetails);

    final tzScheduled = tz.TZDateTime.from(scheduledTime, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tzScheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: null,
    );
  }

  String _fmt(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  void dispose() {
    _extractor.close();
    _tts.stop();
    _stt.cancel();
  }
}
