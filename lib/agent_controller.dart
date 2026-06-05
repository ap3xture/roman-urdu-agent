import 'package:android_intent_plus/android_intent.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import 'gemini_service.dart';
import 'mlkit_extractor.dart';

class AgentController {
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  final _extractor = MlKitExtractor();
  final _gemini = GeminiService();
  final _battery = Battery();
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

  // ─── STT ────────────────────────────────────────────────────────────────────

  Future<void> startListening({
    required void Function(String) onTranscript,
    required void Function(String) onDone,
  }) async {
    if (!_sttReady) { onDone('Microphone permission required.'); return; }
    await _stt.listen(
      onResult: (r) {
        if (r.recognizedWords.isNotEmpty) onTranscript(r.recognizedWords);
        if (r.finalResult && r.recognizedWords.isNotEmpty) onDone(r.recognizedWords);
      },
      localeId: 'ur_PK',
      listenFor: const Duration(seconds: 10),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(cancelOnError: false),
    );
  }

  Future<void> stopListening() => _stt.stop();

  // ─── Main pipeline ───────────────────────────────────────────────────────────

  Future<String> processCommand(String input) async {
    if (input.trim().isEmpty) return 'Kuch bola nahi gaya.';
    try {
      final entities = await _extractor.extract(input);
      final context = await _buildRuntimeContext();
      final intent = await _gemini.classifyIntent(
        input,
        normalizedHint: entities.normalized,
        runtimeContext: context,
      );
      return await _execute(intent, entities);
    } on GeminiException catch (e) {
      return 'API error: ${e.message}';
    } catch (_) {
      return 'Maafi, kuch masla ho gaya. Dobara koshish karein.';
    }
  }

  // ─── Real-time context builder ───────────────────────────────────────────────

  Future<String> _buildRuntimeContext() async {
    final now = DateTime.now();
    const days    = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    const daysUr  = ['Somwar','Mangal','Budh','Jumerat','Jumma','Hafta','Itwar'];
    const months  = ['January','February','March','April','May','June',
                     'July','August','September','October','November','December'];

    final dayEn  = days[now.weekday - 1];
    final dayUr  = daysUr[now.weekday - 1];
    final month  = months[now.month - 1];
    final h12    = now.hour == 0 ? 12 : (now.hour > 12 ? now.hour - 12 : now.hour);
    final amPm   = now.hour < 12 ? 'AM' : 'PM';
    final amPmUr = now.hour < 12 ? 'Subah'
                 : now.hour < 12 ? 'Subah'
                 : now.hour < 17 ? 'Dopahar'
                 : now.hour < 20 ? 'Sham'
                 : 'Raat';
    final min    = now.minute.toString().padLeft(2, '0');
    final time24 = '${now.hour.toString().padLeft(2, '0')}:$min';

    String batteryStr = 'unknown';
    try {
      final lvl   = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final stateStr = switch (state) {
        BatteryState.charging         => 'charging',
        BatteryState.discharging      => 'discharging',
        BatteryState.full             => 'full',
        BatteryState.connectedNotCharging => 'plugged in, not charging',
        _                             => 'unknown',
      };
      batteryStr = '$lvl% ($stateStr)';
    } catch (_) {}

    return '''
--- REAL-TIME DEVICE DATA ---
Time         : $h12:$min $amPm  |  $time24 (24h)  |  $amPmUr
Date         : $dayEn, ${now.day} $month ${now.year}
Day (Urdu)   : $dayUr
Battery      : $batteryStr
---''';
  }

  // ─── Intent executor ─────────────────────────────────────────────────────────

