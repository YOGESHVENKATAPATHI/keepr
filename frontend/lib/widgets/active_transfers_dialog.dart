import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:google_fonts/google_fonts.dart';

class ActiveTransfersDialog extends StatefulWidget {
  final List<Map<String, dynamic>> initialTasks;

  const ActiveTransfersDialog({
    super.key,
    required this.initialTasks,
  });

  @override
  State<ActiveTransfersDialog> createState() => _ActiveTransfersDialogState();
}

class _ActiveTransfersDialogState extends State<ActiveTransfersDialog> {
  late final Map<String, Map<String, dynamic>> _tasks;
  StreamSubscription? _progressSub;

  @override
  void initState() {
    super.initState();
    _tasks = {
      for (final task in widget.initialTasks)
        task['taskId'].toString(): Map<String, dynamic>.from(task)
    };
    _attachProgressListener();
  }

  void _attachProgressListener() async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return;

    _progressSub = service.on('progress').listen((event) {
      if (event == null || !mounted) return;
      final taskId = event['taskId']?.toString();
      if (taskId == null) return;
      final existing = _tasks[taskId];
      if (existing == null) return;

      final status = event['status']?.toString();
      if (status != null) {
        existing['status'] = status;
      }

      final progress = event['progress'];
      if (progress is num) {
        existing['progress'] = (progress * 100).toInt().clamp(0, 100);
      }

      if (status == 'completed' ||
          status == 'failed' ||
          status == 'cancelled') {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (!mounted) return;
          setState(() {
            _tasks.remove(taskId);
          });
        });
      }

      setState(() {});
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _sendAction(Map<String, dynamic> task, String actionId) {
    final service = FlutterBackgroundService();
    service.invoke('notification_action', {
      'actionId': actionId,
      'notificationId': task['notificationId'],
      'payload': task['payload'],
    });

    if (actionId == 'pause_action') {
      task['status'] = 'paused';
    } else if (actionId == 'resume_action') {
      task['status'] = 'running';
    } else if (actionId == 'cancel_action') {
      task['status'] = 'cancelled';
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final taskList = _tasks.values.toList(growable: false);

    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      child: SizedBox(
        width: 520,
        height: 420,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Background Transfers',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: taskList.isEmpty
                    ? Center(
                        child: Text(
                          'No active transfers',
                          style: GoogleFonts.inter(color: Colors.white54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: taskList.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final task = taskList[index];
                          final progress =
                              (task['progress'] as num?)?.toInt() ?? 0;
                          final status =
                              task['status']?.toString() ?? 'running';
                          final name = task['name']?.toString() ?? 'Transfer';
                          final type = task['type']?.toString() ?? 'upload';

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${type == 'download' ? 'Download' : 'Upload'} • $name',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.inter(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '$progress%',
                                      style: GoogleFonts.inter(
                                          color: Colors.white70),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value: progress / 100,
                                  minHeight: 5,
                                  backgroundColor: Colors.white12,
                                  color: const Color(0xFF6366F1),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        status.toUpperCase(),
                                        style: GoogleFonts.inter(
                                          color: status == 'failed'
                                              ? Colors.redAccent
                                              : (status == 'completed'
                                                  ? Colors.greenAccent
                                                  : Colors.white60),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    if (status == 'running' ||
                                        status == 'paused') ...[
                                      IconButton(
                                        onPressed: () => _sendAction(
                                          task,
                                          status == 'paused'
                                              ? 'resume_action'
                                              : 'pause_action',
                                        ),
                                        icon: Icon(
                                          status == 'paused'
                                              ? Icons.play_arrow
                                              : Icons.pause,
                                          color: Colors.white70,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () =>
                                            _sendAction(task, 'cancel_action'),
                                        icon: const Icon(
                                          Icons.close,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ]
                                  ],
                                )
                              ],
                            ),
                          );
                        },
                      ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
