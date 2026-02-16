import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:async';

// Top-level function for background action handling
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) {
  print('notification(${notificationResponse.id}) action tapped: '
      '${notificationResponse.actionId} with payload: ${notificationResponse.payload}');
  if (notificationResponse.input?.isNotEmpty ?? false) {
    print('notification action tapped with input: ${notificationResponse.input}');
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

  factory NotificationService() => _instance;

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<NotificationAction> _actionStreamController =
      StreamController<NotificationAction>.broadcast();
  
  Stream<NotificationAction> get actionStream => _actionStreamController.stream;

  Future<void> init() async {
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

    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsDarwin,
      macOS: initializationSettingsDarwin,
      linux: initializationSettingsLinux,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (response.actionId != null) {
          _actionStreamController.add(NotificationAction(
              response.actionId!, 
              response.id ?? 0, 
              response.payload
          ));
        } else if (response.payload != null) {
             // Handle simple tap
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
  }

  Future<void> showProgressNotification({
    required int id,
    required String title,
    required String body,
    required int progress, // 0 to 100
    required int maxProgress,
    bool isPaused = false,
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
      actions: <AndroidNotificationAction>[
        if (!isPaused)
          AndroidNotificationAction(
            'pause_action',
            'Pause',
            showsUserInterface: false,
            cancelNotification: false,
          )
        else
          AndroidNotificationAction(
            'resume_action',
            'Resume',
            showsUserInterface: false,
            cancelNotification: false,
          ),
        AndroidNotificationAction(
          'cancel_action',
          'Cancel',
          showsUserInterface: false,
          cancelNotification: true, // Dismiss on cancel but we handle logic
        ),
      ],
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      platformChannelSpecifics,
      payload: 'upload_progress',
    );
  }
  
  Future<void> showCompletionNotification({
      required int id,
      required String title,
      required String body,
      bool isSuccess = true
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
