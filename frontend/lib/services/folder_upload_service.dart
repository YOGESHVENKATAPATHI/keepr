import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;

class FolderUploadService {
  final String backendUrl;

  FolderUploadService({required this.backendUrl});

  // Web-compatible upload for PlatformFiles (from file_picker)
  Future<void> uploadWebFiles(
      List<PlatformFile> files, String userId, String parentPath,
      {Function(String, double)? onFileProgress}) async {
    try {
      for (var file in files) {
        // Construct path: parentPath + / + filename
        final safeParent = parentPath.endsWith('/') && parentPath.length > 1
            ? parentPath.substring(0, parentPath.length - 1)
            : parentPath;
        // if parent is just '/', we want '/filename'. if parent is '/foo', we want '/foo/filename'

        String logicalPath;
        if (safeParent == '/') {
          logicalPath = "/${file.name}";
        } else {
          logicalPath = "$safeParent/${file.name}";
        }
        
        final sizeMb = file.size / (1024 * 1024);

        // Fetch token specifically for this file size
        String dropboxToken = await _getBestStorageToken(sizeMb: sizeMb);

        // Dropbox path
        String dropboxPath = logicalPath;
        await _uploadPlatformFile(file, dropboxPath, dropboxToken,
            onProgress: (sent, total) {
          if (onFileProgress != null) {
            double p = sent / total;
            onFileProgress(file.name, p);
          }
        });

        // Save metadata to backend
        await _saveFileMetadata(
            userId, logicalPath, file.name, sizeMb, dropboxPath);
      }
    } catch (e) {
      print("Error uploading web files: $e");
      rethrow;
    }
  }

