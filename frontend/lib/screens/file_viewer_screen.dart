import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
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

  const FileViewerScreen({
    super.key,
    required this.userId,
    required this.fileName,
    required this.path,
    required this.dropboxPath,
    this.fileIdRef,
    required this.uploader,
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
        final bytes =
            await widget.uploader.downloadDistributedFile(widget.fileIdRef!);
        setState(() {
          _fileBytes = bytes;
        });

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

  Future<void> _saveLocal() async {
    if (_fileBytes == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("To save file, please use the 'Download' option in File Manager.")));
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
          // If we have a download URL, show external open
          if (_downloadUrl != null)
            IconButton(
              icon: Icon(Icons.open_in_new),
              onPressed: () => launchUrl(Uri.parse(_downloadUrl!)),
              tooltip: "Open External",
            ),
          // If distributed (bytes only), show a 'save' hint or just nothing (since we have Download in Manager)
          if (_fileBytes != null && !_isCodeFile)
             IconButton(
               icon: Icon(Icons.info_outline),
               onPressed: () {
                 ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Distributed file. View only mode.")));
               },
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

    if (_isPdf) {
      if (_fileBytes != null) {
        return SfPdfViewer.memory(
              Uint8List.fromList(_fileBytes!),
              onDocumentLoadFailed: (details) => ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(
                      content: Text("Failed to load PDF: ${details.error}"))));
      } else {
        return SfPdfViewer.network(
              _downloadUrl!,
              onDocumentLoadFailed: (details) => ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(
                      content: Text("Failed to load PDF: ${details.error}"))));
      }
    }

    if (_isImage) {
      return Center(
        child: InteractiveViewer(
          minScale: 0.1,
          maxScale: 5.0,
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
        color: Colors.black.withOpacity(0.3), // Darker editor bg
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
    
    // Video Stub
    if (_isVideo) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             Icon(Icons.play_circle_outline, size: 64, color: Colors.white),
             SizedBox(height: 16),
             Text("Video preview not supported yet.", style: TextStyle(color: Colors.white70))
          ],
        )
      );
    }

    // Default Fallback
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text("Preview not available", style: GoogleFonts.inter(color: Colors.white54)),
          if (_downloadUrl != null)
            ElevatedButton(
              onPressed: () => launchUrl(Uri.parse(_downloadUrl!)),
              child: Text("Open External"),
            )
        ],
      )
    );
  }
}
