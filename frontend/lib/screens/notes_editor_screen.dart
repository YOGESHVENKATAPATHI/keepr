import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import '../services/api_service.dart';
import '../utils/storage_helper.dart';

class NotesEditorScreen extends StatefulWidget {
  final ApiService api;

  const NotesEditorScreen({super.key, required this.api});

  @override
  State<NotesEditorScreen> createState() => _NotesEditorScreenState();
}

class _NotesEditorScreenState extends State<NotesEditorScreen> {
  final _storage = const FlutterSecureStorage();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  String? _token;
  bool _loading = false;
  List<Map<String, dynamic>> _notes = [];
  List<Map<String, dynamic>> _assets = [];
  int? _activeNoteId;
  StreamSubscription<html.MouseEvent>? _webDragOverSub;
  StreamSubscription<html.MouseEvent>? _webDropSub;
  StreamSubscription<html.Event>? _webPasteSub;

  bool _previewMode = false;
  final Map<String, String> _assetLinkCache = {};

  static final RegExp _assetImageRegex = RegExp(
      r'!\[([^\]]*)\]\(asset:([^\s\)]+)(?:\s+"([^"]*)")?\)');

  @override
  void initState() {
    super.initState();
    _setupWebFileIntake();
    _bootstrap();
  }

  @override
  void dispose() {
    _webDragOverSub?.cancel();
    _webDropSub?.cancel();
    _webPasteSub?.cancel();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _setupWebFileIntake() {
    if (!kIsWeb) return;

    _webDragOverSub = html.document.onDragOver.listen((event) {
      event.preventDefault();
    });

    _webDropSub = html.document.onDrop.listen((event) async {
      event.preventDefault();
      if (_activeNoteId == null || _token == null) return;

      final files = event.dataTransfer.files;
      if (files == null || files.isEmpty) return;
      await _uploadAssetsFromWebFiles(files.toList());
    });

    _webPasteSub = html.document.onPaste.listen((event) async {
      if (_activeNoteId == null || _token == null) return;
      final data = event.clipboardData;
      final files = data?.files;
      if (files == null || files.isEmpty) return;

      event.preventDefault();
      await _uploadAssetsFromWebFiles(files.toList());
    });
  }

  Future<void> _bootstrap() async {
    final secureToken = await _storage.read(key: 'auth_token');
    final fallback = await getLocalStorageValue('auth_token');
    _token = secureToken ?? fallback;
    await _refreshNotes();
  }

  Future<void> _refreshNotes() async {
    if (_token == null) return;
    setState(() => _loading = true);
    try {
      final items = await widget.api.listNotes(_token!);
      if (!mounted) return;
      setState(() {
        _notes = items;
      });
      if (_activeNoteId == null && _notes.isNotEmpty) {
        await _openNote((_notes.first['id'] as num).toInt());
      }
    } catch (e) {
      _showSnack('Failed to load notes: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createNote() async {
    if (_token == null) return;
    setState(() => _loading = true);
    try {
      final item = await widget.api
          .createNote(_token!, title: 'Untitled note', contentText: '');
      final id = (item['id'] as num).toInt();
      await _refreshNotes();
      await _openNote(id);
    } catch (e) {
      _showSnack('Create note failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openNote(int id) async {
    if (_token == null) return;
    setState(() => _loading = true);
    try {
      final payload = await widget.api.getNote(_token!, id);
      final note = Map<String, dynamic>.from(payload['item'] as Map);
      final assets = (payload['assets'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return;
      setState(() {
        _activeNoteId = id;
        _titleController.text = note['title']?.toString() ?? '';
        _contentController.text = note['content_text']?.toString() ?? '';
        _assets = assets;
      });
    } catch (e) {
      _showSnack('Open note failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveNote() async {
    if (_token == null || _activeNoteId == null) return;

    setState(() => _loading = true);
    try {
      await widget.api.updateNote(_token!, _activeNoteId!,
          title: _titleController.text.trim().isEmpty
              ? 'Untitled note'
              : _titleController.text.trim(),
          contentText: _contentController.text,
          contentJson: {
            'plainText': _contentController.text,
          });
      await _refreshNotes();
      _showSnack('Note saved');
    } catch (e) {
      _showSnack('Save failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteCurrentNote() async {
    if (_token == null || _activeNoteId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This will remove the note and its media records.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      await widget.api.deleteNote(_token!, _activeNoteId!);
      setState(() {
        _activeNoteId = null;
        _titleController.clear();
        _contentController.clear();
        _assets = [];
      });
      await _refreshNotes();
      _showSnack('Note deleted');
    } catch (e) {
      _showSnack('Delete failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _attachMedia() async {
    if (_token == null || _activeNoteId == null) return;

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty) return;

    await _uploadFromPlatformFiles(result.files);
  }

  Future<void> _uploadFromPlatformFiles(List<PlatformFile> files) async {
    if (_token == null || _activeNoteId == null) return;

    setState(() => _loading = true);
    try {
      for (final file in files) {
        final bytes = await _readPlatformFileBytes(file);
        await _uploadSingleAsset(
          bytes: bytes,
          fileName: file.name,
          mimeType: _inferMime(file.name),
        );
      }

      await _openNote(_activeNoteId!);
      _showSnack('Media attached');
    } catch (e) {
      _showSnack('Attach failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadAssetsFromWebFiles(List<html.File> files) async {
    if (_token == null || _activeNoteId == null || files.isEmpty) return;

    setState(() => _loading = true);
    try {
      for (final file in files) {
        final reader = html.FileReader();
        final completer = Completer<Uint8List>();
        reader.onLoadEnd.listen((_) {
          final result = reader.result;
          if (result is ByteBuffer) {
            completer.complete(Uint8List.view(result));
          } else if (result is Uint8List) {
            completer.complete(result);
          } else {
            completer.completeError(Exception('Unsupported pasted/dropped file format'));
          }
        });
        reader.onError.listen((_) {
          completer.completeError(Exception('Failed to read ${file.name}'));
        });
        reader.readAsArrayBuffer(file);

        final bytes = await completer.future;
        await _uploadSingleAsset(
          bytes: bytes,
          fileName: file.name,
          mimeType: file.type.isNotEmpty ? file.type : _inferMime(file.name),
        );
      }

      await _openNote(_activeNoteId!);
      _showSnack('Media attached from drop/paste');
    } catch (e) {
      _showSnack('Drop/paste upload failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadSingleAsset({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final sizeMb = bytes.length / (1024 * 1024);
    final init = await widget.api.initNoteMediaUpload(_token!, _activeNoteId!,
        fileName: fileName, mimeType: mimeType, sizeMb: sizeMb);

    final accessToken = init['accessToken']?.toString() ?? '';
    final uploadPath = init['uploadPath']?.toString() ?? '';
    final storageSource = init['storageSource']?.toString() ?? 'storage_shards';
    final storageShardRef = init['storageShardRef']?.toString() ?? '';

    if (accessToken.isEmpty || uploadPath.isEmpty || storageShardRef.isEmpty) {
      throw Exception('Invalid upload init response for $fileName');
    }

    final dio = Dio();
    await dio.post('https://content.dropboxapi.com/2/files/upload',
        data: bytes,
        options: Options(headers: {
          'Authorization': 'Bearer $accessToken',
          'Dropbox-API-Arg': jsonEncode({
            'path': uploadPath,
            'mode': 'overwrite',
            'autorename': false,
            'mute': true
          }),
          'Content-Type': 'application/octet-stream'
        }));

    await widget.api.completeNoteMediaUpload(_token!, _activeNoteId!,
        assetName: fileName,
        mimeType: mimeType,
        sizeMb: sizeMb,
        dropboxPath: uploadPath,
        storageSource: storageSource,
        storageShardRef: storageShardRef);

    if (mimeType.startsWith('image/')) {
      _insertImageAtCursor(fileName, width: 480);
      await _saveNote();
    }
  }

  void _insertTextAtCursor(String insertText) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final replaced = text.replaceRange(start, end, insertText);
    _contentController.text = replaced;
    _contentController.selection =
        TextSelection.collapsed(offset: start + insertText.length);
  }

  void _insertImageAtCursor(String assetName, {int width = 480}) {
    final token = '\n![$assetName](asset:$assetName "w=$width")\n';
    setState(() {
      _insertTextAtCursor(token);
    });
  }

  int _parseImageWidth(String? title, {int fallback = 480}) {
    if (title == null || title.trim().isEmpty) return fallback;
    final m = RegExp(r'w\s*=\s*(\d+)').firstMatch(title);
    if (m == null) return fallback;
    return int.tryParse(m.group(1) ?? '') ?? fallback;
  }

  Future<void> _resizeAssetInNote(String assetName) async {
    final escaped = RegExp.escape(assetName);
    final regex =
      RegExp('!\\[$escaped\\]\\(asset:$escaped(?:\\s+"([^"]*)")?\\)');
    final match = regex.firstMatch(_contentController.text);
    final currentWidth = _parseImageWidth(match?.group(1), fallback: 480);
    double selected = currentWidth.toDouble();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Resize image'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Width: ${selected.round()} px'),
              Slider(
                min: 120,
                max: 1200,
                value: selected,
                onChanged: (v) => setDialogState(() => selected = v),
              )
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Apply')),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final replacement = '![$assetName](asset:$assetName "w=${selected.round()}")';
    setState(() {
      _contentController.text =
          _contentController.text.replaceAllMapped(regex, (_) => replacement);
    });
    await _saveNote();
  }

  Future<String> _getAssetLink(String fileName) async {
    if (_assetLinkCache.containsKey(fileName)) {
      return _assetLinkCache[fileName]!;
    }
    final asset = _assets.firstWhere((a) => a['asset_name'] == fileName, orElse: () => {});
    if (asset.isEmpty || _token == null) return '';
    try {
      final link = await widget.api.getNoteMediaTemporaryLink(_token!,
          dropboxPath: asset['dropbox_path']?.toString() ?? '',
          storageSource: asset['storage_source']?.toString() ?? 'storage_shards',
          storageShardRef: asset['storage_shard_ref']?.toString() ?? '');
      _assetLinkCache[fileName] = link;
      return link;
    } catch (e) {
      return '';
    }
  }

  Future<void> _openAsset(Map<String, dynamic> asset) async {
    if (_token == null) return;
    try {
      // Only allow opening in browser for web; mobile/desktop should download instead
      if (!kIsWeb) {
        _showSnack('Download the file instead to view it', isError: true);
        return;
      }
      final link = await widget.api.getNoteMediaTemporaryLink(_token!,
          dropboxPath: asset['dropbox_path']?.toString() ?? '',
          storageSource: asset['storage_source']?.toString() ?? 'storage_shards',
          storageShardRef: asset['storage_shard_ref']?.toString() ?? '');
      if (link.isEmpty) throw Exception('Empty link');
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    } catch (e) {
      _showSnack('Failed to open media: $e', isError: true);
    }
  }

  Future<void> _deleteAsset(Map<String, dynamic> asset) async {
    if (_token == null || _activeNoteId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Attachment?'),
        content: Text('Remove ${asset['asset_name']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      final assetId = (asset['id'] as num).toInt();
      await widget.api.deleteNoteAsset(_token!, _activeNoteId!, assetId);
      
      // Remove text reference
      final assetName = asset['asset_name']?.toString() ?? '';
      final escaped = RegExp.escape(assetName);
      setState(() {
        _contentController.text = _contentController.text
            .replaceAllMapped(
                RegExp(
                  '\\n?!\\[$escaped\\]\\(asset:$escaped(?:\\s+"[^"]*")?\\)\\n?'),
                (_) => '');
      });
      await _saveNote();
      
      await _openNote(_activeNoteId!);
      _showSnack('Attachment deleted');
    } catch (e) {
      _showSnack('Delete failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export(String format) async {
    if (_token == null || _activeNoteId == null) return;

    setState(() => _loading = true);
    try {
      final file = await widget.api.exportNote(_token!, _activeNoteId!, format);
      await _saveExportedFile(file.bytes, file.fileName, file.contentType);
      _showSnack('Exported ${file.fileName}');
    } catch (e) {
      _showSnack('Export failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveExportedFile(
      Uint8List bytes, String fileName, String contentType) async {
    if (kIsWeb) {
      final blob = html.Blob([bytes], contentType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', fileName)
        ..click();
      html.Url.revokeObjectUrl(url);
      return;
    }

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save export',
      fileName: fileName,
      bytes: null,
    );
    if (path == null) return;

    final out = File(path);
    await out.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List> _readPlatformFileBytes(PlatformFile file) async {
    if (file.bytes != null) return Uint8List.fromList(file.bytes!);
    if (file.path == null) throw Exception('File path missing for ${file.name}');
    return File(file.path!).readAsBytes();
  }

  String _inferMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.redAccent : const Color(0xFF1D4ED8),
    ));
  }

  void _insertMarkdown(String prefix, String suffix) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    if (selection.start == -1) {
      _contentController.text = text + prefix + suffix;
    } else {
      final newText = text.replaceRange(selection.start, selection.end, prefix + text.substring(selection.start, selection.end) + suffix);
      _contentController.text = newText;
      _contentController.selection = TextSelection.collapsed(offset: selection.start + prefix.length + (selection.end - selection.start));
    }
  }

  List<Map<String, dynamic>> _extractReferencedImages() {
    final out = <Map<String, dynamic>>[];
    for (final m in _assetImageRegex.allMatches(_contentController.text)) {
      final name = (m.group(2) ?? '').trim();
      if (name.isEmpty) continue;
      final title = m.group(3);
      out.add({
        'name': name,
        'width': _parseImageWidth(title, fallback: 480),
      });
    }
    return out;
  }

  Widget _buildInlineImagePreviewStrip() {
    final refs = _extractReferencedImages();
    if (refs.isEmpty) {
      return Text('No inline images yet',
          style: GoogleFonts.inter(color: Colors.white54, fontSize: 12));
    }

    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: refs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final ref = refs[index];
          final name = ref['name'].toString();
          final widthPx = (ref['width'] as int).clamp(120, 1200);
          final previewWidth = (widthPx / 4).clamp(80, 260).toDouble();
          return FutureBuilder<String>(
              future: _getAssetLink(name),
              builder: (ctx, snap) {
                final child = (snap.hasData && snap.data!.isNotEmpty)
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(snap.data!,
                            width: previewWidth,
                            height: 100,
                            fit: BoxFit.cover),
                      )
                    : Container(
                        width: previewWidth,
                        height: 100,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white24),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      );

                return GestureDetector(
                  onTap: () => _resizeAssetInNote(name),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      child,
                      const SizedBox(height: 4),
                      SizedBox(
                        width: previewWidth,
                        child: Text(
                          '$name (${widthPx}px)',
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              color: Colors.white60, fontSize: 11),
                        ),
                      )
                    ],
                  ),
                );
              });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _activeNoteId;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Scaffold(
      appBar: AppBar(
        title: Text('Notes Studio', style: GoogleFonts.inter()),
        actions: [
          IconButton(onPressed: _loading ? null : _createNote, icon: const Icon(Icons.add)),
          IconButton(onPressed: _loading || selected == null ? null : _saveNote, icon: const Icon(Icons.save)),
          PopupMenuButton<String>(
            onSelected: (v) => _export(v),
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'txt', child: Text('Export TXT')),
              PopupMenuItem(value: 'pdf', child: Text('Export PDF')),
              PopupMenuItem(value: 'docx', child: Text('Export DOCX')),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.file_download_outlined),
            ),
          ),
          IconButton(
              onPressed: _loading || selected == null ? null : _deleteCurrentNote,
              icon: const Icon(Icons.delete_outline))
        ],
      ),
      body: isMobile ? _buildMobileLayout(selected) : _buildDesktopLayout(selected),
    );
  }

  Widget _buildMobileLayout(int? selected) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(text: 'Notes (${_notes.length})'),
              Tab(text: selected != null ? 'Edit' : 'New'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                // Tab 1: Notes List
                Column(
                  children: [
                    if (_loading) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: _notes.isEmpty
                          ? Center(
                              child: Text(
                                'No notes yet. Tap + to create one.',
                                style: GoogleFonts.inter(color: Colors.white70),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _notes.length,
                              itemBuilder: (context, index) {
                                final note = _notes[index];
                                final id = (note['id'] as num).toInt();
                                final isActive = id == selected;
                                return ListTile(
                                  selected: isActive,
                                  title: Text(note['title']?.toString() ?? 'Untitled',
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    (note['updated_at']?.toString() ?? '').split('T').first,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onTap: () => _openNote(id),
                                );
                              },
                            ),
                    )
                  ],
                ),
                // Tab 2: Editor
                selected == null
                    ? Center(
                        child: Text(
                          'Create or select a note',
                          style: GoogleFonts.inter(color: Colors.white70),
                        ),
                      )
                    : _buildNoteEditor(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(int? selected) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: Column(
            children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: ListView.builder(
                  itemCount: _notes.length,
                  itemBuilder: (context, index) {
                    final note = _notes[index];
                    final id = (note['id'] as num).toInt();
                    final isActive = id == selected;
                    return ListTile(
                      selected: isActive,
                      title: Text(note['title']?.toString() ?? 'Untitled'),
                      subtitle: Text(
                        (note['updated_at']?.toString() ?? '').split('T').first,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => _openNote(id),
                    );
                  },
                ),
              )
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? Center(
                  child: Text(
                    'Create or select a note',
                    style: GoogleFonts.inter(color: Colors.white70),
                  ),
                )
              : _buildNoteEditor(),
        )
      ],
    );
  }

  Widget _buildNoteEditor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            style: GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: 'Note title'),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _previewMode = false),
                      child: Text('Edit', style: TextStyle(fontWeight: !_previewMode ? FontWeight.bold : FontWeight.normal)),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _previewMode = true;
                        _saveNote();
                      }),
                      child: Text('Preview', style: TextStyle(fontWeight: _previewMode ? FontWeight.bold : FontWeight.normal)),
                    ),
                    if (!_previewMode) ...[
                      const SizedBox(height: 24, child: VerticalDivider()),
                      IconButton(icon: const Icon(Icons.format_bold, size: 18), onPressed: () => _insertMarkdown('**', '**'), tooltip: 'Bold'),
                      IconButton(icon: const Icon(Icons.format_italic, size: 18), onPressed: () => _insertMarkdown('*', '*'), tooltip: 'Italic'),
                      IconButton(icon: const Icon(Icons.format_list_bulleted, size: 18), onPressed: () => _insertMarkdown('\n- ', ''), tooltip: 'Bullet List'),
                      IconButton(icon: const Icon(Icons.format_list_numbered, size: 18), onPressed: () => _insertMarkdown('\n1. ', ''), tooltip: 'Numbered List'),
                      IconButton(icon: const Icon(Icons.code, size: 18), onPressed: () => _insertMarkdown('`', '`'), tooltip: 'Code'),
                      IconButton(icon: const Icon(Icons.link, size: 18), onPressed: () => _insertMarkdown('[', '](url)'), tooltip: 'Link'),
                    ],
                  ],
                ),
                Expanded(
                  child: _previewMode
                      ? Container(
                          decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                          child: Markdown(
                            data: _contentController.text.isEmpty ? 'Nothing to preview' : _contentController.text,
                            sizedImageBuilder: (config) {
                              if (config.uri.scheme == 'asset') {
                                final parsedWidth =
                                    _parseImageWidth(config.title, fallback: 480)
                                        .toDouble();
                                return FutureBuilder<String>(
                                  future: _getAssetLink(config.uri.path),
                                  builder: (ctx, snap) {
                                    if (!snap.hasData || snap.data!.isEmpty) {
                                      return const SizedBox(height: 50, width: 50, child: Center(child: CircularProgressIndicator()));
                                    }
                                    return Image.network(
                                      snap.data!,
                                      width: parsedWidth,
                                      fit: BoxFit.contain,
                                    );
                                  }
                                );
                              }
                              return Image.network(
                                config.uri.toString(),
                                width: config.width,
                                height: config.height,
                                fit: BoxFit.contain,
                              );
                            },
                          ),
                        )
                      : TextField(
                          controller: _contentController,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: const InputDecoration(
                            hintText: 'Write text, paste/drag image files, then click image preview chips below to resize.',
                            border: OutlineInputBorder(),
                          ),
                        ),
                ),
              ],
            ),
          ),
          if (!_previewMode) ...[
            const SizedBox(height: 8),
            Text('Inline image preview (tap image to resize)',
                style: GoogleFonts.inter(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 6),
            _buildInlineImagePreviewStrip(),
          ],
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _loading ? null : _attachMedia,
                  icon: const Icon(Icons.attachment),
                  label: const Text('Attach Media'),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_assets.length} attachments',
                  style: GoogleFonts.inter(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: _assets.isEmpty
                ? Center(
                    child: Text('No attachments',
                        style: GoogleFonts.inter(color: Colors.white54)),
                  )
                : ListView.builder(
                    itemCount: _assets.length,
                    itemBuilder: (context, index) {
                      final asset = _assets[index];
                      return ListTile(
                        dense: true,
                        title: Text(asset['asset_name']?.toString() ?? 'asset', overflow: TextOverflow.ellipsis),
                        subtitle: Text(asset['mime_type']?.toString() ?? '', overflow: TextOverflow.ellipsis),
                        trailing: SizedBox(
                          width: 120,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: IconButton(
                                  icon: const Icon(Icons.open_in_new, color: Colors.blueAccent),
                                  iconSize: 18,
                                  onPressed: () => _openAsset(asset),
                                ),
                              ),
                              Flexible(
                                child: IconButton(
                                  icon: const Icon(Icons.photo_size_select_large, color: Colors.amberAccent),
                                  iconSize: 18,
                                  onPressed: () => _resizeAssetInNote(asset['asset_name']?.toString() ?? ''),
                                ),
                              ),
                              Flexible(
                                child: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                                  iconSize: 18,
                                  onPressed: () => _deleteAsset(asset),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }
}