  // Helper to upload simple text content (for code editor)
  Future<void> uploadStringContent(
      String content, String userId, String logicalPath) async {
    try {
      // Convert string to bytes
      List<int> bytes = utf8.encode(content);
      final sizeMb = bytes.length / (1024 * 1024);

      String dropboxToken = await _getBestStorageToken(sizeMb: sizeMb);
      String dropboxPath =
          logicalPath; // Assuming logical mapping 1:1 for simplicity or reusing existing logic

      // Upload to Dropbox (overwrite mode = add + autorename=false? No, mode=overwrite)
      var url = Uri.parse('https://content.dropboxapi.com/2/files/upload');
      var headers = {
        'Authorization': 'Bearer $dropboxToken',
        'Dropbox-API-Arg': jsonEncode({
          "path": dropboxPath,
          "mode": "overwrite",
          "autorename": false,
          "mute": false
        }),
        'Content-Type': 'application/octet-stream',
      };

      var request = http.StreamedRequest("POST", url);
      request.headers.addAll(headers);
      request.contentLength = bytes.length;
      request.sink.add(bytes);
      request.sink.close();

      final resp = await request.send();
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        throw Exception("Dropbox upload failed: $body");
      }

      // Update metadata (size might change)
      await _saveFileMetadata(
          userId, logicalPath, p.basename(logicalPath), sizeMb, dropboxPath);
    } catch (e) {
      rethrow;
    }
  }

  Future<String> getTemporaryLink(String dropboxPath) async {
    final token = await _getBestStorageToken();
    final url =
        Uri.parse('https://api.dropboxapi.com/2/files/get_temporary_link');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({"path": dropboxPath}));

    if (resp.statusCode == 200) {
      return jsonDecode(resp.body)['link'];
    } else {
      throw Exception('Failed to get download link: ${resp.body}');
    }
  }

  // Returns a direct backend URL to download the folder as zip
  String getFolderDownloadUrl(String path, String userId) {
    final encodedPath = Uri.encodeQueryComponent(path);
    final encodedUser = Uri.encodeQueryComponent(userId);
    return "$backendUrl/api/files/download-zip?path=$encodedPath&user_id=$encodedUser";
  }

  Future<void> _uploadPlatformFile(PlatformFile file, String path, String token,
      {Function(int, int)? onProgress}) async {
    // Switch to Dio to get XHR upload progress events (essential for Web & accurate KB updates)
    final dio = Dio();
    final url = 'https://content.dropboxapi.com/2/files/upload';

    final headers = {
      'Authorization': 'Bearer $token',
      'Dropbox-API-Arg': jsonEncode(
          {"path": path, "mode": "add", "autorename": true, "mute": false}),
      'Content-Type': 'application/octet-stream',
    };

    dynamic data;
    if (file.bytes != null) {
      // Memory files (small or web)
      data = Stream.fromIterable(file.bytes!
          .map((b) => [b])); // Terribly inefficient to map byte by byte?
      // No... Dio accepts Stream<List<int>>.
      // If we have List<int> bytes, we can just pass the list or a stream of list.
      // Passing List<int> directly is best for Dio.
      data = file.bytes;
    } else if (file.readStream != null) {
      // Stream files (large/desktop)
      data = file.readStream;
    } else {
      throw Exception("No file data available for upload");
    }

    // Dio Options
    final options = Options(
      headers: headers,
      contentType: 'application/octet-stream',
      // Ensure we don't timeout too fast on large uploads
      sendTimeout: const Duration(minutes: 30),
    );

    try {
      await dio.post(
        url,
        data: data,
        options: options,
        onSendProgress: (sent, total) {
          // total might be -1 if chunked, but we know file.size
          if (onProgress != null) {
            onProgress(sent, total > 0 ? total : file.size);
          }
        },
      );
      print("Uploaded web file via Dio: $path");
    } catch (e) {
      if (e is DioException) {
        throw Exception("Upload failed: ${e.response?.data ?? e.message}");
      }
      throw Exception("Upload failed: $e");
    }
  }

  /// 1. Recursive File Walker
  /// Returns a list of File entities found in the directory and subdirectories.
  Future<List<File>> getFilesRecursive(Directory dir) async {
    var files = <File>[];
    var completer = Completer<List<File>>();
    var lister = dir.list(recursive: true);

    lister.listen(
      (file) {
        if (file is File) {
          files.add(file);
        }
      },
      onDone: () => completer.complete(files),
      onError: (e) => completer.completeError(e),
    );

    return completer.future;
  }

  /// 2. Upload Logic
  /// Orchestrates the upload of a folder.
  Future<void> uploadFolder(String folderPath, String userId) async {
    Directory dir = Directory(folderPath);
    if (!await dir.exists()) {
      throw Exception("Directory not found");
    }

    try {
      // Step A: Get all files
      List<File> allFiles = await getFilesRecursive(dir);
      print("Found ${allFiles.length} files to upload.");

      // Step B: Upload files (Check storage for EACH file to ensure it fits "live")
      for (var file in allFiles) {
        // Calculate relative path to preserve structure: e.g. "subfolder/file.txt"
        String relativePath = p.relative(file.path, from: dir.path);
        // Correctslashes for Dropbox (forward slash)
        String dropboxPath = "/$relativePath".replaceAll(r'\', '/');
        
        final sizeMb = (await file.length()) / (1024 * 1024);
        
        // Dynamic Token Allocation per file
        String dropboxToken = await _getBestStorageToken(sizeMb: sizeMb);

        await _uploadFile(file, dropboxPath, dropboxToken);

        // Save metadata
        await _saveFileMetadata(userId, "/$relativePath", p.basename(file.path),
            sizeMb, dropboxPath);
      }

      print("Folder upload complete.");
    } catch (e) {
      print("Error uploading folder: $e");
      rethrow;
    }
  }

  Future<void> _saveFileMetadata(String userId, String appPath, String name,
      double sizeMb, String dropboxPath) async {
    final url = Uri.parse('$backendUrl/api/files/upload-metadata');
    final resp = await http.post(url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          'path': appPath, // logical path in app
          'name': name,
          'size_mb': sizeMb,
          'dropbox_path': dropboxPath
        }));
    if (resp.statusCode != 200) {
      print("Failed to save metadata: ${resp.body}");
      // Optional: don't fail the whole upload if metadata fails, or do?
      // throwing here ensures consistency
      throw Exception("Metadata save failed: ${resp.body}");
    }
  }

  Future<String> _getBestStorageToken({double sizeMb = 0}) async {
    // Call your backend to get the best access token
    // Passing size_mb ensures the selected account has enough space
    final url = Uri.parse('$backendUrl/api/storage/best-account')
        .replace(queryParameters: {'size_mb': sizeMb.toString()});

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['access_token'];
    } else {
      throw Exception('Failed to get eligible storage account: ${response.body}');
    }
  }

  /// 3. Chunked Upload Implementation
  /// Dropbox allows files < 150MB in one go. Larger files need sessions.
  /// This implements a simplified logic for "Large Files".
  Future<void> _uploadFile(
      File file, String dropboxPath, String accessToken) async {
    int len = await file.length();

    // Threshold: 140MB (safe margin below 150MB)
    const int CHUNK_SIZE = 140 * 1024 * 1024;

    if (len < CHUNK_SIZE) {
      // Simple Upload
      await _uploadSingleStep(file, dropboxPath, accessToken);
    } else {
      // Session Upload (Chunked)
      await _uploadSession(file, dropboxPath, accessToken, CHUNK_SIZE, len);
    }
  }

  Future<void> _uploadSingleStep(File file, String path, String token) async {
    var url = Uri.parse('https://content.dropboxapi.com/2/files/upload');
    var headers = {
      'Authorization': 'Bearer $token',
      'Dropbox-API-Arg': jsonEncode(
          {"path": path, "mode": "add", "autorename": true, "mute": false}),
      'Content-Type': 'application/octet-stream',
    };

    // Stream upload for memory efficiency
    var stream = http.ByteStream(file.openRead());
    var request = http.StreamedRequest("POST", url);
    request.headers.addAll(headers);
    request.contentLength = await file.length();

    // Pipe stream to request
    stream.listen((value) {
      request.sink.add(value);
    }, onDone: () {
      request.sink.close();
    });

    var response = await request.send();
    if (response.statusCode != 200) {
      // read response
      var respStr = await response.stream.bytesToString();
      throw Exception("Upload failed: $respStr");
    }
    print("Uploaded: $path");
  }

  // Simplified Session Upload Logic
  Future<void> _uploadSession(File file, String path, String token,
      int chunkSize, int totalSize) async {
    // 1. Start Session
    var startUrl = Uri.parse(
        'https://content.dropboxapi.com/2/files/upload_session/start');
    var startHeaders = {
      'Authorization': 'Bearer $token',
      'Dropbox-API-Arg': jsonEncode({"close": false}),
      'Content-Type': 'application/octet-stream',
    };

    var startRes = await http.post(startUrl,
        headers: startHeaders); // Send empty body just to start
    if (startRes.statusCode != 200) throw Exception("Failed to start session");
    var sessionId = jsonDecode(startRes.body)['session_id'];

    // 2. Append Chunks
    RandomAccessFile raf = await file.open();
    int offset = 0;

    while (offset < totalSize) {
      // Read chunk
      // Note: In real Dart stream processing, this needs careful memory mgmt.
      // This is conceptual logic for the requested feature.

      bool isLastChunk = (offset + chunkSize) >= totalSize;

      if (isLastChunk) {
        // 3. Finish Session
        var finishUrl = Uri.parse(
            'https://content.dropboxapi.com/2/files/upload_session/finish');
        var finishHeaders = {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': jsonEncode({
            "cursor": {"session_id": sessionId, "offset": offset},
            "commit": {
              "path": path,
              "mode": "add",
              "autorename": true,
              "mute": false
            }
          }),
          'Content-Type': 'application/octet-stream',
        };
        // Send remaining bytes
        var remaining = totalSize - offset;
        var bytes = await raf.read(remaining);
        var finishRes =
            await http.post(finishUrl, headers: finishHeaders, body: bytes);
        if (finishRes.statusCode != 200)
          throw Exception("Failed to finish session");
        break;
      } else {
        // Append
        var appendUrl = Uri.parse(
            'https://content.dropboxapi.com/2/files/upload_session/append_v2');
        var appendHeaders = {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': jsonEncode({
            "cursor": {"session_id": sessionId, "offset": offset},
            "close": false
          }),
          'Content-Type': 'application/octet-stream',
        };

        var bytes = await raf.read(chunkSize);
        var appendRes =
            await http.post(appendUrl, headers: appendHeaders, body: bytes);
        if (appendRes.statusCode != 200)
          throw Exception("Failed to append chunk");

        offset += chunkSize;
      }
    }

    await raf.close();
    print("Large file uploaded: $path");
  }
}
