import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';

import 'folder_upload_service.dart';
import 'notification_service.dart';

// --- Background Entry ---
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  // Shared Preferences (new isolate)
  final prefs = await SharedPreferences.getInstance();
  
  // Initialize Notification Service in this isolate
  await NotificationService().init();
  
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Shared State
  final Map<int, String> notifToTask = {};
  final Map<String, String> taskToFileId = {};
  final Map<String, bool> taskCancelled = {};
  String? globalBackendUrl;

  NotificationService().actionStream.listen((action) {
      if (action.actionId == 'cancel_action') {
          final taskId = notifToTask[action.notificationId];
          if (taskId != null) {
              taskCancelled[taskId] = true;
              NotificationService().cancelNotification(action.notificationId);
              
              // Trigger deletion if fileId known
              final fileId = taskToFileId[taskId];
              if (fileId != null && globalBackendUrl != null) {
                  // Fire and forget deletion
                  http.post(
                      Uri.parse('$globalBackendUrl/api/upload/cancel'), // hypothetical endpoint
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode({'fileId': fileId})
                  ).then((_) => print("Cleaned up cancelled file $fileId"))
                   .catchError((err) => print("Cleanup error: $err"));
              }
          }
      }
  });

  service.on('upload_files').listen((event) async {
    if (event == null) return;
    
    final String backendUrl = event['backendUrl'];
    globalBackendUrl = backendUrl;
    final String userId = event['userId'];
    final String parentPath = event['parentPath'];
    final List<String> filePaths = List<String>.from(event['filePaths']);
    final fileNames = List<String>.from(event['fileNames']);
    final taskIds = List<String>.from(event['taskIds']);

    final uploadService = FolderUploadService(backendUrl: backendUrl);
    
    for (int i = 0; i < filePaths.length; i++) {
       final path = filePaths[i];
       final name = fileNames[i];
       final taskId = taskIds[i];
       
       final notifId = taskId.hashCode;
       notifToTask[notifId] = taskId;
       taskCancelled[taskId] = false;
       
       // Handle cancellation between files?
       // Loop continues but check map.
       if (taskCancelled[taskId] == true) continue;
       
       try {
           service.invoke('progress', {'taskId': taskId, 'status': 'started'});
           
           NotificationService().showProgressNotification(
               id: notifId, 
               title: 'Uploading $name', 
               body: 'Starting...', 
               progress: 0, 
               maxProgress: 100
           );
           
           final fileObj = File(path);
           final size = await fileObj.length();
           
           await uploadService.uploadFileFromPath(
               path: path,
               name: name,
               size: size,
               userId: userId,
               logicalPath: "$parentPath/$name",
               onProgress: (prog) {
                   if (taskCancelled[taskId] == true) return; // Stop updates if cancelled (loop will throw next)
                   
                   service.invoke('progress', {'taskId': taskId, 'progress': prog, 'status': 'running'});
                   NotificationService().showProgressNotification(
                       id: notifId, 
                       title: 'Uploading $name', 
                       body: '${(prog * 100).toStringAsFixed(1)}%', 
                       progress: (prog * 100).toInt(), 
                       maxProgress: 100
                   );
               },
               isCancelled: () => taskCancelled[taskId] ?? false,
               onFileIdCreated: (fid) => taskToFileId[taskId] = fid
           );
           
           NotificationService().showCompletionNotification(
               id: notifId,
               title: 'Upload Complete',
               body: '$name uploaded successfully.'
           );
           service.invoke('progress', {'taskId': taskId, 'status': 'completed'});
           
       } catch (e) {
           print("Background Upload Error: $e");
           
           if (e.toString().contains("Cancelled")) {
                service.invoke('progress', {'taskId': taskId, 'status': 'cancelled'});
                // Notification already cleared by action handler
           } else {
               NotificationService().showCompletionNotification(
                   id: notifId,
                   title: 'Upload Failed',
                   body: 'Error uploading $name',
                   isSuccess: false
               );
               service.invoke('progress', {'taskId': taskId, 'status': 'failed', 'error': e.toString()});
           }
       }
    }
  });
}


class BackgroundUploadService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    
    // Request notification permission (Required for Android 13+)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await Permission.notification.request();
    }
    
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Start only when needed? Or true to be always ready?
        isForegroundMode: true, // Promotes app to foreground importance
        notificationChannelId: 'upload_channel',
        initialNotificationTitle: 'Keepr Service',
        initialNotificationContent: 'Ready for background tasks',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }
  
  @pragma('vm:entry-point')
  static bool onIosBackground(ServiceInstance service) {
    // Keep alive on iOS (limited time)
    return true; 
  }
  
  static Future<void> startUploads({
      required String backendUrl, 
      required String userId,
      required String parentPath,
      required List<String> filePaths,
      required List<String> fileNames,
      required List<String> taskIds,
  }) async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
        await service.startService();
    }
    
    // Use provided IDs
    
    service.invoke('upload_files', {
        'backendUrl': backendUrl,
        'userId': userId,
        'parentPath': parentPath,
        'filePaths': filePaths,
        'fileNames': fileNames,
        'taskIds': taskIds
    });
  }
}
