import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/transit.dart';

/// Handles local (on-device) scheduling of upcoming transit notifications.
/// Strategy (#3 Hybrid): each prediction run schedules a rolling window (default 24h)
/// with a heads-up notification lead time, replacing previous ones to avoid duplication.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _prefsKey = 'scheduled_transit_ids_v1';
  static const int defaultLeadMinutes = 10; // TODO: make user-configurable
  static const int maxEventsToSchedule = 40; // keep well under iOS 64 pending limit

  static Future<void> init() async {
    if (_initialized) return;

    // Timezone initialization (best-effort). We rely on the device local zone.
    try {
      tz.initializeTimeZones();
      // NOTE: We intentionally *do not* call tz.setLocalLocation with a named zone,
      // tz.local should reflect system local zone when available. This avoids needing native channel.
    } catch (_) {}

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();

    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: darwinSettings, macOS: darwinSettings),
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _onNotificationResponse,
    );

    // Request permissions (iOS + Android 13+); ignore failures.
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      await androidImpl?.requestNotificationsPermission();
      // ignore: avoid_print
      print('[Notifications] Android permission requested');
    } catch (e) {
      // ignore: avoid_print
      print('[Notifications] Android permission failed: $e');
    }

    try {
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true, badge: true, sound: true,
      );
      // ignore: avoid_print
      print('[Notifications] iOS permissions requested');
    } catch (e) {
      // ignore: avoid_print
      print('[Notifications] iOS permission failed: $e');
    }

    _initialized = true;
    // ignore: avoid_print
    print('[Notifications] Service initialized successfully');
  }

  /// Test notification to verify the system works - shows immediately
  static Future<void> sendTestNotification() async {
    if (!_initialized) {
      // ignore: avoid_print
      print('[Notifications] Not initialized, calling init first');
      await init();
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'test_channel',
        'Test Notifications',
        channelDescription: 'Test notifications to verify system works',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBadge: false),
      macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBadge: false),
    );

    try {
      await _plugin.show(
        99999, // unique test ID
        'HelioSelene Test',
        'Notifications are working! 🛰️',
        details,
        payload: 'test',
      );
      // ignore: avoid_print
      print('[Notifications] Test notification sent successfully');
    } catch (e) {
      // ignore: avoid_print
      print('[Notifications] Test notification failed: $e');
    }
  }

  static Future<void> _onNotificationResponse(NotificationResponse response) async {
    // ignore: avoid_print
    print('[Notifications] User tapped notification: ${response.payload}');
    // Reserved for potential expansion: open detail screen, etc.
    // We could store payload = transitId to deep-link later.
  }

  /// Clear previously scheduled transit notifications we own.
  static Future<void> clearScheduled() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsKey)?.map(int.parse).toList() ?? [];
    for (final id in ids) {
      await _plugin.cancel(id);
    }
    await prefs.remove(_prefsKey);
  }

  /// Schedule a rolling window of upcoming transits within [windowHours]. Replaces previous schedule.
  static Future<void> scheduleRollingWindow(List<Transit> allTransits, {int windowHours = 24, int? leadMinutes}) async {
    if (!_initialized) return;
    final now = DateTime.now();
    final windowEnd = now.add(Duration(hours: windowHours));
    final lead = leadMinutes ?? defaultLeadMinutes;

    // Filter future events within window and sort.
    final candidates = allTransits
        .where((t) => t.timeUtc.toLocal().isAfter(now) && t.timeUtc.toLocal().isBefore(windowEnd))
        .toList()
      ..sort((a,b)=> a.timeUtc.compareTo(b.timeUtc));

    if (candidates.isEmpty) {
      await clearScheduled();
      // ignore: avoid_print
      print('[Notifications] No upcoming transits to schedule');
      return;
    }

    // Trim to maximum (each event may schedule up to 2 notifications: heads-up + start) => limit events to half.
    final maxEvents = (maxEventsToSchedule / 2).floor();
    final trimmed = candidates.take(maxEvents).toList();

    // Cancel old schedule first.
    await clearScheduled();

    final prefs = await SharedPreferences.getInstance();
    final newIds = <int>[];

    for (final t in trimmed) {
      final localStart = t.timeUtc.toLocal();
      final headsUp = localStart.subtract(Duration(minutes: lead));
      final baseId = (t.timeUtc.millisecondsSinceEpoch & 0x7FFFFFFF); // 31-bit
      // Heads-up
      if (headsUp.isAfter(now)) {
        final id = baseId; // stable
        await _zonedOneShot(id, headsUp, title: 'Transit soon', body: _summaryLine(t, prefix: 'In $lead min:'));
        newIds.add(id);
      }
      // Start notification
      if (localStart.isAfter(now)) {
        final id = baseId ^ 0x1; // distinct
        await _zonedOneShot(id, localStart, title: 'Transit now', body: _summaryLine(t));
        newIds.add(id);
      }
    }

    await prefs.setStringList(_prefsKey, newIds.map((e)=> e.toString()).toList());
    // ignore: avoid_print
    print('[Notifications] Scheduled ${newIds.length} notifications for ${trimmed.length} transit events');
  }

  static String _summaryLine(Transit t, {String prefix = ''}) {
    final buf = StringBuffer();
    if (prefix.isNotEmpty) buf.write(prefix + ' ');
    buf.write(t.body);
    if (t.kind.isNotEmpty) buf.write(' ${t.kind}');
    if (t.satellite != null) buf.write(' • ${t.satellite}');
    buf.write(' @ ${t.timeUtc.toLocal().toIso8601String().substring(11,16)}');
    return buf.toString();
  }

  static Future<void> _zonedOneShot(int id, DateTime fireLocal, {required String title, required String body}) async {
    // Convert to tz if available, else fallback to immediate scheduling check.
    tz.TZDateTime scheduled;
    try {
      scheduled = tz.TZDateTime.from(fireLocal, tz.local);
    } catch (_) {
      scheduled = tz.TZDateTime.from(DateTime.now().add(const Duration(seconds: 5)), tz.local);
    }

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'transits',
        'Upcoming Transits',
        channelDescription: 'Alerts for predicted satellite transits',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        visibility: NotificationVisibility.public,
      ),
      iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBadge: false),
      macOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBadge: false),
    );

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'transit',
      matchDateTimeComponents: null,
    );
  }
}
