import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;

class FolderUploadService {
  final String backendUrl;

  FolderUploadService({required this.backendUrl});

  // Chunk size for parallel uploads (e.g., 4MB)
  static const int CHUNK_SIZE_BYTES = 4 * 1024 * 1024;

  // Unified Distributed Upload Logic
  Future<void> uploadDistributedFile({
    required String name,
    required String logicalPath,
    required int size,
    required String userId,
    required Future<List<int>> Function(int start, int end) chunkReader,
    Function(String, double)? onProgress,
  }) async {
    final sizeMb = size / (1024 * 1024);

    // 1. Init Upload
    final initUrl = Uri.parse('$backendUrl/api/files/init-upload');
    final initResp = await http.post(initUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          'path': logicalPath,
          'name': name,
          'size_mb': sizeMb,
          'is_folder': false 
        }));
    if (initResp.statusCode != 200) throw Exception("Init failed: ${initResp.body}");
    final fileId = jsonDecode(initResp.body)['fileId'];

    // 2. Allocate Chunks
    final totalChunks = (size / CHUNK_SIZE_BYTES).ceil();
    final effectiveChunks = totalChunks > 0 ? totalChunks : 1; 
    
    final allocUrl = Uri.parse('$backendUrl/api/files/allocate-chunks');
    final allocResp = await http.post(allocUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fileId': fileId,
          'totalChunks': effectiveChunks,
          'fileSizeMb': sizeMb
        }));
    if (allocResp.statusCode != 200) throw Exception("Allocation failed: ${allocResp.body}");
    
    final allocations = jsonDecode(allocResp.body)['allocations'] as List;

    // 3. Parallel Upload
    int chunksCompleted = 0;
    
    Future<void> processChunk(dynamic alloc) async {
         final chunkIndex = alloc['chunkIndex'] as int;
         final start = chunkIndex * CHUNK_SIZE_BYTES;
         final end = (start + CHUNK_SIZE_BYTES) < size ? (start + CHUNK_SIZE_BYTES) : size;
         
         List<int> chunkBytes = [];
         if(size > 0) {
            chunkBytes = await chunkReader(start, end);
         }

         final dio = Dio();
         final url = 'https://content.dropboxapi.com/2/files/upload';
         
         await dio.post(
            url,
            data: chunkBytes, 
            options: Options(
                headers: {
                  'Authorization': 'Bearer ${alloc['accessToken']}',
                  'Dropbox-API-Arg': jsonEncode({
                      "path": alloc['dropboxPath'],
                      "mode": "overwrite", 
                      "autorename": false,
                      "mute": true
                  }),
                  'Content-Type': 'application/octet-stream'
                },
                sendTimeout: const Duration(minutes: 10)
            )
         );

         chunksCompleted++;
         if (onProgress != null) {
            onProgress(name, chunksCompleted / effectiveChunks);
         }
    }

    // Run in batches to avoid connection limits
    const parallelism = 5;
    for (var i = 0; i < allocations.length; i += parallelism) {
        final batch = allocations.sublist(
            i, 
            (i + parallelism) < allocations.length ? (i + parallelism) : allocations.length
        );
        await Future.wait(batch.map((a) => processChunk(a)));
    }

    // 4. Finalize
    final finUrl = Uri.parse('$backendUrl/api/files/finalize-upload');
    final finResp = await http.post(finUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fileId': fileId}));
        
    if (finResp.statusCode != 200) {
         // Even if finalize fails, chunks might be up. Logic can be improved.
         throw Exception("Finalize failed: ${finResp.body}");
    }
  }

  // Upload String Content (Editor Save)
  Future<void> uploadStringContent(String content, String userId, String logicalPath) async {
    final bytes = utf8.encode(content);
    final name = logicalPath.split('/').last;
    
    await uploadDistributedFile(
      name: name,
      logicalPath: logicalPath,
      size: bytes.length,
      userId: userId,
      chunkReader: (start, end) async {
         return bytes.sublist(start, end);
      }
    );
  }

  // Web/Desktop File Picker Upload
  Future<void> uploadWebFiles(
      List<PlatformFile> files, String userId, String parentPath,
      {Function(String, double)? onFileProgress}) async {
    try {
      for (var file in files) {
        final safeParent = parentPath.endsWith('/') && parentPath.length > 1
            ? parentPath.substring(0, parentPath.length - 1)
            : parentPath;

        String logicalPath;
        if (safeParent == '/') {
          logicalPath = "/${file.name}";
        } else {
          logicalPath = "$safeParent/${file.name}";
        }

        await uploadDistributedFile(
            name: file.name,
            logicalPath: logicalPath,
            size: file.size,
            userId: userId,
            onProgress: onFileProgress,
            chunkReader: (start, end) async {
                if (file.bytes != null) {
                    return file.bytes!.sublist(start, end);
                }
                if (file.path != null) {
                    // Fallback for Desktop if bytes not loaded
                    final f = File(file.path!);
                    final raf = await f.open();
                    try {
                        await raf.setPosition(start);
                        return await raf.read(end - start);
                    } finally {
                        await raf.close();
                    }
                }
                throw Exception("Cannot read file data: No bytes and no path (Stream not supported here)");
            }
        );
      }
    } catch (e) {
      print("Error uploading files: $e");
      rethrow;
    }
  }

  /// Recursive File Walker
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

  /// Upload Folder Logic (Now Distributed)
  Future<void> uploadFolder(String folderPath, String userId) async {
    Directory dir = Directory(folderPath);
    if (!await dir.exists()) {
      throw Exception("Directory not found");
    }

    try {
      List<File> allFiles = await getFilesRecursive(dir);
      print("Found ${allFiles.length} files to upload.");

      for (var file in allFiles) {
        // Calculate relative path to preserve structure
        String relativePath = p.relative(file.path, from: dir.path);
        // Correct slashes
        String logicalPath = "/${relativePath.replaceAll(r'\', '/')}";
        
        final size = await file.length();

        await uploadDistributedFile(
            name: p.basename(file.path),
            logicalPath: logicalPath,
            size: size,
            userId: userId,
            onProgress: (n, p) => print("Uploading $n: ${(p * 100).toInt()}%"),
            chunkReader: (start, end) async {
                 final raf = await file.open();
                 try {
                     await raf.setPosition(start);
                     return await raf.read(end - start);
                 } finally {
                     await raf.close();
                 }
            }
        );
      }
      print("Folder upload complete.");
    } catch (e) {
      print("Error uploading folder: $e");
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

  // Necessary for getTemporaryLink (Legacy downloads)
  Future<String> _getBestStorageToken({double sizeMb = 0}) async {
    final url = Uri.parse('$backendUrl/api/storage/best-account')
        .replace(queryParameters: {'size_mb': sizeMb.toString()});

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['access_token'];
    } else {
      throw Exception(
          'Failed to get eligible storage account: ${response.body}');
    }
  }

  // Download Distributed File (Reassemble)
  Future<void> downloadDistributedFile(String fileId, String fileName) async {
      try {
          final url = Uri.parse('$backendUrl/api/files/download-info/$fileId');
          final resp = await http.get(url);
          if(resp.statusCode != 200) throw Exception("Failed to get download info: ${resp.body}");
          
          final data = jsonDecode(resp.body);
          if(!data['ok']) throw Exception(data['error']);
          
          final chunks = data['chunks'] as List;
          chunks.sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
          
          List<Uint8List?> downloadedParts = List.filled(chunks.length, null);
          
          Future<void> fetchChunk(int index, String url) async {
             final r = await http.get(Uri.parse(url));
             if(r.statusCode == 200) {
                 downloadedParts[index] = r.bodyBytes;
             } else {
                 throw Exception("Failed to download chunk $index");
             }
          }
          
          int parallelism = 5; 
          for(int i=0; i<chunks.length; i+=parallelism) {
              final end = (i+parallelism < chunks.length) ? i+parallelism : chunks.length;
              await Future.wait(
                  chunks.sublist(i, end).map((c) => fetchChunk(c['index'], c['url']))
              );
          }
          
          final totalBytes = downloadedParts.fold<int>(0, (sum, part) => sum + (part?.length ?? 0));
          final merged = Uint8List(totalBytes);
          int offset = 0;
          for(var part in downloadedParts) {
              if(part != null) {
                  merged.setAll(offset, part);
                  offset += part.length;
              }
          }
          print("Reassembled ${merged.length} bytes for $fileName");
          // NOTE: In a real app we would save this to a file or trigger download
      } catch(e) {
          print("Download failed: $e");
          rethrow;
      }
  }
}
