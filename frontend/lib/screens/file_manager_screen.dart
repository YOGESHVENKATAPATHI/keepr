import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:universal_html/html.dart' as html;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:glassmorphism/glassmorphism.dart';
import '../services/api_service.dart';
import '../services/folder_upload_service.dart';
import '../theme/keepr_theme.dart';
import 'file_viewer_screen.dart';
import '../widgets/upload_dialog.dart';
import '../widgets/download_dialog.dart';
import '../widgets/active_transfers_dialog.dart';

import 'package:flutter_svg/flutter_svg.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;

import '../services/notification_service.dart';
import '../services/background_upload_service.dart';
import 'saved_messages_screen.dart';
import 'notes_editor_screen.dart';
import 'set_pin_screen.dart';

class FileManagerScreen extends StatefulWidget {
  final String userId;
  final ApiService api;
  final FolderUploadService uploader;
  const FileManagerScreen(
      {super.key,
      required this.userId,
      required this.api,
      required this.uploader});

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  String currentPath = '/';
  List<dynamic> items = [];
  bool loading = false;
  StreamController<double>? _downloadProgressController;
  bool _isActiveTransfersDialogOpen = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearchExpanded = false;
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _activeTaskPollTimer;
  List<Map<String, dynamic>> _activeTasks = [];

  StreamSubscription? _notificationSubscription;

  double _totalAllocatedBytes = 0;
  double _totalUsedBytes = 0;
  bool _loadingStorage = true;

