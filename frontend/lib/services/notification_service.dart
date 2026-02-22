import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

// Top-level function for background action handling
@pragma('vm:entry-point')
void notificationTapBackground(
    NotificationResponse notificationResponse) async {
  print('notification(${notificationResponse.id}) action tapped: '
      '${notificationResponse.actionId} with payload: ${notificationResponse.payload}');
  if (notificationResponse.input?.isNotEmpty ?? false) {
    print(
        'notification action tapped with input: ${notificationResponse.input}');
  }

  final actionId = notificationResponse.actionId ?? 'open_app';
  if (actionId == 'open_app') {
    await NotificationService.enqueueBackgroundAction(notificationResponse);
  }

  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('notification_action', {
      'actionId': actionId,
      'notificationId': notificationResponse.id,
      'payload': notificationResponse.payload,
    });
  } else if (actionId != 'open_app') {
    await NotificationService.enqueueBackgroundAction(notificationResponse);
  }
}

class NotificationAction {
  final String actionId;
  final int notificationId;
  final String? payload;

  NotificationAction(this.actionId, this.notificationId, this.payload);
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  static const String _pendingActionsPrefsKey = 'pending_notification_actions';

  static int notificationIdForTask(String taskId) {
    var hash = 0x811C9DC5;
    final input = 'transfer:$taskId';
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  factory NotificationService() => _instance;

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<NotificationAction> _actionStreamController =
      StreamController<NotificationAction>.broadcast();
  final List<NotificationAction> _bufferedActions = <NotificationAction>[];

  Stream<NotificationAction> get actionStream => _actionStreamController.stream;

  List<NotificationAction> takeBufferedActions() {
    final copy = List<NotificationAction>.from(_bufferedActions);
    _bufferedActions.clear();
    return copy;
  }

  void _emitAction(NotificationAction action) {
    _bufferedActions.add(action);
    _actionStreamController.add(action);
  }

  static Future<void> enqueueBackgroundAction(
      NotificationResponse response) async {
    final actionId = response.actionId ?? 'open_app';

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_pendingActionsPrefsKey) ?? <String>[];

    existing.add(jsonEncode({
      'actionId': actionId,
      'notificationId': response.id ?? 0,
      'payload': response.payload,
    }));

    await prefs.setStringList(_pendingActionsPrefsKey, existing);
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) {
      // Tapped on notification body
      _emitAction(NotificationAction(
        'open_app',
        response.id ?? 0,
        response.payload,
      ));
      return;
    }
    _emitAction(NotificationAction(
      actionId,
      response.id ?? 0,
      response.payload,
    ));
  }

  Future<void> flushPendingActions() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingActionsPrefsKey) ?? <String>[];
    if (pending.isEmpty) return;

    await prefs.remove(_pendingActionsPrefsKey);

    for (final raw in pending) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _emitAction(NotificationAction(
          map['actionId']?.toString() ?? '',
          (map['notificationId'] as num?)?.toInt() ?? 0,
          map['payload']?.toString(),
        ));
      } catch (e) {
        print('[NotificationService] Failed to parse pending action: $e');
      }
    }
  }

  Future<void> init() async {
    try {
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      final DarwinInitializationSettings initializationSettingsDarwin =
          DarwinInitializationSettings(
        requestSoundPermission: false,
        requestBadgePermission: false,
        requestAlertPermission: false,
      );

      final LinuxInitializationSettings initializationSettingsLinux =
          LinuxInitializationSettings(defaultActionName: 'Open notification');

      final InitializationSettings initializationSettings =
          InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: initializationSettingsDarwin,
        macOS: initializationSettingsDarwin,
        linux: initializationSettingsLinux,
      );

      await flutterLocalNotificationsPlugin.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );

      await _ensureUploadChannel();
      await flushPendingActions();
    } catch (e) {
      print("[NotificationService] Init Error: $e");
    }
  }

  Future<void> _ensureUploadChannel() async {
    final androidPlugin =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    const channel = AndroidNotificationChannel(
      'upload_channel',
      'File Uploads',
      description: 'Notifications for file upload progress',
      importance: Importance.low,
    );

    await androidPlugin.createNotificationChannel(channel);
  }

  Future<void> showProgressNotification({
    required int id,
    required String title,
    required String body,
    required int progress, // 0 to 100
    required int maxProgress,
    bool isPaused = false,
    String? payload,
  }) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'upload_channel',
      'File Uploads',
      channelDescription: 'Notifications for file upload progress',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      actions: const <AndroidNotificationAction>[], // Removed actions
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  Future<void> showCompletionNotification({
    required int id,
    required String title,
    required String body,
    bool isSuccess = true,
  }) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'upload_channel',
      'File Uploads',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
      autoCancel: true,
    );
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      platformChannelSpecifics,
    );
  }

  Future<void> cancelNotification(int id) async {
    await flutterLocalNotificationsPlugin.cancel(id);
  }
}
