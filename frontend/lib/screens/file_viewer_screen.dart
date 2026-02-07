import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:universal_html/html.dart' as html;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../services/folder_upload_service.dart';
import '../theme/keepr_theme.dart';

class FileViewerScreen extends StatefulWidget {
  final String userId;
  final String fileName;
  final String path;
  final String dropboxPath;
  final String? fileIdRef;
  final FolderUploadService uploader;
  final double sizeMb;

  const FileViewerScreen({
    super.key,
    required this.userId,
    required this.fileName,
    required this.path,
    required this.dropboxPath,
    this.fileIdRef,
    required this.uploader,
    this.sizeMb = 0,
  });

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  bool _loading = true;
  String? _downloadUrl;
  List<int>? _fileBytes;
  String? _textContent;
  bool _saving = false;
  late TextEditingController _codeController;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
    _init();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      if (widget.dropboxPath == 'distributed' && widget.fileIdRef != null) {
        // Distributed: Download bytes directly
        final bytes = await widget.uploader
            .downloadDistributedFile(widget.fileIdRef!, widget.sizeMb);
        setState(() {
          _fileBytes = bytes;
        });
        debugPrint(
            '[FileViewer] downloaded bytes length=${bytes.length} (expected ${(widget.sizeMb * 1024 * 1024).round()})');

        if (_isCodeFile) {
          _textContent = utf8.decode(bytes);
          _codeController.text = _textContent!;
        }
      } else {
        // Standard / Legacy
        final url = await widget.uploader.getTemporaryLink(widget.dropboxPath);
        setState(() {
          _downloadUrl = url;
        });

        if (_isCodeFile) {
          // fetch content
          final resp = await http.get(Uri.parse(url));
          if (resp.statusCode == 200) {
            _textContent = resp.body;
            _codeController.text = _textContent!;
          }
        }
      }
    } catch (e) {
      debugPrint("Error loading file: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveFile() async {
    setState(() => _saving = true);
    try {
      await widget.uploader.uploadStringContent(
          _codeController.text,
          widget.userId,
          widget
              .path // logical path usually maps to dropbox path in simple implementation
          );
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("File saved!")));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Save failed: $e"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _isImage {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'ico'].contains(ext);
  }

  bool get _isCodeFile {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return [
      'txt',
      'json',
      'dart',
      'js',
      'ts',
      'html',
      'css',
      'py',
      'java',
      'c',
      'cpp',
      'h',
      'md',
      'xml',
      'yaml',
      'yml',
      'sql',
      'sh'
    ].contains(ext);
  }

  bool get _isVideo {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
  }

  bool get _isPdf {
    return widget.fileName.toLowerCase().endsWith('.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KeeprTheme.background,
      appBar: AppBar(
        title: Text(widget.fileName, style: GoogleFonts.inter(fontSize: 16)),
        backgroundColor: KeeprTheme.surface,
        actions: [
          if (_isCodeFile && !_loading)
            IconButton(
              onPressed: _saving ? null : _saveFile,
              icon: _saving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ))
                  : Icon(Icons.save),
              tooltip: "Save Changes",
            ),
          if (_downloadUrl != null)
            IconButton(
              icon: Icon(Icons.download),
              onPressed: () => launchUrl(Uri.parse(_downloadUrl!)),
              tooltip: "open in Browser",
            )
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_downloadUrl == null && _fileBytes == null) {
      return Center(
          child: Text("Could not load file.",
              style: GoogleFonts.inter(color: Colors.white54)));
    }

    if (_isImage) {
      return Center(
        child: InteractiveViewer(
          child: _fileBytes != null
              ? Image.memory(
                  Uint8List.fromList(_fileBytes!),
                  errorBuilder: (ctx, err, stack) =>
                      Icon(Icons.broken_image, size: 64, color: Colors.white24),
                )
              : Image.network(
                  _downloadUrl!,
                  loadingBuilder: (ctx, child, chunk) {
                    if (chunk == null) return child;
                    return Center(
                        child: CircularProgressIndicator(
                            value: chunk.expectedTotalBytes != null
                                ? chunk.cumulativeBytesLoaded /
                                    chunk.expectedTotalBytes!
                                : null));
                  },
                  errorBuilder: (ctx, err, stack) =>
                      Icon(Icons.broken_image, size: 64, color: Colors.white24),
                ),
        ),
      );
    }

    if (_isCodeFile) {
      return Container(
        color: Colors.black.withAlpha((0.3 * 255).round()), // Darker editor bg
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _codeController,
          maxLines: null,
          expands: true,
          style: GoogleFonts.firaCode(
              color: const Color(0xFFa9b7c6), // Classic dark theme code color
              fontSize: 14,
              height: 1.5),
          decoration: InputDecoration(border: InputBorder.none),
        ),
      );
    }

    if (_isPdf) {
      return _fileBytes != null
          ? SfPdfViewer.memory(
              Uint8List.fromList(_fileBytes!),
              onDocumentLoadFailed: (details) => ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(
                      content: Text("Failed to load PDF: ${details.error}"))),
            )
          : SfPdfViewer.network(
              _downloadUrl!,
              onDocumentLoadFailed: (PdfDocumentLoadFailedDetails details) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text("Failed to load PDF: ${details.error}")));
              },
            );
    }

    // Fallback for Video/Other
    IconData icon = Icons.insert_drive_file;
    String actionLabel = "OPEN FILE";

    if (_isVideo) {
      icon = Icons.play_circle_outline;
      actionLabel = "PLAY VIDEO";
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 80, color: Colors.white24),
          const SizedBox(height: 20),
          Text("Preview not supported natively.",
              style: GoogleFonts.inter(color: Colors.white54)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () async {
              if (_downloadUrl != null) {
                await launchUrl(Uri.parse(_downloadUrl!));
              } else if (_fileBytes != null) {
                if (kIsWeb) {
                  final blob = html.Blob([_fileBytes!]);
                  final url = html.Url.createObjectUrlFromBlob(blob);
                  final anchor = html.AnchorElement(href: url)
                    ..setAttribute("download", widget.fileName)
                    ..click();
                  html.Url.revokeObjectUrl(url);
                } else {
                  try {
                    final tempDir = await getTemporaryDirectory();
                    final tempFile = File('${tempDir.path}/${widget.fileName}');
                    await tempFile.writeAsBytes(_fileBytes!);
                    final uri = Uri.file(tempFile.path);
                    if (!await launchUrl(uri)) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Could not open file.")));
                      }
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text("Error: $e")));
                    }
                  }
                }
              }
            },
            icon: Icon(Icons.open_in_new),
            label: Text(actionLabel),
            style: ElevatedButton.styleFrom(
                backgroundColor:
                    KeeprTheme.primary.withAlpha((0.8 * 255).round()),
                foregroundColor: Colors.white),
          )
        ],
      ),
    );
  }
}