  @override
  void initState() {
    super.initState();
    _downloadProgressController = StreamController<double>.broadcast();
    _refresh();
    _startActiveTaskPolling();
    _loadStorageStats();

    _searchController.addListener(() {
      if (!mounted) return;
      setState(() {
        _searchQuery = _searchController.text.trim();
        _isSearchExpanded =
            _searchFocusNode.hasFocus || _searchController.text.isNotEmpty;
      });
    });

    _searchFocusNode.addListener(() {
      if (!mounted) return;
      setState(() {
        _isSearchExpanded =
            _searchFocusNode.hasFocus || _searchController.text.isNotEmpty;
      });
    });

    _notificationSubscription =
        NotificationService().actionStream.listen((action) {
      if (action.actionId == 'open_app') {
        _openActiveTransfersDialog();
      }
    });

    final buffered = NotificationService().takeBufferedActions();
    if (buffered.any((a) => a.actionId == 'open_app')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openActiveTransfersDialog();
      });
    }
  }

  Future<void> _loadStorageStats() async {
    setState(() => _loadingStorage = true);
    try {
      final secureStorage = const FlutterSecureStorage();
      final token = await secureStorage.read(key: 'auth_token');
      if (token != null) {
        final res = await widget.api.getStorageStats(token);
        if (res['ok'] == true && res['stats'] != null) {
          if (mounted) {
            setState(() {
              _totalUsedBytes = (res['stats']['usedBytes'] ?? 0).toDouble();
              _totalAllocatedBytes = (res['stats']['allocatedBytes'] ?? 0).toDouble();
              _loadingStorage = false;
            });
          }
          return;
        }
      }
    } catch (e) {
      print('Failed to load storage stats: $e');
    }
    if (mounted) {
      setState(() => _loadingStorage = false);
    }
  }

  void _startActiveTaskPolling() {
    _pollActiveTasks();
    _activeTaskPollTimer?.cancel();
    _activeTaskPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollActiveTasks();
    });
  }

  Future<void> _pollActiveTasks() async {
    final tasks = await BackgroundUploadService.getActiveTasks();
    if (!mounted) return;
    setState(() {
      _activeTasks = tasks;
    });
  }

  Future<void> _openActiveTransfersDialog({String? type}) async {
    if (_isActiveTransfersDialogOpen || !mounted) return;

    final tasks = _activeTasks.isEmpty
        ? await BackgroundUploadService.getActiveTasks()
        : _activeTasks;
    final filtered = type == null
        ? tasks
        : tasks.where((task) => task['type']?.toString() == type).toList();

    if (!mounted || filtered.isEmpty) {
      _showSnack('No active transfers');
      return;
    }

    _isActiveTransfersDialogOpen = true;
    await showDialog(
      context: context,
      builder: (_) => ActiveTransfersDialog(initialTasks: filtered),
    );
    _isActiveTransfersDialogOpen = false;
  }

  @override
  void dispose() {
    _notificationSubscription?.cancel();
    _activeTaskPollTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    if (_downloadProgressController != null &&
        !_downloadProgressController!.isClosed) {
      _downloadProgressController!.close();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      loading = true;
    });
    try {
      // Use logic to fetch files
      final res = await widget.api.listFiles(widget.userId, path: currentPath);
      setState(() {
        items = res['items'] ?? [];
        // Sort: Folders first, then files
        items.sort((a, b) {
          bool aIsFolder = a['is_folder'] ?? false;
          bool bIsFolder = b['is_folder'] ?? false;
          if (aIsFolder && !bIsFolder) return -1;
          if (!aIsFolder && bIsFolder) return 1;
          return (a['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b['name'] ?? '').toString().toLowerCase());
        });
      });
    } catch (e) {
      if (mounted) _showSnack('Failed to list files: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter(color: Colors.white)),
      backgroundColor: isError
          ? Colors.redAccent.withAlpha((0.8 * 255).round())
          : const Color(0xFF15294a),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ));
  }

  Future<void> _pickFolderAndUpload() async {
    // Check for active background deletes
    final tasks = await BackgroundUploadService.getActiveTasks();
    if (tasks.any((t) => t['type'] == 'delete')) {
      _showSnack('Please wait for deletions to complete before uploading.',
          isError: true);
      return;
    }

    String? dirPath;
    try {
      dirPath = await FilePicker.platform.getDirectoryPath();
    } catch (e) {
      dirPath = null;
    }

    if (dirPath == null) {
      final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          withData:
              false, // Important: Never load full file into memory to avoid crashes
          withReadStream: true // Use stream for Web/Large files
          );
      if (result == null) return;

      try {
        _showSnack('Uploading files...');
        await widget.uploader
            .uploadWebFiles(result.files, widget.userId, currentPath);
        _showSnack('Files uploaded successfully');
        _refresh();
      } catch (e) {
        _showSnack('Upload failed: $e', isError: true);
      }
      return;
    }

    try {
      await widget.uploader.uploadFolder(dirPath, widget.userId);
      _showSnack('Folder uploaded successfully');
      _refresh();
    } catch (e) {
      _showSnack('Upload failed: $e', isError: true);
    }
  }

  Future<void> _downloadFile(dynamic item) async {
    final dropboxPath = item['dropbox_path'] ?? item['path'];
    final name = item['name'];

    // Check for distributed file
    final isDistributed =
        (dropboxPath == 'distributed' && item['file_id_ref'] != null);
    double sizeMb = double.tryParse(item['size_mb']?.toString() ?? '0') ?? 0;

    if (!kIsWeb) {
      // Desktop/Mobile: on mobile use saved download path (if set) so user
      // doesn't need to pick a location every time. Otherwise fall back to
      // the save dialog (desktop or if path missing).

      if (Platform.isAndroid) {
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }

      final secureStorage = const FlutterSecureStorage();
      String? savePath;
      final isMobile = defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;

      if (isMobile) {
        final stored = await secureStorage.read(key: 'download_path');
        if (stored != null && stored.isNotEmpty) {
          final sep = Platform.pathSeparator;
          savePath =
              stored.endsWith(sep) ? '$stored$name' : '$stored${sep}$name';
        }
      }

      // If we didn't obtain a saved path, ask the user (desktop or mobile fallback)
      if (savePath == null) {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save $name',
          fileName: name,
        );
      }

      if (savePath == null) {
        _showSnack('Save cancelled');
        return;
      }

      if (isDistributed) {
        showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              return DownloadDialog(
                uploader: widget.uploader,
                userId: widget.userId,
                itemsToDownload: [
                  {
                    'name': name,
                    'file_id_ref': item['file_id_ref'],
                    'size_mb': sizeMb,
                    'targetPath': savePath,
                  }
                ],
                onDownloadComplete: () {
                  _showSnack('Saved to $savePath');
                  _refresh();
                },
              );
            });
      } else {
        showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) {
              return StatefulBuilder(builder: (context, setState) {
                return StreamBuilder<double>(
                    stream: _downloadProgressController?.stream ??
                        Stream.value(0.0),
                    initialData: 0.0,
                    builder: (context, snapshot) {
                      final p = snapshot.data ?? 0.0;
                      return AlertDialog(
                        backgroundColor: KeeprTheme.surface,
                        title: Text('Downloading...',
                            style: GoogleFonts.inter(color: Colors.white)),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LinearProgressIndicator(
                                value: p,
                                backgroundColor: Colors.white10,
                                color: KeeprTheme.primary),
                            const SizedBox(height: 10),
                            Text('${(p * 100).toStringAsFixed(1)}%',
                                style: GoogleFonts.inter(color: Colors.white70))
                          ],
                        ),
                      );
                    });
              });
            });

        try {
          await widget.uploader.downloadFileToPath(dropboxPath, File(savePath),
              onProgress: (p) {
            if (_downloadProgressController != null &&
                !_downloadProgressController!.isClosed) {
              _downloadProgressController!.add(p);
            }
          });
          if (mounted) Navigator.pop(context);
          _showSnack('Saved to $savePath');
        } catch (e) {
          if (mounted) Navigator.pop(context);
          _showSnack('Download failed: $e', isError: true);
        }
      }
      return;
    }

    // Web Logic
    if (isDistributed) {
      showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return StatefulBuilder(builder: (context, setState) {
              return StreamBuilder<double>(
                  stream:
                      _downloadProgressController?.stream ?? Stream.value(0.0),
                  initialData: 0.0,
                  builder: (context, snapshot) {
                    final p = snapshot.data ?? 0.0;
                    return AlertDialog(
                      backgroundColor: KeeprTheme.surface,
                      title: Text("Downloading...",
                          style: GoogleFonts.inter(color: Colors.white)),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                              value: p,
                              backgroundColor: Colors.white10,
                              color: KeeprTheme.primary),
                          const SizedBox(height: 10),
                          Text("${(p * 100).toStringAsFixed(1)}%",
                              style: GoogleFonts.inter(color: Colors.white70))
                        ],
                      ),
                    );
                  });
            });
          });

      try {
        final bytes = await widget.uploader.downloadDistributedFile(
            item['file_id_ref'], sizeMb, onProgress: (p) {
          if (_downloadProgressController != null &&
              !_downloadProgressController!.isClosed) {
            _downloadProgressController!.add(p);
          }
        });

        Navigator.pop(context); // Close dialog

        // Ensure we pass a typed buffer to the JS Blob constructor to avoid JS string coercion
        final u8 = Uint8List.fromList(bytes);
        print(
            '[Download] final assembled bytes: ${u8.length} (expected ${(sizeMb * 1024 * 1024).round()})');
        final blob = html.Blob([u8], 'application/octet-stream');
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)
          ..setAttribute("download", name)
          ..click();
        html.Url.revokeObjectUrl(url);
        _showSnack('Download started');
      } catch (e) {
        Navigator.pop(context); // Close dialog
        _showSnack('Distributed download failed: $e', isError: true);
      }
      return;
    }

    // Legacy / Single file download (WEB)
    try {
      _showSnack('Preparing download...');
      final link = await widget.uploader.getTemporaryLink(dropboxPath);
      // Use anchor to force download if possible, otherwise launch
      final anchor = html.AnchorElement(href: link)
        ..setAttribute("download", name)
        ..click();
      /*
      if (await canLaunchUrl(Uri.parse(link))) {
        await launchUrl(Uri.parse(link));
      } else {
        throw Exception("Could not launch link");
      }
      */
    } catch (e) {
      _showSnack('Download failed: $e', isError: true);
    }
  }

  Future<void> _downloadFolder(String path) async {
    try {
      if (kIsWeb) {
        _showSnack('Preparing folder download...');
        final url = widget.uploader.getFolderDownloadUrl(path, widget.userId);
        if (await canLaunchUrl(Uri.parse(url))) {
          await launchUrl(Uri.parse(url));
          return;
        }
        throw Exception('Could not launch url');
      }

      // Android/Windows/Desktop: avoid external browser zip endpoint and
      // download folder contents directly from metadata.
      if (Platform.isAndroid) {
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }

      final secureStorage = const FlutterSecureStorage();
      final isMobile = defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;

      String? baseDirectory;
      if (isMobile) {
        baseDirectory = await secureStorage.read(key: 'download_path');
      }
      baseDirectory ??= await FilePicker.platform.getDirectoryPath();
      if (baseDirectory == null || baseDirectory.isEmpty) {
        _showSnack('Download cancelled');
        return;
      }

      final files = await _collectFolderFiles(path);
      if (files.isEmpty) {
        _showSnack('No files found in this folder');
        return;
      }

      final folderName =
          (path == '/' ? 'root' : path.split('/').where((s) => s.isNotEmpty).last);
      final targetRoot = Directory(p.join(baseDirectory, folderName));
      await targetRoot.create(recursive: true);

      double progress = 0;
      String currentFile = '';
      void Function(void Function())? updateDialog;

      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              updateDialog = setDialogState;
              return AlertDialog(
                backgroundColor: KeeprTheme.surface,
                title: Text('Downloading folder...',
                    style: GoogleFonts.inter(color: Colors.white)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white10,
                      color: KeeprTheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${(progress * 100).toStringAsFixed(1)}%',
                      style: GoogleFonts.inter(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentFile,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(color: Colors.white54),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      }

      for (int i = 0; i < files.length; i++) {
        final item = files[i];
        final itemPath = (item['path'] ?? '').toString();
        final relative = _relativePathWithinFolder(path, itemPath);
        currentFile = relative;
        updateDialog?.call(() {});

        final target = File(p.join(targetRoot.path, relative));
        await target.parent.create(recursive: true);

        final dropboxPath = (item['dropbox_path'] ?? item['path']).toString();
        final isDistributed =
            (dropboxPath == 'distributed' && item['file_id_ref'] != null);

        if (isDistributed) {
          final sizeMb =
              double.tryParse(item['size_mb']?.toString() ?? '0') ?? 0;
          final bytes = await widget.uploader
              .downloadDistributedFile(item['file_id_ref'], sizeMb);
          await target.writeAsBytes(bytes, flush: true);
        } else {
          await widget.uploader.downloadFileToPath(dropboxPath, target);
        }

        progress = (i + 1) / files.length;
        updateDialog?.call(() {});
      }

      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _showSnack('Folder downloaded to ${targetRoot.path}');
    } catch (e) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showSnack('Download failed: $e', isError: true);
    }
  }

  Future<List<Map<String, dynamic>>> _collectFolderFiles(String folderPath) async {
    final results = <Map<String, dynamic>>[];
    final queue = <String>[folderPath];

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final res = await widget.api.listFiles(widget.userId, path: current);
      final rawItems = (res['items'] as List?) ?? const [];

      for (final raw in rawItems) {
        final item = Map<String, dynamic>.from(raw as Map);
        if (item['is_folder'] == true) {
          final nextPath = (item['path'] ?? '').toString();
          if (nextPath.isNotEmpty) queue.add(nextPath);
        } else {
          results.add(item);
        }
      }
    }

    return results;
  }

  String _relativePathWithinFolder(String root, String fullPath) {
    if (root == '/') {
      return fullPath.replaceFirst(RegExp(r'^/+'), '');
    }

    final normalizedRoot = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    if (fullPath.startsWith('$normalizedRoot/')) {
      return fullPath.substring(normalizedRoot.length + 1);
    }
    return fullPath.split('/').where((s) => s.isNotEmpty).last;
  }

  void _navigateUp() {
    if (currentPath == '/') return;
    var p = currentPath;
    if (p.endsWith('/') && p.length > 1) p = p.substring(0, p.length - 1);

    final lastSlash = p.lastIndexOf('/');
    if (lastSlash <= 0) {
      setState(() => currentPath = '/');
    } else {
      setState(() => currentPath = p.substring(0, lastSlash));
    }
    _refresh();
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final res = await showDialog<String?>(
        context: context,
        builder: (ctx) {
          return Dialog(
            backgroundColor: KeeprTheme.surface,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NEW FOLDER',
                      style: GoogleFonts.zillaSlab(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'FOLDER NAME',
                        hintStyle: TextStyle(
                            color: Colors.white.withAlpha((0.3 * 255).round())),
                        enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                                color: Colors.white
                                    .withAlpha((0.2 * 255).round()))),
                        focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white)),
                      )),
                  const SizedBox(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text('CANCEL',
                              style: GoogleFonts.inter(color: Colors.white54))),
                      const SizedBox(width: 16),
                      TextButton(
                          onPressed: () =>
                              Navigator.pop(ctx, controller.text.trim()),
                          child: Text('CREATE',
                              style: GoogleFonts.inter(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)))
                    ],
                  )
                ],
              ),
            ),
          );
        });

    if (res == null || res.isEmpty) return;
    final newPath = currentPath == '/' ? '/$res' : '$currentPath/$res';
    final ok = await widget.api.createFolder(widget.userId, newPath);
    if (ok) {
      _refresh();
      _showSnack('Folder created');
    } else {
      _showSnack('Failed to create folder', isError: true);
    }
  }

  Future<void> _createFile() async {
    final TextEditingController nameController = TextEditingController();
    final String? fileName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KeeprTheme.surface,
        title: Text("New File", style: GoogleFonts.inter(color: Colors.white)),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "example.txt",
            hintStyle: TextStyle(color: Colors.white54),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white24)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("CANCEL", style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: Text("CREATE",
                  style: TextStyle(
                      color: KeeprTheme.primary, fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (fileName == null || fileName.isEmpty) return;

    try {
      _showSnack('Creating file...');
      String fullPath =
          currentPath == '/' ? '/$fileName' : '$currentPath/$fileName';

      // Upload empty string
      await widget.uploader.uploadStringContent("", widget.userId, fullPath);

      _showSnack('File created successfully');
      _refresh();
    } catch (e) {
      _showSnack('Failed to create file: $e', isError: true);
    }
  }

  Future<void> _openUploadDialog() async {
    final tasks = await BackgroundUploadService.getActiveTasks();
    if (tasks.any((t) => t['type'] == 'delete')) {
      _showSnack('Please wait for deletions to complete.', isError: true);
      return;
    }

    if (!mounted) return;
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => UploadDialog(
              uploader: widget.uploader,
              userId: widget.userId,
              currentPath: currentPath,
              onUploadComplete: () {
                _refresh();
              },
            ));
  }

  // --- UI COMPONENTS ---

  Widget _buildBreadcrumbs() {
    if (currentPath == '/') return const SizedBox.shrink();

    // Split path into clickable segments
    // e.g. /work/docs -> [work, docs]
    final segments = currentPath.split('/').where((s) => s.isNotEmpty).toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      width: double.infinity,
      color: Colors.black.withAlpha((0.2 * 255).round()), // Darker strip
      child: Row(
        children: [
          GestureDetector(
              onTap: () {
                setState(() => currentPath = '/');
                _refresh();
              },
              child: Text('ROOT',
                  style: GoogleFonts.inter(
                      color: Colors.white54,
                      fontWeight: FontWeight.bold,
                      fontSize: 12))),
          ...segments.asMap().entries.map((arg) {
            final idx = arg.key;
            final segment = arg.value;
            final isLast = idx == segments.length - 1;

            // Reconstruct path for this segment
            // /a/b/c -> index 1 (b) -> /a/b
            String segmentPath = '/' + segments.sublist(0, idx + 1).join('/');

            return Row(
              children: [
                Icon(Icons.chevron_right,
                    size: 16,
                    color: Colors
                        .white24), // Keep small chevron purely for spacing/separator, or use text ">"
                GestureDetector(
                    onTap: isLast
                        ? null
                        : () {
                            setState(() => currentPath = segmentPath);
                            _refresh();
                          },
                    child: Text(segment.toUpperCase(),
                        style: GoogleFonts.inter(
                            color: isLast ? Colors.white : Colors.white54,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
              ],
            );
          })
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    // Determine screen width
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth <= 600;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          // Logo (Left Aligned) - Becomes invisible when search overlaps on small screens
          Align(
            alignment: Alignment.centerLeft,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: (_isSearchExpanded && isMobile) ? 0.0 : 1.0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset('assets/keeprlogo.svg',
                      width: 28,
                      height: 28,
                      colorFilter: const ColorFilter.mode(
                          Colors.white, BlendMode.srcIn)),
                  const SizedBox(width: 8),
                  Text(
                    'KEEPR',
                    style: GoogleFonts.zillaSlab(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1.5),
                  ),
                ],
              ),
            ),
          ),

          // Right Side Controls (Search + Menu)
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(child: _buildSearchBar()),
                const SizedBox(width: 10),
                _buildQuickActionsMenu(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionsMenu() {
    final uploadCount = _activeTasks
        .where((task) => task['type']?.toString() == 'upload')
        .length;
    final downloadCount = _activeTasks
        .where((task) => task['type']?.toString() == 'download')
        .length;

    return PopupMenuButton<String>(
      color: const Color(0xFF111827),
      tooltip: 'Quick Actions',
      onSelected: (value) {
        if (value == 'refresh') {
          _refresh();
        } else if (value == 'upload') {
          _openUploadDialog();
        } else if (value == 'new_file') {
          _createFile();
        } else if (value == 'new_folder') {
          _createFolder();
        } else if (value == 'bg_uploads') {
          _openActiveTransfersDialog(type: 'upload');
        } else if (value == 'bg_downloads') {
          _openActiveTransfersDialog(type: 'download');
        } else if (value == 'saved_messages') {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => SavedMessagesScreen(api: widget.api)));
        } else if (value == 'notes_studio') {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => NotesEditorScreen(api: widget.api)));
        } else if (value == 'reset_pin') {
          final storage = const FlutterSecureStorage();
          storage.read(key: 'auth_token').then((token) {
            if (token != null) {
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SetPinScreen(
                            api: widget.api,
                            token: token,
                            userEmail: widget.userId,
                            uploader: widget.uploader,
                          )));
            }
          });
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'refresh',
          child: Row(children: [
            const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text('Refresh', style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'reset_pin',
          child: Row(children: [
            const Icon(Icons.lock_reset, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text('Reset PIN', style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'upload',
          child: Row(children: [
            const Icon(Icons.upload_rounded,
                color: Color(0xFF60A5FA), size: 18),
            const SizedBox(width: 10),
            Text('Upload', style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'new_file',
          child: Row(children: [
            const Icon(Icons.note_add_rounded,
                color: Color(0xFF34D399), size: 18),
            const SizedBox(width: 10),
            Text('Create File', style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'new_folder',
          child: Row(children: [
            const Icon(Icons.create_new_folder_rounded,
                color: Color(0xFFF59E0B), size: 18),
            const SizedBox(width: 10),
            Text('Create Folder',
                style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        const PopupMenuDivider(height: 1),
        PopupMenuItem(
          value: 'saved_messages',
          child: Row(children: [
            const Icon(Icons.bookmark_add_outlined,
                color: Color(0xFF22D3EE), size: 18),
            const SizedBox(width: 10),
            Text('Saved Messages',
                style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        PopupMenuItem(
          value: 'notes_studio',
          child: Row(children: [
            const Icon(Icons.edit_note_rounded,
                color: Color(0xFFA78BFA), size: 18),
            const SizedBox(width: 10),
            Text('Notes Studio',
                style: GoogleFonts.inter(color: Colors.white)),
          ]),
        ),
        if (!kIsWeb) ...[
          const PopupMenuDivider(height: 1),
          PopupMenuItem(
            value: 'bg_uploads',
            child: Row(children: [
              const Icon(Icons.cloud_upload_outlined,
                  color: Color(0xFF60A5FA), size: 18),
              const SizedBox(width: 10),
              Text('Currently Uploading ($uploadCount)',
                  style: GoogleFonts.inter(color: Colors.white)),
            ]),
          ),
          PopupMenuItem(
            value: 'bg_downloads',
            child: Row(children: [
              const Icon(Icons.cloud_download_outlined,
                  color: Color(0xFF34D399), size: 18),
              const SizedBox(width: 10),
              Text('Currently Downloading ($downloadCount)',
                  style: GoogleFonts.inter(color: Colors.white)),
            ]),
          ),
        ],
      ],
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha((0.08 * 255).round()),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: const Icon(Icons.more_vert_rounded, color: Colors.white),
      ),
    );
  }

  Widget _buildSearchBar() {
    final isDesktop = MediaQuery.of(context).size.width > 600;
    // On mobile, expanded width is limited to prevent overflow with logo and other elements
    // The screen width minus (padding + logo + spacer + menu + initial search width buffer)
    // 20 (left pad) + 20 (right pad) + 42 (menu button) + 10 (spacing) = 92
    // We add a bit more buffer (e.g. 8) just in case = 100
    final double screenWidth = MediaQuery.of(context).size.width;
    final double maxMobileWidth = screenWidth - 100; // Use a safer margin
    final double expandedWidth = isDesktop ? 300.0 : maxMobileWidth;
    final double collapsedWidth = 42.0;

    // When expanded on mobile, we might need to overlay or hide the logo,
    // but for now let's just make sure it fits.
    // If screen is very narrow, we might need to hide logo when expanded.

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: _isSearchExpanded ? expandedWidth : collapsedWidth,
      height: 46,
      decoration: BoxDecoration(
        color: _isSearchExpanded
            ? const Color(0xFF1F2937)
            : const Color(0xFF4F29F0),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          if (!_isSearchExpanded)
            BoxShadow(
              color: const Color(0xFF4F29F0).withAlpha(80),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
        ],
      ),
      child: Stack(
        children: [
          // Search Input
          Positioned.fill(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _isSearchExpanded ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.only(left: 48, right: 16),
                child: Center(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
                    cursorColor: const Color(0xFF4F29F0),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      filled: true,
                      fillColor: Colors.transparent,
                      hintText: 'Search files...',
                      hintStyle: GoogleFonts.inter(
                          color: Colors.white54, fontSize: 14),
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Search Icon
          Positioned(
            left: 11,
            top: 11,
            child: GestureDetector(
              onTap: () {
                if (!_isSearchExpanded) {
                  _searchFocusNode.requestFocus();
                }
              },
              child: Icon(
                Icons.search_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          // Close Icon
          if (_isSearchExpanded && _searchQuery.isNotEmpty)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white70, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  _searchController.clear();
                  _searchFocusNode.unfocus();
                },
              ),
            ),
        ],
      ),
    );
  }

  List<dynamic> get _filteredItems {
    if (_searchQuery.isEmpty) return items;
    final q = _searchQuery.toLowerCase();
    return items.where((item) {
      final name = (item['name'] ?? '').toString().toLowerCase();
      final path = (item['path'] ?? '').toString().toLowerCase();
      return name.contains(q) || path.contains(q);
    }).toList(growable: false);
  }

  TextSpan _highlightedSpan(String text) {
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return TextSpan(
        text: text,
        style: GoogleFonts.inter(
            fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
      );
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }

      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }

      spans.add(TextSpan(
        text: text.substring(index, index + query.length),
        style: const TextStyle(
          color: Color(0xFF22D3EE),
          fontWeight: FontWeight.w800,
          backgroundColor: Color(0x3316465A),
        ),
      ));

      start = index + query.length;
    }

    return TextSpan(
      style: GoogleFonts.inter(
          fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
      children: spans,
    );
  }

  Widget _buildActionButton(String label, VoidCallback onTap,
      {bool highlight = false}) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
          backgroundColor: highlight
              ? Colors.white.withAlpha((0.1 * 255).round())
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: highlight
                  ? BorderSide.none
                  : BorderSide(
                      color: Colors.white.withAlpha((0.1 * 255).round())))),
      child: Text(label,
          style: GoogleFonts.inter(
              color: highlight ? Colors.white : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              letterSpacing: 1)),
    );
  }

  Widget _buildItem(Map<String, dynamic> it) {
    final bool isFolder = it['is_folder'] ?? false;
    final String name = it['name'] ?? 'Unknown';
    final String size = isFolder
        ? '-'
        : '${(double.tryParse(it['size_mb']?.toString() ?? '0') ?? 0).toStringAsFixed(2)} MB';

    // Abstract ID color
    final Color typeColor = isFolder ? const Color(0xFF00E5FF) : Colors.white24;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (isFolder) {
            setState(() => currentPath = it['path']);
            _refresh();
          } else {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => FileViewerScreen(
                          userId: widget.userId,
                          fileName: name,
                          path: it['path'],
                          dropboxPath: it['dropbox_path'] ?? it['path'],
                          fileIdRef: it['file_id_ref'], // Pass distributed ID
                          uploader: widget.uploader,
                          sizeMb: double.tryParse(
                                  it['size_mb']?.toString() ?? '0') ??
                              0,
                        )));
          }
        },
        hoverColor: Colors.white.withAlpha((0.05 * 255).round()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: Colors.white.withAlpha((0.05 * 255).round())))),
          child: Row(
            children: [
              // Type Indicator (No Icon)
              Container(
                width: 4,
                height: 40,
                color: typeColor,
              ),
              const SizedBox(width: 16),

              // Text Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: _highlightedSpan(name),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: isFolder
                                    ? Colors.blue.withAlpha((0.1 * 255).round())
                                    : Colors.white10,
                                borderRadius: BorderRadius.circular(2)),
                            child: Text(isFolder ? 'DIR' : 'FILE',
                                style: GoogleFonts.chivoMono(
                                    fontSize: 10,
                                    color: isFolder
                                        ? Colors.blueAccent
                                        : Colors.white38))),
                        const SizedBox(width: 10),
                        Text(isFolder ? 'Folder' : '$size',
                            style: GoogleFonts.inter(
                                fontSize: 12, color: Colors.white38)),
                      ],
                    )
                  ],
                ),
              ),

              // Action
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () {
                      if (isFolder)
                        _downloadFolder(it['path']);
                      else
                        _downloadFile(it);
                    },
                    child: Text('DOWNLOAD',
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Colors.white54,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (!kIsWeb && !Platform.isWindows) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _confirmDelete(it),
                      child: Text('DELETE',
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              color: Colors.redAccent.withOpacity(0.8),
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> item) async {
    final name = item['name'];
    final bool isFolder = item['is_folder'] ?? false;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              backgroundColor: KeeprTheme.surface,
              title: Text("Delete $name?",
                  style: GoogleFonts.inter(color: Colors.white)),
              content: Text(
                  isFolder
                      ? "This will permanently delete the folder and ALL its contents recursively.This cannot be undone."
                      : "This will permanently delete the file",
                  style: GoogleFonts.inter(color: Colors.white70)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text("CANCEL",
                        style: TextStyle(color: Colors.white54))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text("DELETE",
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold))),
              ],
            ));

    if (confirmed == true) {
      if (!kIsWeb &&
          (Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
        try {
          final uuid = const Uuid().v4();
          await BackgroundUploadService.startDeletes(
            backendUrl: widget.api.backendBase,
            userId: widget.userId,
            filePaths: [item['path']],
            fileNames: [name],
            taskIds: [uuid],
          );
          _showSnack('deleting: $name');
          setState(() {
            // Optimistically remove from list? Or just let user refresh.
            // _refresh();
            // _refresh might fetch old state.
          });
          // Give it a second then refresh
          Future.delayed(const Duration(seconds: 1), _refresh);
        } catch (e) {
          _showSnack('Failed to start delete: $e', isError: true);
        }
      } else {
        try {
          _showSnack('Deleting $name...');
          await widget.api.deleteFile(widget.userId, item['path']);
          _showSnack('Deleted $name');
          _refresh();
        } catch (e) {
          _showSnack('Failed to delete: $e', isError: true);
        }
      }
    }
  }

  Widget _buildStorageOverview() {
    final size = MediaQuery.of(context).size;
    final isCompact = size.width < 420;

    if (_loadingStorage) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Container(
          height: 100,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha((0.03 * 255).round()),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withAlpha((0.05 * 255).round())),
          ),
          child: const Center(child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2)),
        ),
      );
    }

    // Format bytes to GB
    final double usedGb = _totalUsedBytes / (1024 * 1024 * 1024);
    final double totalGb = _totalAllocatedBytes / (1024 * 1024 * 1024);
    final double progress = totalGb > 0 ? (usedGb / totalGb).clamp(0.0, 1.0) : 0;
    
    // Determine healthy/warning/critical color
    Color statusColor = const Color(0xFF34D399); // Green
    if (progress > 0.9) {
      statusColor = const Color(0xFFEF4444); // Red
    } else if (progress > 0.7) {
      statusColor = const Color(0xFFF59E0B); // Orange
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: GlassmorphicContainer(
        width: double.infinity,
        height: 100,
        borderRadius: 16,
        blur: 10,
        alignment: Alignment.center,
        border: 1,
        linearGradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withAlpha((0.08 * 255).round()),
            Colors.white.withAlpha((0.02 * 255).round()),
          ],
        ),
        borderGradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withAlpha((0.2 * 255).round()),
            Colors.white.withAlpha((0.05 * 255).round()),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: statusColor.withAlpha((0.2 * 255).round()),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.cloud_outlined, color: statusColor, size: 28),
              ),
              const SizedBox(width: 16),
              
              // Text & Progress
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isCompact)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CLUSTER STORAGE',
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${usedGb.toStringAsFixed(2)} GB / ${totalGb.toStringAsFixed(2)} GB',
                            style: GoogleFonts.chivoMono(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'CLUSTER STORAGE',
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            '${usedGb.toStringAsFixed(2)} GB / ${totalGb.toStringAsFixed(2)} GB',
                            style: GoogleFonts.chivoMono(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 10),
                    // Progress Bar
                    Container(
                      height: 6,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha((0.1 * 255).round()),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progress,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                statusColor.withAlpha((0.6 * 255).round()),
                                statusColor,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(3),
                            boxShadow: [
                              BoxShadow(
                                color: statusColor.withAlpha((0.5 * 255).round()),
                                blurRadius: 6,
                                spreadRadius: 1,
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KeeprTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (currentPath == '/') _buildStorageOverview(),
            _buildBreadcrumbs(),
            if (loading)
              const LinearProgressIndicator(
                  color: Color(0xFF00E5FF),
                  backgroundColor: Colors.transparent,
                  minHeight: 2),
            Expanded(
              child: _filteredItems.isEmpty && !loading
                  ? Center(
                      child: Text(
                          _searchQuery.isEmpty
                              ? 'NO FILES FOUND'
                              : 'NO SEARCH RESULTS',
                          style: GoogleFonts.zillaSlab(
                              color: Colors.white24,
                              fontSize: 24,
                              fontWeight: FontWeight.bold)))
                  : ListView.builder(
                      itemCount: _filteredItems.length,
                      itemBuilder: (ctx, i) =>
                          _buildItem(_filteredItems[i] as Map<String, dynamic>),
                    ),
            )
          ],
        ),
      ),
    );
  }
}
