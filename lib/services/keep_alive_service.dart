// Licensed under the MIT License — see LICENSE for details.

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void _keepAliveStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Heartbeat only. The actual streaming/detection logic runs on the main
    // Flutter engine, not inside this background task isolate — this task's
    // only job is to hold a foreground service + notification so Android
    // doesn't kill the app process while it's backgrounded.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Thin wrapper around `flutter_foreground_task` that keeps the whole app
/// process alive (Android only) while the server is streaming or the client
/// has opted in, so switching to another app or locking the screen doesn't
/// tear down the camera/mic session or the WebRTC connection.
///
/// iOS has no equivalent general-purpose mechanism: Apple only allows
/// continuous background execution for a handful of approved use cases
/// (VoIP calls via CallKit/PushKit, background audio, location, etc.), not
/// arbitrary background video streaming. On iOS this class is a no-op —
/// see the README for what iOS actually supports here.
class KeepAliveService {
  static bool _initialized = false;

  static Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'video_monitor_keep_alive',
        channelName: 'Video Monitor active session',
        channelDescription: 'Keeps the app running while streaming or connected.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // Best-effort: significantly improves reliability on OEMs (Xiaomi,
      // Huawei, Samsung, etc.) that kill backgrounded apps aggressively
      // regardless of the foreground service being active.
      final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!ignoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  static Future<void> start({required String title, required String text}) async {
    if (!Platform.isAndroid) return; // no-op elsewhere — see class doc above
    await _ensureInit();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      return;
    }
    await FlutterForegroundTask.startService(
      serviceTypes: const [
        ForegroundServiceTypes.camera,
        ForegroundServiceTypes.microphone,
      ],
      notificationTitle: title,
      notificationText: text,
      callback: _keepAliveStartCallback,
    );
  }

  static Future<void> update({required String title, required String text}) async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
