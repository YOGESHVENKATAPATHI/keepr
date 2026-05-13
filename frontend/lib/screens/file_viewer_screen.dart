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
import '../services/folder_upload_service.dart';
import '../theme/keepr_theme.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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
  String? _localFilePath;
  String? _textContent;
  bool _saving = false;
  late TextEditingController _codeController;
  
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;

  AudioPlayer? _audioPlayer;
  bool _isPlayingAudio = false;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
    _init();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _videoPlayerController?.dispose();
    _chewieController?.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  Future<void> _initAudio(String? url, String? localPath, List<int>? bytes) async {
    _audioPlayer = AudioPlayer();
    _audioPlayer!.onDurationChanged.listen((Duration d) {
      if(mounted) setState(() => _audioDuration = d);
    });
    _audioPlayer!.onPositionChanged.listen((Duration  p) {
      if(mounted) setState(() => _audioPosition = p);
    });
    _audioPlayer!.onPlayerStateChanged.listen((PlayerState s) {
      if(mounted) setState(() => _isPlayingAudio = s == PlayerState.playing);
    });

    try {
      if (url != null) {
        await _audioPlayer!.setSourceUrl(url);
      } else if (localPath != null && !kIsWeb) {
        await _audioPlayer!.setSourceDeviceFile(localPath);
      } else if (bytes != null) {
        await _audioPlayer!.setSourceBytes(Uint8List.fromList(bytes));
      }
    } catch (e) {
      debugPrint('[AudioPlayer] Init failed: $e');
    }
  }

  Future<void> _initVideoPlayer(String url) async {
    try {
      _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(url));
      await _videoPlayerController!.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoPlayerController!.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              errorMessage,
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[VideoPlayer] Init failed: $e');
    }
  }

  Future<void> _init() async {
    try {
      if (widget.dropboxPath == 'distributed' && widget.fileIdRef != null) {
        if (_isVideo || _isImage) {
          final storage = const FlutterSecureStorage();
          final token = await storage.read(key: 'auth_token');
          // For distributed media, use the backend streaming endpoint
          final streamUrl = '${widget.uploader.backendUrl}/api/files/stream/${widget.fileIdRef}?token=$token&name=${Uri.encodeComponent(widget.fileName)}';
          if (mounted) {
            setState(() {
              _downloadUrl = streamUrl;
            });
          }
          if (_isVideo) await _initVideoPlayer(streamUrl);
          if (_isAudio) await _initAudio(streamUrl, null, null);
        } else if (!kIsWeb) {
          // Native: Stream to temp file
          final tempDir = await getTemporaryDirectory();
          final filePath = '${tempDir.path}/${widget.fileName}';
          final f = File(filePath);
          await widget.uploader.downloadDistributedFileToFile(
              widget.fileIdRef!, widget.sizeMb, f);

          String? txt;
          if (_isCodeFile || _isMarkdown) {
            try {
              txt = await f.readAsString();
            } catch (e) {
              txt = "Binary content";
            }
          }

          if (mounted) {
            setState(() {
              _localFilePath = filePath;
              if (txt != null) {
                _textContent = txt;
                _codeController.text = txt;
              }
            });
          }
          if (_isAudio) await _initAudio(null, filePath, null);
          debugPrint('[FileViewer] downloaded to $filePath');
        } else {
          // Web: RAM
          final bytes = await widget.uploader
              .downloadDistributedFile(widget.fileIdRef!, widget.sizeMb);
          setState(() {
            _fileBytes = bytes;
          });
          if (_isCodeFile || _isMarkdown) {
            _textContent = utf8.decode(bytes);
            _codeController.text = _textContent!;
          }
          if (_isAudio) await _initAudio(null, null, bytes);
        }
      } else {
        // Standard / Legacy
        final url = await widget.uploader.getTemporaryLink(widget.dropboxPath);
        setState(() {
          _downloadUrl = url;
        });

        if (_isVideo) {
          await _initVideoPlayer(url);
        } else if (_isAudio) {
          await _initAudio(url, null, null);
        } else if (_isCodeFile || _isMarkdown) {
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

  bool get _isAudio {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'].contains(ext);
  }

  bool get _isPdf {
    return widget.fileName.toLowerCase().endsWith('.pdf');
  }

  bool get _isMarkdown {
    final ext = widget.fileName.split('.').last.toLowerCase();
    return ext == 'md' || ext == 'markdown';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KeeprTheme.background,
      appBar: AppBar(
        title: Text(widget.fileName, style: GoogleFonts.inter(fontSize: 16)),
        backgroundColor: KeeprTheme.surface,
        actions: [
          if ((_isCodeFile || _isMarkdown) && !_loading)
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
          if (_downloadUrl != null && kIsWeb)
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
    if (_downloadUrl == null && _fileBytes == null && _localFilePath == null) {
      return Center(
          child: Text("Could not load file.",
              style: GoogleFonts.inter(color: Colors.white54)));
    }

    if (_isImage) {
      return Center(
        child: InteractiveViewer(
          child: _localFilePath != null
              ? Image.file(File(_localFilePath!),
                  errorBuilder: (ctx, err, stack) =>
                      Icon(Icons.broken_image, size: 64, color: Colors.white24))
              : (_fileBytes != null
                  ? Image.memory(
                      Uint8List.fromList(_fileBytes!),
                      errorBuilder: (ctx, err, stack) => Icon(
                          Icons.broken_image,
                          size: 64,
                          color: Colors.white24),
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
                      errorBuilder: (ctx, err, stack) => Icon(
                          Icons.broken_image,
                          size: 64,
                          color: Colors.white24),
                    )),
        ),
      );
    }

    // Code file uses _textContent which is already set
    if (_isCodeFile) {
      return Container(
        color: Colors.black.withAlpha((0.3 * 255).round()),
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _codeController,
          maxLines: null,
          expands: true,
          style: GoogleFonts.firaCode(
              color: const Color(0xFFa9b7c6), fontSize: 14, height: 1.5),
          decoration: InputDecoration(border: InputBorder.none),
        ),
      );
    }

    if (_isMarkdown) {
      return Container(
        color: KeeprTheme.background,
        child: Markdown(
          data: _textContent ?? '',
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            p: GoogleFonts.inter(color: Colors.white.withAlpha((0.9 * 255).round()), fontSize: 16),
            h1: GoogleFonts.inter(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
            h2: GoogleFonts.inter(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            h3: GoogleFonts.inter(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            code: GoogleFonts.firaCode(backgroundColor: Colors.white.withAlpha((0.1 * 255).round()), color: const Color(0xFFa9b7c6)),
            codeblockPadding: const EdgeInsets.all(16),
            codeblockDecoration: BoxDecoration(
              color: Colors.black.withAlpha((0.5 * 255).round()),
              borderRadius: BorderRadius.circular(8),
            ),
            blockquote: GoogleFonts.inter(color: Colors.white54, fontStyle: FontStyle.italic),
            blockquoteDecoration: BoxDecoration(
              border: Border(left: BorderSide(color: Colors.white24, width: 4)),
            ),
          ),
        ),
      );
    }

    if (_isPdf) {
      if (_downloadUrl != null) {
        return SfPdfViewer.network(_downloadUrl!);
      } else if (_localFilePath != null && !kIsWeb) {
        return SfPdfViewer.file(File(_localFilePath!));
      } else if (_fileBytes != null) {
        return SfPdfViewer.memory(Uint8List.fromList(_fileBytes!));
      }
      return const Center(child: CircularProgressIndicator());
    }

    if (_isAudio) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(32),
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: KeeprTheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withAlpha((0.1 * 255).round())),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha((0.2 * 255).round()),
                blurRadius: 20,
                offset: const Offset(0, 10),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: KeeprTheme.primary.withAlpha((0.2 * 255).round()),
                ),
                child: Icon(Icons.music_note_rounded, size: 80, color: KeeprTheme.primary),
              ),
              const SizedBox(height: 32),
              Text(
                widget.fileName,
                style: GoogleFonts.inter(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 32),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: KeeprTheme.primary,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  trackHeight: 4.0,
                ),
                child: Slider(
                  value: _audioPosition.inSeconds.toDouble().clamp(0.0, _audioDuration.inSeconds.toDouble()),
                  max: _audioDuration.inSeconds.toDouble() > 0 ? _audioDuration.inSeconds.toDouble() : 1.0,
                  onChanged: (val) {
                    _audioPlayer?.seek(Duration(seconds: val.toInt()));
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_formatDuration(_audioPosition), style: GoogleFonts.firaCode(color: Colors.white54, fontSize: 12)),
                    Text(_formatDuration(_audioDuration), style: GoogleFonts.firaCode(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 32,
                    icon: const Icon(Icons.replay_10, color: Colors.white70),
                    onPressed: () {
                      final newPos = _audioPosition - const Duration(seconds: 10);
                      _audioPlayer?.seek(newPos.isNegative ? Duration.zero : newPos);
                    },
                  ),
                  const SizedBox(width: 24),
                  InkWell(
                    onTap: () {
                      if (_isPlayingAudio) {
                        _audioPlayer?.pause();
                      } else {
                        _audioPlayer?.resume();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: KeeprTheme.primary,
                      ),
                      child: Icon(
                        _isPlayingAudio ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    iconSize: 32,
                    icon: const Icon(Icons.forward_10, color: Colors.white70),
                    onPressed: () {
                      final newPos = _audioPosition + const Duration(seconds: 10);
                      _audioPlayer?.seek(newPos > _audioDuration ? _audioDuration : newPos);
                    },
                  ),
                ],
              )
            ],
          ),
        ),
      );
    }

    // Fallback for Video/Other
    if (_isVideo) {
      if (_chewieController != null && _videoPlayerController != null && _videoPlayerController!.value.isInitialized) {
        return Center(
          child: Chewie(
            controller: _chewieController!,
          ),
        );
      } else {
        return const Center(child: CircularProgressIndicator());
      }
    }

    IconData icon = Icons.insert_drive_file;
    String actionLabel = "OPEN FILE";

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 80, color: Colors.white24),
          const SizedBox(height: 20),
          Text("Preview not supported natively.",
              style: GoogleFonts.inter(color: Colors.white54)),
          const SizedBox(height: 20),
          if (kIsWeb && _downloadUrl != null)
            ElevatedButton.icon(
              onPressed: () async {
                await launchUrl(Uri.parse(_downloadUrl!));
              },
              icon: Icon(Icons.open_in_new),
              label: Text("Download"),
              style: ElevatedButton.styleFrom(
                  backgroundColor:
                      KeeprTheme.primary.withAlpha((0.8 * 255).round()),
                  foregroundColor: Colors.white),
            )
          else
            Text(
              "Preview and native file opening not supported for this file type.",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: Colors.white38),
            )
        ],
      ),
    );
  }
}
