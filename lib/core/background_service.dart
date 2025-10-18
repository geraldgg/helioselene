import 'dart:async';
import 'dart:io' show Platform;
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/ffi.dart';
import '../core/notification_service.dart';
import '../models/transit.dart';

/// Background service using android_alarm_manager_plus for periodic predictions.
/// Replaces the incompatible workmanager plugin.
class BackgroundService {
  static const int _alarmId = 1001;
  static const String _enabledKey = 'background_refresh_enabled';
  static const String _lastRunKey = 'background_last_run';
  static const String _lastSuccessKey = 'background_last_success';
  static const String _lastErrorKey = 'background_last_error';

  static bool get isSupported => Platform.isAndroid;

  /// Update the persistent background service status notification (Android only).
  static Future<void> updateStatusNotification() async {
    final enabled = await isEnabled();
    if (!enabled) {
      await NotificationService.hideServiceStatus();
      return;
    }
    final lastRun = await getLastRun();
    final lastSuccess = await getLastSuccess();
    final lastError = await getLastError();
    await NotificationService.showServiceStatus(
      enabled: enabled,
      lastRun: lastRun,
      lastSuccess: lastSuccess,
      lastError: lastError,
    );
  }

  /// Initialize the background service (call once at app startup)
  static Future<void> initialize() async {
    if (!isSupported) {
      print('[BackgroundService] Skipped initialization (unsupported platform)');
      return;
    }

    try {
      await AndroidAlarmManager.initialize();

      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_enabledKey) ?? true; // Default: enabled

      if (enabled) {
        await _schedulePeriodicTask();
        print('[BackgroundService] Initialized and scheduled');
      } else {
        print('[BackgroundService] Disabled by user');
      }

      // Show initial status notification
      await updateStatusNotification();
    } catch (e) {
      print('[BackgroundService] Initialization failed: $e');
    }
  }

  /// Schedule the periodic background task (runs daily)
  static Future<void> _schedulePeriodicTask() async {
    if (!isSupported) return;

    await AndroidAlarmManager.periodic(
      const Duration(hours: 24),
      _alarmId,
      _backgroundTaskCallback,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  }

  /// Enable background refresh
  static Future<void> enable() async {
    if (!isSupported) {
      print('[BackgroundService] Enable ignored (unsupported platform)');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, true);
    await _schedulePeriodicTask();
    print('[BackgroundService] Enabled');
    await updateStatusNotification();
  }

  /// Disable background refresh and cancel pending tasks
  static Future<void> disable() async {
    if (!isSupported) {
      print('[BackgroundService] Disable ignored (unsupported platform)');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    await AndroidAlarmManager.cancel(_alarmId);
    print('[BackgroundService] Disabled');
    await updateStatusNotification();
  }

  /// Check if background refresh is enabled
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  /// Get last run timestamp
  static Future<DateTime?> getLastRun() async {
    if (!isSupported) return null;
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastRunKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// Get last successful run timestamp
  static Future<DateTime?> getLastSuccess() async {
    if (!isSupported) return null;
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastSuccessKey);
    if (timestamp == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  /// Get last error message
  static Future<String?> getLastError() async {
    if (!isSupported) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastErrorKey);
  }

  /// Manually trigger background task for testing
  static Future<void> runNow() async {
    if (!isSupported) return;
    print('[BackgroundService] Manual trigger requested');
    _backgroundTaskCallback();
    // Update after manual trigger (callback will also update; this ensures quick UI feedback)
    await updateStatusNotification();
  }
}

/// Background task callback (must be top-level or static)
@pragma('vm:entry-point')
void _backgroundTaskCallback() async {
  print('[BackgroundTask] Starting daily refresh');

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('background_last_run', DateTime.now().millisecondsSinceEpoch);

  try {
    // Initialize notification service
    await NotificationService.init();

    // Get last known location
    Position? position;
    try {
      position = await Geolocator.getLastKnownPosition();
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      print('[BackgroundTask] Location failed: $e');
      await prefs.setString('background_last_error', 'Location failed: $e');
      return;
    }

    // Load settings
    final maxDistanceKm = prefs.getDouble('max_distance_km') ?? 35.0;
    final satelliteIds = prefs.getStringList('selected_satellites') ?? ['25544']; // Default: ISS

    // Run predictions
    final results = <Transit>[];
    final now = DateTime.now().toUtc();
    final startEpoch = now.millisecondsSinceEpoch ~/ 1000;
    final endEpoch = now.add(const Duration(days: 15)).millisecondsSinceEpoch ~/ 1000;

    for (final satId in satelliteIds) {
      try {
        final events = await NativeCore.predictTransitsForSatellite(
          satId: satId,
          lat: position.latitude,
          lon: position.longitude,
          altM: position.altitude,
          startEpochSec: startEpoch,
          endEpochSec: endEpoch,
          maxDistanceKm: maxDistanceKm,
        );
        results.addAll(events);
        print('[BackgroundTask] Found ${events.length} events for satellite $satId');
      } catch (e) {
        print('[BackgroundTask] Prediction failed for $satId: $e');
      }
    }

    if (results.isNotEmpty) {
      results.sort((a, b) => a.timeUtc.compareTo(b.timeUtc));

      // Schedule notifications for the next 24 hours
      await NotificationService.scheduleRollingWindow(
        results,
        windowHours: 24,
        leadMinutes: prefs.getInt('notification_lead_minutes') ?? 10,
      );

      print('[BackgroundTask] Scheduled notifications for ${results.length} transits');
      await prefs.setInt('background_last_success', DateTime.now().millisecondsSinceEpoch);
      await prefs.remove('background_last_error');
    } else {
      print('[BackgroundTask] No transits found');
      await prefs.setInt('background_last_success', DateTime.now().millisecondsSinceEpoch);
      await prefs.setString('background_last_error', 'No transits found in next 15 days');
    }
  } catch (e, stackTrace) {
    print('[BackgroundTask] Error: $e');
    print(stackTrace);
    await prefs.setString('background_last_error', e.toString());
  }

  // Update persistent status notification after run
  try {
    final lastRunTs = prefs.getInt('background_last_run');
    final lastSuccessTs = prefs.getInt('background_last_success');
    final lastError = prefs.getString('background_last_error');
    await NotificationService.showServiceStatus(
      enabled: true,
      lastRun: lastRunTs != null ? DateTime.fromMillisecondsSinceEpoch(lastRunTs) : null,
      lastSuccess: lastSuccessTs != null ? DateTime.fromMillisecondsSinceEpoch(lastSuccessTs) : null,
      lastError: lastError,
    );
  } catch (e) {
    print('[BackgroundTask] Status notification update failed: $e');
  }
}