  Future<String> _execute(AgentIntent intent, ExtractedEntities entities) async {
    switch (intent.intent) {

      // ── Alarm ────────────────────────────────────────────────────────────────
      case IntentType.setAlarm:
        final time = _resolveTime(intent.timeString, entities.dateTime);
        if (time == null) return _say('Waqt samajh nahi aaya. Dobara bolein.');
        final native = await _tryIntent(AndroidIntent(
          action: 'android.intent.action.SET_ALARM',
          arguments: {
            'android.intent.extra.alarm.HOUR': time.hour,
            'android.intent.extra.alarm.MINUTES': time.minute,
            'android.intent.extra.alarm.MESSAGE': 'Roman Urdu Agent',
            'android.intent.extra.alarm.SKIP_UI': false,
            'android.intent.extra.alarm.VIBRATE': true,
          },
        ));
        if (!native) await _scheduleNotif(time.millisecondsSinceEpoch ~/ 1000, 'Alarm', 'Alarm baj raha hai!', time);
        return _say(native
            ? 'Clock app mein alarm set ho raha hai ${_fmt(time)} ke liye.'
            : 'Alarm set ho gaya ${_fmt(time)} ke liye.');

      // ── Reminder ─────────────────────────────────────────────────────────────
      case IntentType.setReminder:
        final time = _resolveTime(intent.timeString, entities.dateTime);
        if (time == null) return _say('Waqt samajh nahi aaya. Dobara bolein.');
        final title = intent.message ?? 'Reminder';
        final native = await _tryIntent(AndroidIntent(
          action: 'android.intent.action.INSERT',
          type: 'vnd.android.cursor.item/event',
          arguments: {
            'title': title,
            'beginTime': time.millisecondsSinceEpoch,
            'endTime': time.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
            'description': 'Set by Roman Urdu Agent',
          },
        ));
        if (!native) await _scheduleNotif(time.millisecondsSinceEpoch ~/ 1000 + 1, 'Reminder', title, time);
        return _say(native
            ? 'Calendar mein "$title" add ho raha hai ${_fmt(time)} ke liye.'
            : 'Reminder set ho gaya: "$title" — ${_fmt(time)} ke liye.');

      // ── Timer ─────────────────────────────────────────────────────────────────
      case IntentType.setTimer:
        final mins = intent.durationMinutes ?? 0;
        if (mins <= 0) return _say('Timer ki muddat samajh nahi aayi.');
        final native = await _tryIntent(AndroidIntent(
          action: 'android.intent.action.SET_TIMER',
          arguments: {
            'android.intent.extra.alarm.LENGTH': mins * 60,
            'android.intent.extra.alarm.MESSAGE': 'Roman Urdu Agent Timer',
            'android.intent.extra.alarm.SKIP_UI': false,
          },
        ));
        if (!native) {
          final fireAt = DateTime.now().add(Duration(minutes: mins));
          await _scheduleNotif(fireAt.millisecondsSinceEpoch ~/ 1000 + 2, 'Timer khatam!', '$mins minute ho gaye!', fireAt);
        }
        return _say(native
            ? 'Clock app mein $mins minute ka timer set ho raha hai.'
            : '$mins minute ka timer shuru ho gaya.');

      // ── Phone call ────────────────────────────────────────────────────────────
      case IntentType.makeCall:
        final number = intent.phone;
        if (number == null || number.isEmpty) {
          return _say('Phone number samajh nahi aaya.');
        }
        await _tryIntent(AndroidIntent(
          action: 'android.intent.action.DIAL',
          data: 'tel:$number',
        ));
        return _say('$number pe call kiya ja raha hai.');

      // ── WhatsApp ──────────────────────────────────────────────────────────────
      case IntentType.openWhatsApp:
        final number  = intent.phone ?? '';
        final message = intent.message ?? '';
        final uri = number.isNotEmpty
            ? Uri.parse('https://wa.me/$number?text=${Uri.encodeComponent(message)}')
            : Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}');
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication)
            .catchError((_) => false);
        if (!launched) {
          // fallback: open WhatsApp directly via intent
          await _tryIntent(const AndroidIntent(
            action: 'android.intent.action.MAIN',
            package: 'com.whatsapp',
          ));
        }
        return _say('WhatsApp khul raha hai.');

