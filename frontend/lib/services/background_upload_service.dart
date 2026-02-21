import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folder_upload_service.dart';
import 'notification_service.dart';
import 'api_service.dart';

const String _activeTransfersPrefsKey = 'active_background_transfers';

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  try {
    DartPluginRegistrant.ensureInitialized();
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

    final Map<int, String> notifToTask = {};
    final Map<String, int> taskToNotif = {};
    final Map<String, String> taskToFileId = {};
    final Map<String, String> taskToBackendUrl = {};
    final Map<String, String> taskToName = {};
    final Map<String, String> taskToType = {};
    final Map<String, String> taskToPayload = {};
    final Map<String, bool> taskCancelled = {};
    final Map<String, bool> taskPaused = {};
    final Map<String, int> taskProgress = {};
    final Set<String> cleanupTriggeredTasks = <String>{};

    Future<void> persistActiveTasks() async {
      final prefs = await SharedPreferences.getInstance();
      final list = <Map<String, dynamic>>[];

      for (final taskId in taskToNotif.keys) {
        list.add({
          'taskId': taskId,
          'notificationId': taskToNotif[taskId],
          'fileId': taskToFileId[taskId],
          'backendUrl': taskToBackendUrl[taskId],
          'name': taskToName[taskId],
          'type': taskToType[taskId],
          'payload': taskToPayload[taskId],
          'progress': taskProgress[taskId] ?? 0,
          'paused': taskPaused[taskId] ?? false,
          'cancelled': taskCancelled[taskId] ?? false,
        });
      }

      await prefs.setString(_activeTransfersPrefsKey, jsonEncode(list));
    }

    Future<void> loadActiveTasks() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_activeTransfersPrefsKey);
      if (raw == null || raw.isEmpty) return;

      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final item in list) {
          final taskId = item['taskId']?.toString();
          if (taskId == null || taskId.isEmpty) continue;

          final notifId = (item['notificationId'] as num?)?.toInt();
          if (notifId == null) continue;

          notifToTask[notifId] = taskId;
          taskToNotif[taskId] = notifId;
          taskToFileId[taskId] = item['fileId']?.toString() ?? '';
          if ((taskToFileId[taskId] ?? '').isEmpty) taskToFileId.remove(taskId);
          taskToBackendUrl[taskId] = item['backendUrl']?.toString() ?? '';
          if ((taskToBackendUrl[taskId] ?? '').isEmpty) {
            taskToBackendUrl.remove(taskId);
          }
          taskToName[taskId] = item['name']?.toString() ?? 'Transfer';
          taskToType[taskId] = item['type']?.toString() ?? 'upload';
          taskToPayload[taskId] = item['payload']?.toString() ??
              (taskToType[taskId] == 'download'
                  ? 'download_progress'
                  : 'upload_progress');
          taskProgress[taskId] = (item['progress'] as num?)?.toInt() ?? 0;
          taskPaused[taskId] = item['paused'] == true;
          taskCancelled[taskId] = item['cancelled'] == true;
        }
      } catch (e) {
        print('[BackgroundService] Failed to restore active tasks: $e');
      }
    }

    Future<void> registerOrUpdateTask({
      required String taskId,
      required int notificationId,
      required String type,
      required String name,
      required String payload,
      required String backendUrl,
      String? fileId,
      int? progress,
      bool? paused,
      bool? cancelled,
    }) async {
      notifToTask[notificationId] = taskId;
      taskToNotif[taskId] = notificationId;
      taskToType[taskId] = type;
      taskToName[taskId] = name;
      taskToPayload[taskId] = payload;
      taskToBackendUrl[taskId] = backendUrl;
      if (fileId != null && fileId.isNotEmpty) taskToFileId[taskId] = fileId;
      if (progress != null) taskProgress[taskId] = progress;
      if (paused != null) taskPaused[taskId] = paused;
      if (cancelled != null) taskCancelled[taskId] = cancelled;
      await persistActiveTasks();
    }

    Future<void> removeTask(String taskId) async {
      final notifId = taskToNotif.remove(taskId);
      if (notifId != null) notifToTask.remove(notifId);
      taskToFileId.remove(taskId);
      taskToBackendUrl.remove(taskId);
      taskToName.remove(taskId);
      taskToType.remove(taskId);
      taskToPayload.remove(taskId);
      taskCancelled.remove(taskId);
      taskPaused.remove(taskId);
      taskProgress.remove(taskId);
      cleanupTriggeredTasks.remove(taskId);
      await persistActiveTasks();
    }

    Future<void> cleanupCancelledTask(String taskId) async {
      if (cleanupTriggeredTasks.contains(taskId)) return;

      final fileId = taskToFileId[taskId];
      final backendUrl = taskToBackendUrl[taskId];
      if (fileId == null ||
          fileId.isEmpty ||
          backendUrl == null ||
          backendUrl.isEmpty) {
        return;
      }

      cleanupTriggeredTasks.add(taskId);
      try {
        final response = await http.post(
          Uri.parse('$backendUrl/api/upload/cancel'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'fileId': fileId}),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          print('Cleaned up cancelled upload for fileId=$fileId');
        } else {
          print(
              'Cleanup failed for fileId=$fileId: ${response.statusCode} ${response.body}');
        }
      } catch (err) {
        print('Cleanup error for task=$taskId: $err');
      }
    }

    Future<void> handleNotificationAction(NotificationAction action) async {
      if (action.actionId == 'open_app') {
        service
            .invoke('open_app_from_notification', {'payload': action.payload});
        return;
      }

      final taskId = notifToTask[action.notificationId];
      if (taskId == null) return;
      final payload =
          action.payload ?? taskToPayload[taskId] ?? 'upload_progress';
      final titleBase = payload == 'download_progress' ? 'Download' : 'Upload';

      if (action.actionId == 'pause_action') {
        taskPaused[taskId] = true;
        await persistActiveTasks();
        service.invoke('progress', {'taskId': taskId, 'status': 'paused'});
        await NotificationService().showProgressNotification(
          id: action.notificationId,
          title: '$titleBase Paused',
          body: 'Tap resume to continue',
          progress: taskProgress[taskId] ?? 0,
          maxProgress: 100,
          isPaused: true,
          payload: payload,
        );
      } else if (action.actionId == 'resume_action') {
        taskPaused[taskId] = false;
        await persistActiveTasks();
        service.invoke('progress', {'taskId': taskId, 'status': 'running'});
        await NotificationService().showProgressNotification(
          id: action.notificationId,
          title: payload == 'download_progress' ? 'Downloading' : 'Uploading',
          body: '${taskProgress[taskId] ?? 0}%',
          progress: taskProgress[taskId] ?? 0,
          maxProgress: 100,
          isPaused: false,
          payload: payload,
        );
      } else if (action.actionId == 'cancel_action') {
        taskCancelled[taskId] = true;
        taskPaused[taskId] = false;
        await persistActiveTasks();
        service.invoke('progress', {'taskId': taskId, 'status': 'cancelled'});
        await NotificationService().cancelNotification(action.notificationId);
        if ((taskToType[taskId] ?? 'upload') == 'upload') {
          await cleanupCancelledTask(taskId);
        }
      }
    }

    await loadActiveTasks();

    NotificationService().actionStream.listen((action) {
      handleNotificationAction(action);
    });

    service.on('notification_action').listen((event) {
      if (event == null) return;
      final action = NotificationAction(
        event['actionId']?.toString() ?? '',
        (event['notificationId'] as num?)?.toInt() ?? 0,
        event['payload']?.toString(),
      );
      handleNotificationAction(action);
    });

    service.on('request_tasks').listen((event) {
      final tasks = <Map<String, dynamic>>[];
      for (final taskId in taskToNotif.keys) {
        final notifId = taskToNotif[taskId];
        if (notifId == null) continue;
        tasks.add({
          'taskId': taskId,
          'notificationId': notifId,
          'name': taskToName[taskId] ?? 'Transfer',
          'type': taskToType[taskId] ?? 'upload',
          'payload': taskToPayload[taskId] ?? 'upload_progress',
          'progress': taskProgress[taskId] ?? 0,
          'status': taskCancelled[taskId] == true
              ? 'cancelled'
              : (taskPaused[taskId] == true ? 'paused' : 'running'),
        });
      }
      service.invoke('tasks_response', {'tasks': tasks});
    });

    service.on('upload_files').listen((event) async {
      if (event == null) return;

      final String backendUrl = event['backendUrl'];
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

        final notifId = NotificationService.notificationIdForTask(taskId);
        await registerOrUpdateTask(
          taskId: taskId,
          notificationId: notifId,
          type: 'upload',
          name: name,
          payload: 'upload_progress',
          backendUrl: backendUrl,
          progress: 0,
          paused: false,
          cancelled: false,
        );

        if (taskCancelled[taskId] == true) continue;

        try {
          service.invoke('progress', {'taskId': taskId, 'status': 'started'});

          await NotificationService().showProgressNotification(
            id: notifId,
            title: 'Uploading $name',
            body: 'Starting...',
            progress: 0,
            maxProgress: 100,
            isPaused: false,
            payload: 'upload_progress',
          );

          final fileObj = File(path);
          final size = await fileObj.length();

          await uploadService.uploadFileFromPath(
            path: path,
            name: name,
            size: size,
            userId: userId,
            logicalPath: '$parentPath/$name',
            onProgress: (prog) {
              if (taskCancelled[taskId] == true) return;
              if (taskPaused[taskId] == true) return;

              final progressValue = (prog * 100).toInt();
              taskProgress[taskId] = progressValue;
              persistActiveTasks();

              service.invoke('progress', {
                'taskId': taskId,
                'progress': prog,
                'status': 'running',
              });
              NotificationService().showProgressNotification(
                id: notifId,
                title: 'Uploading $name',
                body: '${(prog * 100).toStringAsFixed(1)}%',
                progress: progressValue,
                maxProgress: 100,
                isPaused: false,
                payload: 'upload_progress',
              );
            },
            isCancelled: () => taskCancelled[taskId] ?? false,
            isPaused: () => taskPaused[taskId] ?? false,
            onFileIdCreated: (fid) {
              taskToFileId[taskId] = fid;
              persistActiveTasks();
              if (taskCancelled[taskId] == true) {
                cleanupCancelledTask(taskId);
              }
            },
          );

          await NotificationService().showCompletionNotification(
            id: notifId,
            title: 'Upload Complete',
            body: '$name uploaded successfully.',
          );
          service.invoke('progress', {'taskId': taskId, 'status': 'completed'});
          await removeTask(taskId);
        } catch (e) {
          print('Background Upload Error: $e');

          if (e.toString().contains('Cancelled')) {
            service
                .invoke('progress', {'taskId': taskId, 'status': 'cancelled'});
            await cleanupCancelledTask(taskId);
          } else {
            await NotificationService().showCompletionNotification(
              id: notifId,
              title: 'Upload Failed',
              body: 'Error uploading $name',
              isSuccess: false,
            );
            service.invoke('progress', {
              'taskId': taskId,
              'status': 'failed',
              'error': e.toString(),
            });
          }
          await removeTask(taskId);
        }
      }
    });

    service.on('download_files').listen((event) async {
      if (event == null) return;

      final String backendUrl = event['backendUrl'];
      final List<String> fileIds = List<String>.from(event['fileIds']);
      final List<String> fileNames = List<String>.from(event['fileNames']);
      final List<double> fileSizes = List<double>.from(event['fileSizes']);
      final List<String> targetPaths = List<String>.from(event['targetPaths']);
      final List<String> taskIds = List<String>.from(event['taskIds']);

      final uploadService = FolderUploadService(backendUrl: backendUrl);

      for (int i = 0; i < fileIds.length; i++) {
        final fileId = fileIds[i];
        final name = fileNames[i];
        final sizeMb = fileSizes[i];
        final targetPath = targetPaths[i];
        final taskId = taskIds[i];

        final notifId = NotificationService.notificationIdForTask(taskId);
        await registerOrUpdateTask(
          taskId: taskId,
          notificationId: notifId,
          type: 'download',
          name: name,
          payload: 'download_progress',
          backendUrl: backendUrl,
          progress: 0,
          paused: false,
          cancelled: false,
        );

        if (taskCancelled[taskId] == true) continue;

        try {
          service.invoke('progress', {'taskId': taskId, 'status': 'started'});

          await NotificationService().showProgressNotification(
            id: notifId,
            title: 'Downloading $name',
            body: 'Starting...',
            progress: 0,
            maxProgress: 100,
            isPaused: false,
            payload: 'download_progress',
          );

          final targetFile = File(targetPath);

          await uploadService.downloadDistributedFileToFile(
            fileId,
            sizeMb,
            targetFile,
            onProgress: (prog) {
              if (taskCancelled[taskId] == true) return;
              if (taskPaused[taskId] == true) return;

              final progressValue = (prog * 100).toInt();
              taskProgress[taskId] = progressValue;
              persistActiveTasks();

              service.invoke('progress', {
                'taskId': taskId,
                'progress': prog,
                'status': 'running',
              });
              NotificationService().showProgressNotification(
                id: notifId,
                title: 'Downloading $name',
                body: '${(prog * 100).toStringAsFixed(1)}%',
                progress: progressValue,
                maxProgress: 100,
                isPaused: false,
                payload: 'download_progress',
              );
            },
            isCancelled: () => taskCancelled[taskId] ?? false,
            isPaused: () => taskPaused[taskId] ?? false,
          );

          await NotificationService().showCompletionNotification(
            id: notifId,
            title: 'Download Complete',
            body: '$name downloaded successfully.',
          );
          service.invoke('progress', {'taskId': taskId, 'status': 'completed'});
          await removeTask(taskId);
        } catch (e) {
          print('Background Download Error: $e');

          if (e.toString().contains('Cancelled')) {
            service
                .invoke('progress', {'taskId': taskId, 'status': 'cancelled'});
          } else {
            await NotificationService().showCompletionNotification(
              id: notifId,
              title: 'Download Failed',
              body: 'Error downloading $name',
              isSuccess: false,
            );
            service.invoke('progress', {
              'taskId': taskId,
              'status': 'failed',
              'error': e.toString(),
            });
          }
          await removeTask(taskId);
        }
      }
    });

    service.on('delete_files').listen((event) async {
      if (event == null) return;
      final String backendUrl = event['backendUrl'];
      final String userId = event['userId'];
      final List<String> filePaths = List<String>.from(event['filePaths']);
      final List<String> names = List<String>.from(event['names']);
      final List<String> taskIds = List<String>.from(event['taskIds']);

      final api = ApiService(backendBase: backendUrl);

      for (int i = 0; i < filePaths.length; i++) {
        final path = filePaths[i];
        final name = names[i];
        final taskId = taskIds[i];
        final notifId = NotificationService.notificationIdForTask(taskId);

        await registerOrUpdateTask(
          taskId: taskId,
          notificationId: notifId,
          type: 'delete',
          name: name,
          payload: 'delete_progress',
          backendUrl: backendUrl,
          progress: 0,
          paused: false,
          cancelled: false,
        );

        try {
          service.invoke('progress', {'taskId': taskId, 'status': 'started'});
          await NotificationService().showProgressNotification(
            id: notifId,
            title: 'Deleting $name',
            body: 'Processing...',
            progress: 0,
            maxProgress: 100,
            isPaused: false,
            payload: 'delete_progress',
          );

          await api.deleteFile(userId, path);

          await NotificationService().showCompletionNotification(
            id: notifId,
            title: 'Deleted',
            body: '$name deleted.',
          );
          service.invoke('progress', {'taskId': taskId, 'status': 'completed'});
          await removeTask(taskId);
        } catch (e) {
          print('Background Delete Error: $e');
          await NotificationService().showCompletionNotification(
            id: notifId,
            title: 'Delete Failed',
            body: 'Error deleting $name',
            isSuccess: false,
          );
          service.invoke('progress', {
            'taskId': taskId,
            'status': 'failed',
            'error': e.toString(),
          });
          await removeTask(taskId);
        }
      }
    });
  } catch (e) {
    print('[BackgroundService] Critical Error: $e');
  }
}

