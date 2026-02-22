import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:io' as io;

import '../services/folder_upload_service.dart';
import '../services/background_upload_service.dart';
import '../services/notification_service.dart';

class DownloadDialog extends StatefulWidget {
  final FolderUploadService uploader;
  final String userId;
  final List<dynamic> itemsToDownload;
  final VoidCallback onDownloadComplete;

  const DownloadDialog({
    super.key,
    required this.uploader,
    required this.userId,
    required this.itemsToDownload,
    required this.onDownloadComplete,
  });

  @override
  State<DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadTask {
  final String id;
  final String name;
  final String fileIdRef;
  final double sizeMb;
  final String targetPath;
  double progress = 0.0;
  bool isCompleted = false;
  bool isFailed = false;
  bool isPaused = false;
  String? errorMessage;

  _DownloadTask({
    required this.name,
    required this.fileIdRef,
    required this.sizeMb,
    required this.targetPath,
  }) : id = const Uuid().v4();
}

class _DownloadDialogState extends State<DownloadDialog> {
  final List<_DownloadTask> _tasks = [];
  bool _isStarting = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _initBackgroundListener();
    }
    _startDownloads();
  }

  void _initBackgroundListener() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.on('progress').listen((event) {
        if (event == null || !mounted) return;
        final taskId = event['taskId'];
        if (taskId == null) return;

        bool taskFound = false;
        setState(() {
          try {
            final task = _tasks.firstWhere((t) => t.id == taskId);
            taskFound = true;
            final status = event['status'];

            if (status == 'running') {
              task.progress = (event['progress'] as num).toDouble();
              task.isPaused = false;
            } else if (status == 'paused') {
              task.isPaused = true;
            } else if (status == 'completed') {
              task.progress = 1.0;
              task.isCompleted = true;
              task.isPaused = false;
            } else if (status == 'failed') {
              task.isFailed = true;
              task.errorMessage = event['error'];
              task.isPaused = false;
            } else if (status == 'cancelled') {
              task.isFailed = true;
              task.errorMessage = 'Cancelled';
              task.isPaused = false;
            }
          } catch (e) {
            // Task not found
          }
        });

        if (taskFound &&
            _tasks.isNotEmpty &&
            _tasks.every((t) => t.isCompleted || t.isFailed)) {
          widget.onDownloadComplete();
        }
      });
    }
  }

  Future<void> _startDownloads() async {
    if (_isStarting) return;
    _isStarting = true;
    try {
      final newTasks = <_DownloadTask>[];
      for (final item in widget.itemsToDownload) {
        final name = item['name'];
        final fileIdRef = item['file_id_ref'];
        final sizeMb = double.tryParse(item['size_mb']?.toString() ?? '0') ?? 0;
        final targetPath = item['targetPath'];

        if (fileIdRef != null && targetPath != null) {
          newTasks.add(_DownloadTask(
            name: name,
            fileIdRef: fileIdRef,
            sizeMb: sizeMb,
            targetPath: targetPath,
          ));
        }
      }

      if (newTasks.isEmpty) return;

      setState(() {
        _tasks.addAll(newTasks);
      });

      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        final ids = newTasks.map((t) => t.id).toList();
        final names = newTasks.map((t) => t.name).toList();
        final fileIds = newTasks.map((t) => t.fileIdRef).toList();
        final sizes = newTasks.map((t) => t.sizeMb).toList();
        final paths = newTasks.map((t) => t.targetPath).toList();

        try {
          await BackgroundUploadService.startDownloads(
            backendUrl: widget.uploader.backendUrl,
            fileIds: fileIds,
            fileNames: names,
            fileSizes: sizes,
            targetPaths: paths,
            taskIds: ids,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Background download failed: $e. Retrying in foreground.',
                ),
              ),
            );
          }
          await _startForegroundDownloads(newTasks);
        }
      } else {
        await _startForegroundDownloads(newTasks);
      }
    } finally {
      if (mounted) setState(() => _isStarting = false);
    }
  }

  Future<void> _startForegroundDownloads(List<_DownloadTask> newTasks) async {
    for (final task in newTasks) {
      await _processTask(task);
    }
    widget.onDownloadComplete();
  }

  Future<void> _processTask(_DownloadTask task) async {
    try {
      final file = io.File(task.targetPath);
      await widget.uploader.downloadDistributedFileToFile(
        task.fileIdRef,
        task.sizeMb,
        file,
        onProgress: (prog) {
          if (mounted) {
            setState(() {
              task.progress = prog;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          task.progress = 1.0;
          task.isCompleted = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          task.isFailed = true;
          task.errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2E).withAlpha((0.85 * 255).round()),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withAlpha((0.1 * 255).round()),
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Downloads',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: _tasks.isEmpty
                      ? Center(
                          child: Text(
                            'No files waiting.',
                            style: GoogleFonts.inter(color: Colors.white12),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _tasks.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (ctx, i) => _buildTaskItem(_tasks[i]),
                        ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskItem(_DownloadTask task) {
    final sizeMb = task.sizeMb;
    final downloadedMb = sizeMb * task.progress;

    Color barColor = const Color(0xFF6366F1);
    IconData statusIcon = Icons.download;
    Color iconColor = const Color(0xFF818CF8);
    Color loadingBg = Colors.white.withAlpha((0.05 * 255).round());

    if (task.isFailed) {
      barColor = Colors.redAccent;
      statusIcon = Icons.error_outline;
      iconColor = Colors.redAccent;
      loadingBg = Colors.redAccent.withAlpha((0.1 * 255).round());
    } else if (task.isCompleted) {
      barColor = const Color(0xFF10B981);
      statusIcon = Icons.check_circle;
      iconColor = const Color(0xFF10B981);
      loadingBg = const Color(0xFF10B981).withAlpha((0.1 * 255).round());
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha((0.03 * 255).round()),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha((0.05 * 255).round())),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: loadingBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(statusIcon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: task.progress > 1
                            ? 1
                            : (task.progress < 0 ? 0 : task.progress),
                        minHeight: 4,
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation(barColor),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (task.isCompleted)
                const Icon(Icons.check, color: Color(0xFF10B981), size: 18)
              else if (task.isFailed)
                const Icon(Icons.error, color: Colors.redAccent, size: 18)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        task.isPaused ? Icons.play_arrow : Icons.pause,
                        color: Colors.white70,
                        size: 20,
                      ),
                      onPressed: () {
                        final service = FlutterBackgroundService();
                        // Instead of sending notification_action, send explicit pause/resume command or invoke payload
                        // But wait, the background service listens to 'notification_action'
                        // Let's verify payload matches exactly what background service expects.

                        service.invoke('notification_action', {
                          'actionId':
                              task.isPaused ? 'resume_action' : 'pause_action',
                          'notificationId':
                              NotificationService.notificationIdForTask(
                                  task.id),
                          'payload':
                              'download_progress', // Hardcoded here? Should match registration?
                        });

                        // Optimistic update
                        if (mounted) {
                          setState(() {
                            task.isPaused = !task.isPaused;
                          });
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white70,
                        size: 20,
                      ),
                      onPressed: () {
                        final service = FlutterBackgroundService();
                        service.invoke('notification_action', {
                          'actionId': 'cancel_action',
                          'notificationId':
                              NotificationService.notificationIdForTask(
                                  task.id),
                          'payload': 'download_progress',
                        });
                      },
                    ),
                  ],
                )
            ],
          ),
          const SizedBox(height: 8),
          Text(
            task.isFailed
                ? 'Error: ${task.errorMessage ?? 'Unknown'}'
                : task.isCompleted
                    ? 'Download Successful!'
                    : task.isPaused
                        ? 'Paused - ${downloadedMb.toStringAsFixed(2)} MB / ${sizeMb.toStringAsFixed(2)} MB'
                        : '${downloadedMb.toStringAsFixed(2)} MB / ${sizeMb.toStringAsFixed(2)} MB',
            style: GoogleFonts.inter(
              color: task.isFailed ? Colors.redAccent : Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          )
        ],
      ),
    );
  }
}