      // ── Navigation ────────────────────────────────────────────────────────────
      case IntentType.navigate:
        final dest = intent.query ?? '';
        if (dest.isEmpty) return _say('Destination samajh nahi aaya.');
        final uri = Uri.parse('google.navigation:q=${Uri.encodeComponent(dest)}');
        final launched = await launchUrl(uri, mode: LaunchMode.externalApplication)
            .catchError((_) => false);
        if (!launched) {
          await launchUrl(
            Uri.parse('https://maps.google.com/?q=${Uri.encodeComponent(dest)}'),
            mode: LaunchMode.externalApplication,
          ).catchError((_) => false);
        }
        return _say('$dest ka rasta Google Maps pe dikh raha hai.');

      // ── Web search ────────────────────────────────────────────────────────────
      case IntentType.webSearch:
        final q = intent.query ?? '';
        if (q.isEmpty) return _say('Search query samajh nahi aaya.');
        await launchUrl(
          Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(q)}'),
          mode: LaunchMode.externalApplication,
        ).catchError((_) => false);
        return _say('"$q" Google pe search ho raha hai.');

      // ── YouTube ───────────────────────────────────────────────────────────────
      case IntentType.openYoutube:
        final q = intent.query ?? '';
        final uri = q.isNotEmpty
            ? Uri.parse('https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}')
            : Uri.parse('https://www.youtube.com');
        await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
        return _say(q.isNotEmpty ? 'YouTube pe "$q" search ho raha hai.' : 'YouTube khul raha hai.');

      // ── Camera ────────────────────────────────────────────────────────────────
      case IntentType.openCamera:
        final native = await _tryIntent(const AndroidIntent(
          action: 'android.media.action.IMAGE_CAPTURE',
        ));
        if (!native) {
          await _tryIntent(const AndroidIntent(action: 'android.media.action.STILL_IMAGE_CAMERA'));
        }
        return _say('Camera khul raha hai.');

      // ── Settings ──────────────────────────────────────────────────────────────
      case IntentType.openSettings:
        final type = intent.settingType ?? 'general';
        final action = switch (type) {
          'wifi'        => 'android.settings.WIFI_SETTINGS',
          'bluetooth'   => 'android.settings.BLUETOOTH_SETTINGS',
          'mobile_data' => 'android.settings.DATA_ROAMING_SETTINGS',
          'display'     => 'android.settings.DISPLAY_SETTINGS',
          'sound'       => 'android.settings.SOUND_SETTINGS',
          _             => 'android.settings.SETTINGS',
        };
        await _tryIntent(AndroidIntent(action: action));
        final label = switch (type) {
          'wifi'        => 'WiFi',
          'bluetooth'   => 'Bluetooth',
          'mobile_data' => 'Mobile Data',
          'display'     => 'Display',
          'sound'       => 'Sound',
          _             => 'Settings',
        };
        return _say('$label settings khul rahi hai.');

      // ── Chat ─────────────────────────────────────────────────────────────────
      case IntentType.chat:
        final reply = intent.response ?? 'Mujhe samajh nahi aaya, dobara poochein.';
        return _say(reply);

      // ── Unknown ───────────────────────────────────────────────────────────────
      case IntentType.unknown:
        return _say('Samajh nahi aaya. Alarm, call, WhatsApp, maps, YouTube, camera, ya kuch bhi pooch sakte hain.');
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  Future<bool> _tryIntent(AndroidIntent intent) async {
    if (kIsWeb) return false;
    try { await intent.launch(); return true; } catch (_) { return false; }
  }

  Future<void> _scheduleNotif(int id, String title, String body, DateTime at) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'roman_urdu_agent_channel', 'Roman Urdu Agent',
        importance: Importance.max, priority: Priority.high,
        playSound: true, enableVibration: true,
      ),
    );
    await _notifications.zonedSchedule(
      id, title, body,
      tz.TZDateTime.from(at, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
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