class BackgroundUploadService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await Permission.notification.request();
    }

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
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
    return true;
  }

  static Future<List<Map<String, dynamic>>> getActiveTasks() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return <Map<String, dynamic>>[];
    }

    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return <Map<String, dynamic>>[];

    final completer = Completer<List<Map<String, dynamic>>>();
    StreamSubscription? subscription;

    subscription = service.on('tasks_response').listen((event) {
      final tasks = ((event?['tasks'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      if (!completer.isCompleted) {
        completer.complete(tasks);
      }
      subscription?.cancel();
    });

    service.invoke('request_tasks');

    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        subscription?.cancel();
        return <Map<String, dynamic>>[];
      },
    );
  }

  static Future<void> startUploads({
    required String backendUrl,
    required String userId,
    required String parentPath,
    required List<String> filePaths,
    required List<String> fileNames,
    required List<String> taskIds,
  }) async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        if (!notifStatus.isGranted) {
          throw Exception(
              'Notification permission is required for background uploads on Android.');
        }
      }

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      service.invoke('upload_files', {
        'backendUrl': backendUrl,
        'userId': userId,
        'parentPath': parentPath,
        'filePaths': filePaths,
        'fileNames': fileNames,
        'taskIds': taskIds,
      });
    } catch (e, st) {
      print('[BackgroundUploadService] Failed to start upload: $e');
      print('[BackgroundUploadService] StackTrace: $st');
      rethrow;
    }
  }

  static Future<void> startDownloads({
    required String backendUrl,
    required List<String> fileIds,
    required List<String> fileNames,
    required List<double> fileSizes,
    required List<String> targetPaths,
    required List<String> taskIds,
  }) async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        if (!notifStatus.isGranted) {
          throw Exception(
              'Notification permission is required for background downloads on Android.');
        }
      }

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      service.invoke('download_files', {
        'backendUrl': backendUrl,
        'fileIds': fileIds,
        'fileNames': fileNames,
        'fileSizes': fileSizes,
        'targetPaths': targetPaths,
        'taskIds': taskIds,
      });
    } catch (e, st) {
      print('[BackgroundUploadService] Failed to start download: $e');
      print('[BackgroundUploadService] StackTrace: $st');
      rethrow;
    }
  }

  static Future<void> startDeletes({
    required String backendUrl,
    required String userId,
    required List<String> filePaths,
    required List<String> fileNames,
    required List<String> taskIds,
  }) async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final notifStatus = await Permission.notification.status;
        if (!notifStatus.isGranted) {
          throw Exception(
              'Notification permission required for background valid.');
        }
      }

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      service.invoke('delete_files', {
        'backendUrl': backendUrl,
        'userId': userId,
        'filePaths': filePaths,
        'names': fileNames,
        'taskIds': taskIds,
      });
    } catch (e) {
      print('[BackgroundUploadService] delete error: $e');
      rethrow;
    }
  }
}
