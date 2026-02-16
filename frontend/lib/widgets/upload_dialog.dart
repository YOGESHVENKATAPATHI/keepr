import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../services/folder_upload_service.dart';
import '../services/background_upload_service.dart';

class UploadDialog extends StatefulWidget {
  final FolderUploadService uploader;
  final String userId;
  final String currentPath;
  final VoidCallback onUploadComplete;

  const UploadDialog({
    super.key,
    required this.uploader,
    required this.userId,
    required this.currentPath,
    required this.onUploadComplete,
  });

  @override
  State<UploadDialog> createState() => _UploadDialogState();
}

class _UploadTask {
  final String id;
  final PlatformFile file;
  double progress = 0.0;
  bool isCompleted = false;
  bool isFailed = false;
  String? errorMessage;

  _UploadTask(this.file) : id = const Uuid().v4();
}

class _UploadDialogState extends State<UploadDialog> {
  final List<_UploadTask> _tasks = [];
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _initBackgroundListener();
    }
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
            } else if (status == 'completed') {
              task.progress = 1.0;
              task.isCompleted = true;
            } else if (status == 'failed') {
               task.isFailed = true;
               task.errorMessage = event['error'];
            }
          } catch (e) {
            // Task not found
          }
        });
        
        if (taskFound && _tasks.isNotEmpty && _tasks.every((t) => t.isCompleted || t.isFailed)) {
           // All visible tasks done
           widget.onUploadComplete();
        }
      });
    }
  }


  Future<void> _pickFiles() async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false, // Required for large files to avoid OOM
        withReadStream: true, // Required for streaming chunks
      );

      if (result != null) {
        final newTasks = result.files.map((f) => _UploadTask(f)).toList();
        setState(() {
          _tasks.addAll(newTasks);
        });

        if (kIsWeb) {
          _startUploads(newTasks);
        } else {
          final paths = newTasks.map((t) => t.file.path!).toList();
          final names = newTasks.map((t) => t.file.name).toList();
          final ids = newTasks.map((t) => t.id).toList();

          await BackgroundUploadService.startUploads(
            backendUrl: widget.uploader.backendUrl,
            userId: widget.userId,
            parentPath: widget.currentPath,
            filePaths: paths,
            fileNames: names,
            taskIds: ids,
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _startUploads(List<_UploadTask> newTasks) async {
    for (final task in newTasks) {
      await _processTask(task);
    }
    widget.onUploadComplete();
  }

  Future<void> _processTask(_UploadTask task) async {
    try {
      await widget.uploader
          .uploadWebFiles([task.file], widget.userId, widget.currentPath,
              onFileProgress: (name, prog) {
        if (mounted) {
          setState(() {
            task.progress = prog;
          });
        }
      });
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
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: isMobile ? width * 0.95 : 600,
            height: 550,
            decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withAlpha((0.85 * 255).round()),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: Colors.white.withAlpha((0.1 * 255).round()),
                    width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha((0.3 * 255).round()),
                    blurRadius: 20,
                    spreadRadius: 5,
                  )
                ]),
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Select Files",
                        style: GoogleFonts.zillaSlab(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              shape: BoxShape.circle),
                          child: const Icon(Icons.close,
                              color: Colors.white, size: 20)),
                    )
                  ],
                ),
                const SizedBox(height: 24),

                // Dashed Upload Area
                GestureDetector(
                  onTap: _pickFiles,
                  child: CustomPaint(
                    painter: _DashedBorderPainter(
                        color: const Color(0xFF6366F1), strokeWidth: 2, gap: 5),
                    child: Container(
                      width: double.infinity,
                      height: 140,
                      decoration: BoxDecoration(
                          color: const Color(0xFF6366F1)
                              .withAlpha((0.1 * 255).round()),
                          borderRadius: BorderRadius.circular(16)),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1)
                                  .withAlpha((0.2 * 255).round()),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.cloud_upload_outlined,
                                color: Color(0xFF818CF8), size: 32),
                          ),
                          const SizedBox(height: 12),
                          RichText(
                              text: TextSpan(children: [
                            TextSpan(
                                text: "Click here",
                                style: GoogleFonts.inter(
                                    color: const Color(0xFF818CF8),
                                    fontWeight: FontWeight.bold)),
                            TextSpan(
                                text: " to upload your file.",
                                style: GoogleFonts.inter(color: Colors.white70))
                          ])),
                          const SizedBox(height: 6),
                          Text("Supported Format: Any (max 1GB)",
                              style: GoogleFonts.inter(
                                  color: Colors.white24, fontSize: 11))
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // File List
                Expanded(
                  child: _tasks.isEmpty
                      ? Center(
                          child: Text("No files waiting.",
                              style: GoogleFonts.inter(color: Colors.white12)))
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

  Widget _buildTaskItem(_UploadTask task) {
    // Safety check for size > 0
    final sizeBytes = task.file.size > 0 ? task.file.size : 1;
    final sizeMb = sizeBytes / (1024 * 1024);

    // Calculate precise uploaded amounts
    final uploadedBytes = (sizeBytes * task.progress).round();
    final double uploadedMb = uploadedBytes / (1024 * 1024);

    // Status Logic
    Color barColor = const Color(0xFF6366F1); // Indigo
    IconData statusIcon = Icons.upload_file;
    Color iconColor = const Color(0xFF818CF8);
    Color loadingBg = Colors.white.withAlpha((0.05 * 255).round());

    if (task.isFailed) {
      barColor = Colors.redAccent;
      statusIcon = Icons.error_outline;
      iconColor = Colors.redAccent;
      loadingBg = Colors.redAccent.withAlpha((0.1 * 255).round());
    } else if (task.isCompleted) {
      barColor = const Color(0xFF10B981); // Emerald
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
                    color: loadingBg, borderRadius: BorderRadius.circular(10)),
                child: Icon(statusIcon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    // Progress Bar
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
                Icon(Icons.refresh,
                    color: Colors.white54, size: 18) // Retry placeholder
              else
                Text("${(task.progress * 100).toStringAsFixed(0)}%",
                    style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold))
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  task.isFailed
                      ? "Error: ${task.errorMessage ?? 'Unknown'}"
                      : (task.isCompleted
                          ? "Upload Successful!"
                          : "${uploadedMb.toStringAsFixed(2)} MB / ${sizeMb.toStringAsFixed(2)} MB"),
                  style: GoogleFonts.inter(
                      color: task.isFailed ? Colors.redAccent : Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          )
        ],
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double gap;

  _DashedBorderPainter(
      {required this.color, this.strokeWidth = 1.0, this.gap = 5.0});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final Path path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          const Radius.circular(16)));

    Path dashPath = Path();
    double dashWidth = 10.0;
    double dashSpace = gap;
    double distance = 0.0;
    for (PathMetric pathMetric in path.computeMetrics()) {
      while (distance < pathMetric.length) {
        dashPath.addPath(
          pathMetric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth;
        distance += dashSpace;
      }
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
