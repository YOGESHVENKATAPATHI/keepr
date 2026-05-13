import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'folder_upload_service.dart';

class DesktopTransferTask {
  final String taskId;
  final String type; // 'upload' or 'download'
  final String name;
  final String userId;
  final String backendUrl;
  
  // Upload specific
  final String? filePath;
  final String? logicalPath;
  
  // Download specific
  final String? fileIdRef;
  final double? sizeMb;
  final String? targetPath;

  double progress = 0.0;
  String status = 'queued'; // queued, running, paused, completed, failed, cancelled
  String? error;

  // Control flags
  bool _isPaused = false;
  bool _isCancelled = false;

  DesktopTransferTask({
    required this.taskId,
    required this.type,
    required this.name,
    required this.userId,
    required this.backendUrl,
    this.filePath,
    this.logicalPath,
    this.fileIdRef,
    this.sizeMb,
    this.targetPath,
  });

  bool get isPaused => _isPaused;
  bool get isCancelled => _isCancelled;
  
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void cancel() => _isCancelled = true;
}

class DesktopTransferManager {
  static final DesktopTransferManager _instance = DesktopTransferManager._internal();
  factory DesktopTransferManager() => _instance;
  DesktopTransferManager._internal();

  final Map<String, DesktopTransferTask> _tasks = {};
  final StreamController<Map<String, dynamic>> _progressController = StreamController.broadcast();

  Stream<Map<String, dynamic>> get onProgress => _progressController.stream;

  List<DesktopTransferTask> get activeTasks => _tasks.values.toList();

  Future<void> startUpload({
    required String taskId,
    required String filePath,
    required String name,
    required String userId,
    required String logicalPath,
    required String backendUrl,
    required FolderUploadService uploader,
  }) async {
    final task = DesktopTransferTask(
      taskId: taskId,
      type: 'upload',
      name: name,
      userId: userId,
      backendUrl: backendUrl,
      filePath: filePath,
      logicalPath: logicalPath,
    );

    _tasks[taskId] = task;
    _emitUpdate(task, 'running');

    try {
      final file = File(filePath);
      final size = await file.length();

      await uploader.uploadFileFromPath(
        path: filePath,
        name: name,
        size: size,
        userId: userId,
        logicalPath: logicalPath,
        onProgress: (prog) {
          task.progress = prog;
          _emitUpdate(task, task.isPaused ? 'paused' : 'running');
        },
        isPaused: () => task.isPaused,
        isCancelled: () => task.isCancelled,
      );

      _emitUpdate(task, 'completed');
    } catch (e) {
      if (task.isCancelled) {
        _emitUpdate(task, 'cancelled');
      } else {
        task.error = e.toString();
        _emitUpdate(task, 'failed');
      }
    } finally {
      // Keep completed/failed tasks for a moment or until cleared
       if (task.isCancelled || task.status == 'completed' || task.status == 'failed') {
         // Auto-remove after delay?
         Future.delayed(const Duration(seconds: 2), () {
           _tasks.remove(taskId);
         });
       }
    }
  }

  Future<void> startDownload({
    required String taskId,
    required String fileIdRef,
    required String name,
    required double sizeMb,
    required String targetPath,
    required String userId,
    required String backendUrl,
    required FolderUploadService uploader,
  }) async {
    final task = DesktopTransferTask(
      taskId: taskId,
      type: 'download',
      name: name,
      userId: userId,
      backendUrl: backendUrl,
      fileIdRef: fileIdRef,
      sizeMb: sizeMb,
      targetPath: targetPath,
    );

    _tasks[taskId] = task;
    _emitUpdate(task, 'running');

    try {
      final file = File(targetPath);
      
      // We need to extend FolderUploadService to support isPaused/isCancelled for downloads too,
      // but for now let's assume it supports it or we'll add it.
      // Checking downloadDistributedFileToFile signature...
      // It currently only has onProgress. We need to modify FolderUploadService.
      
      await uploader.downloadDistributedFileToFile(
        fileIdRef,
        sizeMb,
        file,
        onProgress: (prog) {
          task.progress = prog;
          _emitUpdate(task, task.isPaused ? 'paused' : 'running');
        },
        isPaused: () => task.isPaused,
        isCancelled: () => task.isCancelled,
      );

      _emitUpdate(task, 'completed');
    } catch (e) {
      if (task.isCancelled) {
        _emitUpdate(task, 'cancelled');
      } else {
        task.error = e.toString();
        _emitUpdate(task, 'failed');
      }
    } finally {
        if (task.isCancelled || task.status == 'completed' || task.status == 'failed') {
         Future.delayed(const Duration(seconds: 2), () {
           _tasks.remove(taskId);
         });
       }
    }
  }

  void pauseTask(String taskId) {
    print('Pausing task $taskId');
    final task = _tasks[taskId];
    if (task != null && !task.isCompleted && !task.isFailed) {
      task.pause();
      _emitUpdate(task, 'paused');
    }
  }

  void resumeTask(String taskId) {
    print('Resuming task $taskId');
    final task = _tasks[taskId];
    if (task != null) {
      task.resume();
      _emitUpdate(task, 'running');
    }
  }

  void cancelTask(String taskId) {
    print('Cancelling task $taskId');
    final task = _tasks[taskId];
    if (task != null) {
      task.cancel();
      _emitUpdate(task, 'cancelled');
    }
  }

  void _emitUpdate(DesktopTransferTask task, String status) {
    task.status = status;
    _progressController.add({
      'taskId': task.taskId,
      'status': status,
      'progress': task.progress,
      'error': task.error,
      'name': task.name,
      'type': task.type,
    });
  }
}
