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

import 'package:flutter_svg/flutter_svg.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

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

  @override
  void initState() {
    super.initState();
    _downloadProgressController = StreamController<double>.broadcast();
    _refresh();
  }

  @override
  void dispose() {
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

      // Show progress dialog
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
        if (isDistributed) {
          await widget.uploader.downloadDistributedFileToFile(
              item['file_id_ref'], sizeMb, File(savePath), onProgress: (p) {
            if (_downloadProgressController != null &&
                !_downloadProgressController!.isClosed) {
              _downloadProgressController!.add(p);
            }
          });
        } else {
          // Regular / Legacy file download
          await widget.uploader.downloadFileToPath(dropboxPath, File(savePath),
              onProgress: (p) {
            if (_downloadProgressController != null &&
                !_downloadProgressController!.isClosed) {
              _downloadProgressController!.add(p);
            }
          });
        }
        Navigator.pop(context); // Close dialog
        _showSnack('Saved to $savePath');
      } catch (e) {
        Navigator.pop(context); // Close dialog on error
        _showSnack('Download failed: $e', isError: true);
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
      _showSnack('Zipping and downloading folder...');
      final url = widget.uploader.getFolderDownloadUrl(path, widget.userId);
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } else {
        throw Exception("Could not launch url");
      }
    } catch (e) {
      _showSnack('Download failed: $e', isError: true);
    }
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

  void _openUploadDialog() {
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
    final isDesktop = MediaQuery.of(context).size.width > 600;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: isDesktop
          ? Row(
              children: [
                SvgPicture.asset('assets/keeprlogo.svg',
                    width: 32,
                    height: 32,
                    colorFilter:
                        const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
                const SizedBox(width: 12),
                Text(
                  'KEEPR',
                  style: GoogleFonts.zillaSlab(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5),
                ),
                const Spacer(),
                _buildActionButton('UPLOAD', _openUploadDialog,
                    highlight: true),
                const SizedBox(width: 15),
                _buildActionButton('NEW FILE', _createFile),
                const SizedBox(width: 15),
                _buildActionButton('NEW FOLDER', _createFolder),
                const SizedBox(width: 15),
                _buildActionButton('REFRESH', _refresh),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
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
                    IconButton(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh, color: Colors.white70),
                      tooltip: "Refresh",
                    )
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _buildActionButton('UPLOAD', _openUploadDialog,
                            highlight: true)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: _buildActionButton('NEW FILE', _createFile)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: _buildActionButton('NEW FOLDER', _createFolder)),
                  ],
                )
              ],
            ),
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
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KeeprTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            _buildBreadcrumbs(),
            if (loading)
              const LinearProgressIndicator(
                  color: Color(0xFF00E5FF),
                  backgroundColor: Colors.transparent,
                  minHeight: 2),
            Expanded(
              child: items.isEmpty && !loading
                  ? Center(
                      child: Text("NO FILES FOUND",
                          style: GoogleFonts.zillaSlab(
                              color: Colors.white24,
                              fontSize: 24,
                              fontWeight: FontWeight.bold)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (ctx, i) =>
                          _buildItem(items[i] as Map<String, dynamic>),
                    ),
            )
          ],
        ),
      ),
    );
  }
}
