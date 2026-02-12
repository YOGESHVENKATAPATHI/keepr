import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
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

        String logicalPath;
        if (safeParent == '/') {
          logicalPath = "/${file.name}";
        } else {
          logicalPath = "$safeParent/${file.name}";
        }

        // Use Distributed Upload Logic
        await _uploadFileDistributed(file, userId, logicalPath,
            onProgress: (p) => onFileProgress?.call(file.name, p));
      }
    } catch (e) {
      print("Error uploading web files: $e");
      rethrow;
    }
  }

  // --- Distributed Upload Logic ---

  Future<void> _uploadFileDistributed(
      PlatformFile file, String userId, String logicalPath,
      {Function(double)? onProgress}) async {
    final int chunkSize = 4 * 1024 * 1024; // 4MB
    final int totalSize = file.size;
    final int totalChunks = (totalSize / chunkSize).ceil();
    final String fileName = file.name;
    final double totalSizeMb = totalSize / (1024 * 1024);

    // 1. Init Upload (with retries)
    int maxInitAttempts = 3;
    http.Response initResp;
    int initAttempt = 0;
    while (true) {
      initAttempt++;
      try {
        initResp = await http.post(Uri.parse('$backendUrl/api/upload/init'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'user_id': userId,
              'path': logicalPath,
              'name': fileName,
              'total_size_mb': totalSizeMb,
              'total_chunks': totalChunks
            }));

        if (initResp.statusCode == 200) break;

        print(
            '[Upload][WARN] init attempt $initAttempt failed: ${initResp.statusCode} ${initResp.body}');
        if (initAttempt >= maxInitAttempts)
          throw Exception("Init upload failed: ${initResp.body}");
      } catch (e) {
        print('[Upload][ERROR] init attempt $initAttempt error: $e');
        if (initAttempt >= maxInitAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * initAttempt));
      }
    }

    final fileId = jsonDecode(initResp.body)['fileId'];
    print(
        "Initialized upload for $fileName (ID: $fileId) with $totalChunks chunks");

    // 2. Prepare chunks
    List<Map<String, dynamic>> completedChunks = [];
    int bytesUploaded = 0;

    // Handle both Web (bytes/stream) and Mobile/Desktop (path)
    final bytes = file.bytes;
    final stream = file.readStream; // Available if withReadStream: true
    // RandomAccessFile? raf; // Removed to avoid shared pointer concurrency issues

    if (bytes == null && stream == null) {
      if (file.path == null) {
        throw Exception("File data not available (no bytes, path, or stream).");
      }
    }

    try {
      // Semaphore for concurrency (limit 4 parallel uploads)
      final int concurrency = 4;

      // Processing using a pool with per-chunk progress reporting
      int activeUploads = 0;
      int chunkIndex = 0;
      Completer<void> doneCompleter = Completer<void>();
      List<dynamic> fatalErrors = [];

      // Throttling helpers
      int lastEmitMs = DateTime.now().millisecondsSinceEpoch;
      int lastEmittedBytes = 0;
      void emitProgressIfNeeded() {
        if (onProgress == null) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (bytesUploaded - lastEmittedBytes >= 1024 * 64 || // 64KB
            now - lastEmitMs >= 500 ||
            bytesUploaded >= totalSize) {
          lastEmitMs = now;
          lastEmittedBytes = bytesUploaded;
          onProgress(bytesUploaded / totalSize);
        }
      }

      // STREAM MODE (Sequential Read, Parallel Upload)
      if (stream != null && bytes == null) {
        await _uploadStreamByChunksCorrect(
            stream, chunkSize, totalChunks, fileId, concurrency,
            // Progress
            (uploaded) {
          bytesUploaded = uploaded;
          emitProgressIfNeeded();
        },
            // Chunk Completion
            (result) => completedChunks.add(result));

        // Final progress
        if (onProgress != null) onProgress(1.0);
      } else {
        // RANDOM ACCESS MODE (Bytes or RAF)

        void startNext() async {
          if (fatalErrors.isNotEmpty) return;
          if (chunkIndex >= totalChunks) {
            if (activeUploads == 0 && !doneCompleter.isCompleted)
              doneCompleter.complete();
            return;
          }

          final i = chunkIndex++;
          activeUploads++;

          try {
            // Prepare chunk data
            final start = i * chunkSize;
            final end =
                (start + chunkSize < totalSize) ? start + chunkSize : totalSize;
            List<int> chunkData;

            if (bytes != null) {
              chunkData = bytes.sublist(start, end);
            } else {
              // Read from file safely (new handle per chunk to allow concurrency)
              final localRaf = await File(file.path!).open(mode: FileMode.read);
              try {
                await localRaf.setPosition(start);
                chunkData = await localRaf.read(end - start);
              } finally {
                await localRaf.close();
              }
            }

            // Keep track of the last sent bytes for this chunk to compute deltas
            int prevSentForChunk = 0;

            await _processChunk(
                fileId: fileId,
                chunkIndex: i,
                chunkData: chunkData,
                onChunkProgress: (sent, total) {
                  // sent is bytes sent for this chunk
                  final int delta = sent - prevSentForChunk;
                  if (delta > 0) {
                    prevSentForChunk = sent;
                    bytesUploaded += delta;
                    emitProgressIfNeeded();
                  }
                },
                onChunkComplete: (result) {
                  completedChunks.add(result);
                  // If some bytes weren't accounted for via progress callbacks (edge cases), add remainder
                  final int chunkSizeBytes = result['size'] as int;
                  final int remainder = chunkSizeBytes - prevSentForChunk;
                  if (remainder > 0) {
                    bytesUploaded += remainder;
                  }
                  emitProgressIfNeeded();
                });
          } catch (e) {
            print("Chunk $i failed: $e");
            fatalErrors.add(e);
            if (!doneCompleter.isCompleted) doneCompleter.completeError(e);
          } finally {
            activeUploads--;
            startNext();
          }
        }

        // Start initial batch
        for (int k = 0; k < concurrency; k++) startNext();

        await doneCompleter.future;
      }
    } finally {
      // raf closed automatically if used locally
    }

    // 3. Finalize
    print(
        "Finalizing upload for $fileId... total chunks=${completedChunks.length}");
    print('[Upload][DEBUG] chunks metadata: ${completedChunks.map((c) => {
          'index': c['index'],
          'chunkId': c['chunkId'],
          'size': c['size'],
          'path': c['path']
        }).toList()}');

    final finalizeResp = await http.post(
        Uri.parse('$backendUrl/api/upload/finalize'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fileId': fileId, 'chunks': completedChunks}));
    if (finalizeResp.statusCode != 200)
      throw Exception("Finalize failed: ${finalizeResp.body}");

    // Ensure we emit a final 100% progress update
    if (onProgress != null) onProgress(1.0);
  }

  Future<void> _uploadStreamByChunks(
      Stream<List<int>> stream,
      int chunkSize,
      int totalChunksEstimate,
      String fileId,
      int concurrency,
      Function(int) onBytesUploaded,
      Function(Map<String, dynamic>) onChunkCompleted) async {
    int currentChunkIndex = 0;
    int currentBufferLen = 0;
    List<int> buffer = [];

    // Active uploads
    List<Future> active = [];

    await for (final packet in stream) {
      buffer.addAll(packet);
      currentBufferLen += packet.length;

      // While we have enough to fill a chunk (or more)
      while (currentBufferLen >= chunkSize) {
        // Slice
        final chunkData = buffer.sublist(0, chunkSize);
        buffer = buffer.sublist(chunkSize);
        currentBufferLen -= chunkSize;

        final idx = currentChunkIndex++;

        // Wait if concurrency limit reached
        while (active.length >= concurrency) {
          await Future.any(active);
          active.removeWhere((f) => f.asStream().isBroadcast
              ? false
              : true); // Simple cleanup is hard, simpler:
          // Actually Future.any returns the completed one. But finding WHICH one is hard.
          // Easier: just await the first one if using a Queue, but we want any.
          // Correct approach: Maintain list, when full, await specific or race.
          // Simpler: Just await all if full? No, inhibits throughput.
          // We'll use a simple clean-up loop.
          await Future.delayed(Duration(milliseconds: 50));
          active.removeWhere(
              (f) => f.toString().contains("Completed") /* Hacky */);
          // Better: wrap future to self-remove
        }

        // Start upload
        final future =
            _processChunkWithRetry(fileId, idx, chunkData, onChunkCompleted);
        active.add(future);

        // Clean up finished
        active.removeWhere((f) => f
            .toString()
            .contains("Frequency") /* dummy */); // Need proper future tracking
        // Let's implement proper tracking below.
      }
    }

    // Leftover
    if (currentBufferLen > 0) {
      final idx = currentChunkIndex++;
      final chunkData = buffer;
      active.add(
          _processChunkWithRetry(fileId, idx, chunkData, onChunkCompleted));
    }

    await Future.wait(active);
  }

  // Wrapper simply to return Future that completes so we can track it
  Future<void> _processChunkWithRetry(String fileId, int index, List<int> data,
      Function(Map<String, dynamic>) onComplete) async {
    await _processChunk(
        fileId: fileId,
        chunkIndex: index,
        chunkData: data,
        onChunkComplete: onComplete,
        onChunkProgress:
            null // Stream mode complicates global progress if parallel. We update global bytes linearly.
        );
  }

  // Rewrite _uploadStreamByChunks with better concurrency control
  Future<void> _uploadStreamByChunksCorrect(
      Stream<List<int>> stream,
      int chunkSize,
      int totalChunksEstimate,
      String fileId,
      int concurrency,
      Function(int) onBytesUploaded,
      Function(Map<String, dynamic>) onChunkCompleted) async {
    int currentChunkIndex = 0;
    List<int> buffer = [];

    // Correct Progress Tracking:
    // Tracks bytes from fully completed chunks
    int totalBytesFromCompletedChunks = 0;
    // Tracks current progress of active chunks (ChunkIndex -> BytesSent)
    final Map<int, int> activeChunkProgress = {};

    void updateProgress() {
      int activeTotal = 0;
      for (var val in activeChunkProgress.values) {
        activeTotal += val;
      }
      onBytesUploaded(totalBytesFromCompletedChunks + activeTotal);
    }

    final active = <Future>[];

    // Helper to wait for slot
    Future<void> waitForSlot() async {
      if (active.length < concurrency) return;
      await Future.any(active);
    }

    // Helper to start a chunk upload
    void startChunk(int idx, List<int> data) {
      activeChunkProgress[idx] = 0; // Initialize

      final f = _processChunk(
        fileId: fileId,
        chunkIndex: idx,
        chunkData: data,
        onChunkComplete: onChunkCompleted,
        onChunkProgress: (sent, total) {
           activeChunkProgress[idx] = sent;
           updateProgress();
        }
      ).then((_) {
        // Completion
        activeChunkProgress.remove(idx);
        totalBytesFromCompletedChunks += data.length;
        updateProgress();
      });

      active.add(f);
      f.whenComplete(() => active.remove(f));
    }

    await for (final packet in stream) {
      buffer.addAll(packet);

      while (buffer.length >= chunkSize) {
        await waitForSlot();

        final chunkData = buffer.sublist(0, chunkSize);
        buffer.removeRange(0, chunkSize);

        startChunk(currentChunkIndex++, chunkData);
      }
    }

    if (buffer.isNotEmpty) {
      await waitForSlot();
      final chunkData = buffer;
      startChunk(currentChunkIndex++, chunkData);
    }

    await Future.wait(active);
  }

  Future<void> _processChunk(
      {required String fileId,
      required int chunkIndex,
      required List<int> chunkData,
      required Function(Map<String, dynamic>) onChunkComplete,
      Function(int sent, int total)? onChunkProgress}) async {
    final sizeMb = chunkData.length / (1024 * 1024);

    // A. Allocate
    // A. Allocate (with retry)
    int allocAttempts = 0;
    int maxAllocAttempts = 3;
    Map<String, dynamic> alloc;
    while (true) {
      allocAttempts++;
      try {
        final allocResp = await http.post(
            Uri.parse('$backendUrl/api/upload/allocate-chunk'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'fileId': fileId,
              'chunkIndex': chunkIndex,
              'sizeMb': sizeMb
            }));
        if (allocResp.statusCode == 200) {
          alloc = jsonDecode(allocResp.body);
          break;
        }
        print(
            '[Upload][WARN] alloc attempt $allocAttempts failed: ${allocResp.statusCode} ${allocResp.body}');
        if (allocAttempts >= maxAllocAttempts)
          throw Exception('Alloc chunk failed: ${allocResp.body}');
      } catch (e) {
        print('[Upload][ERROR] alloc attempt $allocAttempts error: $e');
        if (allocAttempts >= maxAllocAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 400 * allocAttempts));
      }
    }

    // Normalize token keys and validate presence
    String? allocToken = alloc['accessToken'] ??
        alloc['access_token'] ??
        alloc['token'] ??
        alloc['accessTokenString'];
    if (allocToken == null || allocToken.isEmpty) {
      print(
          '[Upload][ERROR] allocate-chunk response missing access token: $alloc');
      throw Exception('Allocate response missing access token');
    }

    // Also normalize shard id and uploadPath for defensive use
    final shardId =
        alloc['shardId'] ?? alloc['shard_id'] ?? alloc['shard'] ?? 0;
    final uploadPath =
        alloc['uploadPath'] ?? alloc['upload_path'] ?? alloc['path'];
    if (uploadPath == null) {
      print(
          '[Upload][ERROR] allocate-chunk response missing uploadPath: $alloc');
      throw Exception('Allocate response missing uploadPath');
    }

    // B. Upload to Dropbox (with retry and platform differences)
    int uploadAttempts = 0;
    int maxUploadAttempts = 3;
    while (true) {
      uploadAttempts++;
      try {
        if (kIsWeb) {
          // Browser fetch path using Dio for progress events (XHR)
          final dio = Dio();
          dio.options.sendTimeout = const Duration(minutes: 5);

          await dio.post('https://content.dropboxapi.com/2/files/upload',
              data: chunkData, // Direct bytes for Web
              options: Options(headers: {
                'Authorization': 'Bearer $allocToken',
                'Dropbox-API-Arg': jsonEncode({
                  "path": uploadPath,
                  "mode": "overwrite",
                  "autorename": false,
                  "mute": true
                }),
                'Content-Type': 'application/octet-stream'
              }), onSendProgress: (sent, total) {
            if (onChunkProgress != null) {
              onChunkProgress(sent, total <= 0 ? chunkData.length : total);
            }
          });
          break;
        } else {
          final dio = Dio();
          // Increase timeouts for large chunk uploads (5 minutes)
          dio.options.sendTimeout = const Duration(minutes: 5);
          dio.options.receiveTimeout = const Duration(minutes: 5);

          // Using Stream.fromIterable([chunkData]) makes Dio emit only one progress event (0 -> 100%)
          // Passing List<int> directly prompts Dio to handle it as a buffer and emit granular writes.
          await dio.post('https://content.dropboxapi.com/2/files/upload',
              data: chunkData,
              options: Options(headers: {
                'Authorization': 'Bearer $allocToken',
                'Dropbox-API-Arg': jsonEncode({
                  "path": uploadPath,
                  "mode": "overwrite",
                  "autorename": false,
                  "mute": true
                }),
                'Content-Type': 'application/octet-stream'
              }), onSendProgress: (int sent, int total) {
            try {
              if (onChunkProgress != null)
                onChunkProgress(sent, total <= 0 ? chunkData.length : total);
            } catch (e) {
              print('[Upload] onChunkProgress handler error: $e');
            }
          });
          break;
        }
      } catch (e) {
        print('[Upload] upload attempt $uploadAttempts error: $e');
        // Friendly wrap for TLS handshake errors
        final errMsg = e?.toString() ?? '';
        if ((e is HandshakeException) ||
            errMsg.contains('HandshakeException') ||
            errMsg.contains('Connection terminated during handshake')) {
          throw Exception(
              'HandshakeException: Connection terminated during TLS handshake when uploading chunk $chunkIndex to ${alloc['uploadPath']}. Check your network, proxy, or storage TLS configuration. Original: $e');
        }
        if (uploadAttempts >= maxUploadAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * uploadAttempts));
        continue;
      }
    }

    // C. Report Success
    final chunkId =
        '${fileId}_${chunkIndex}_${DateTime.now().millisecondsSinceEpoch}';
    onChunkComplete({
      'index': chunkIndex,
      'chunkId': chunkId,
      'shardId': shardId,
      'path': uploadPath,
      'size': chunkData.length,
      'success': true
    });
  }

  // --- Distributed Download Logic ---
  Future<List<int>> downloadDistributedFile(
      String fileIdRef, double totalSizeMb,
      {Function(double)? onProgress}) async {
    // 1. Get Chunk Info
    final infoResp = await http.post(
        Uri.parse('$backendUrl/api/files/download-info'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fileIdRef': fileIdRef}));
    if (infoResp.statusCode != 200)
      throw Exception("Failed to get file info: ${infoResp.body}");

    final data = jsonDecode(infoResp.body);
    final chunks = (data['chunks'] as List).cast<Map<String, dynamic>>();

    print('[Download][DEBUG] raw chunks from server: ${chunks.map((c) => {
          'index': c['index'],
          'path': c['path'],
          'size_mb': c['size_mb']
        }).toList()}');

    // Detect duplicate indices returned by server
    final dupCounts = <int, int>{};
    for (var c in chunks) {
      final idx = c['index'] as int;
      dupCounts[idx] = (dupCounts[idx] ?? 0) + 1;
    }
    final duplicates = dupCounts.entries.where((e) => e.value > 1).toList();
    if (duplicates.isNotEmpty) {
      print(
          '[Download][WARN] duplicate chunk indices found from server: ${duplicates.map((e) => {
                'index': e.key,
                'count': e.value
              }).toList()}');
    }

    // Deduplicate chunks locally just in case backend sends duplicates
    final uniqueChunks = <int, Map<String, dynamic>>{};
    for (var c in chunks) {
      uniqueChunks[c['index']] = c;
    }
    final sortedUnique = uniqueChunks.values.toList()
      ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));

    // Determine max index to size the list correctly
    // If indices are 0,1,2,3 -> max is 3, size is 4.
    int maxIndex = -1;
    for (var c in sortedUnique) {
      int idx = c['index'];
      if (idx > maxIndex) maxIndex = idx;
    }

    // 2. Download Chunks (Parallel)
    // We retain parts as Uint8List to minimize conversion overhead
    final List<Uint8List?> parts = List.generate(maxIndex + 1, (_) => null);
    final client = http.Client();
    int totalBytesReceived = 0;

    // Prepare expected size vars before progress emitter so the emitter can reference them
    int expectedBytes = 0;
    // Try to compute sum of chunk sizes returned by server (size_mb) if available
    int sumChunkBytes = 0;
    bool haveChunkSizes = false;

    // Throttle download progress: at most once per second or per 1KB delta
    int lastDownloadEmitMs = DateTime.now().millisecondsSinceEpoch;
    int lastDownloadEmittedBytes = 0;
    void emitDownloadProgressIfNeeded() {
      if (onProgress == null || expectedBytes <= 0) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (totalBytesReceived - lastDownloadEmittedBytes >= 1024 ||
          now - lastDownloadEmitMs >= 1000 ||
          totalBytesReceived >= expectedBytes) {
        lastDownloadEmitMs = now;
        lastDownloadEmittedBytes = totalBytesReceived;
        double p = totalBytesReceived / expectedBytes;
        if (p > 1.0) p = 1.0;
        onProgress(p);
      }
    }

    for (var c in sortedUnique) {
      if (c.containsKey('size_mb') && c['size_mb'] != null) {
        // Server may return size_mb as number or string (e.g. "4"). Parse robustly.
        final raw = c['size_mb'];
        num sizeMbNum;
        if (raw is num) {
          sizeMbNum = raw;
        } else {
          sizeMbNum = num.tryParse(raw.toString()) ?? 0;
        }
        if (sizeMbNum > 0) {
          haveChunkSizes = true;
          sumChunkBytes += (sizeMbNum * 1024 * 1024).round();
        }
      }
    }

    if (haveChunkSizes) {
      expectedBytes = sumChunkBytes;
    } else if (data.containsKey('total_size_mb') &&
        data['total_size_mb'] != null) {
      expectedBytes = (data['total_size_mb'] * 1024 * 1024).round();
    } else {
      expectedBytes = (totalSizeMb * 1024 * 1024).round(); // approx fallback
    }

    print(
        '[Download] starting chunk downloads; chunks requested=${sortedUnique.length}, maxIndex=$maxIndex, expectedBytes=$expectedBytes');

    Future<void> fetchChunk(int index, String path, String token) async {
      print('[Download] fetching chunk index=$index path=$path');
      final url = 'https://content.dropboxapi.com/2/files/download';
      final headers = {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': jsonEncode({"path": path}),
      };

      int attempts = 0;
      int maxAttempts = 3;
      while (true) {
        attempts++;
        try {
          final request = http.Request('POST', Uri.parse(url));
          request.headers.addAll(headers);

          final streamedResponse =
              await client.send(request).timeout(Duration(seconds: 60));
          if (streamedResponse.statusCode != 200) {
            final body = await streamedResponse.stream.bytesToString();
            throw Exception(
                "Chunk download failed: ${streamedResponse.statusCode} ${streamedResponse.reasonPhrase} body=$body");
          }

          // Optimized: Collect into a BytesBuilder for efficient growth
          final builder = BytesBuilder(copy: false);
          await streamedResponse.stream.listen((data) {
            builder.add(data);
            totalBytesReceived += data.length;
            // Emit progress in a throttled manner
            emitDownloadProgressIfNeeded();
          }).asFuture();

          // Store as Uint8List
          parts[index] = builder.takeBytes();
          print(
              '[Download] chunk $index complete size=${parts[index]!.length}');
          break;
        } catch (e) {
          print('[Download] chunk $index attempt $attempts error: $e');
          final errMsg = e?.toString() ?? '';
          if ((e is HandshakeException) ||
              errMsg.contains('HandshakeException') ||
              errMsg.contains('Connection terminated during handshake')) {
            throw Exception(
                'HandshakeException: Connection terminated during TLS handshake when downloading chunk $index from path $path. Check your network, proxy, or storage TLS configuration. Original: $e');
          }
          if (attempts >= maxAttempts) rethrow;
          await Future.delayed(Duration(milliseconds: 400 * attempts));
          continue;
        }
      }
    }

    int i = 0;
    while (i < sortedUnique.length) {
      // If we already received expected bytes, avoid scheduling more downloads
      if (expectedBytes > 0 && totalBytesReceived >= expectedBytes) {
        print(
            '[Download] received expected bytes ($totalBytesReceived >= $expectedBytes), skipping remaining chunks');
        break;
      }

      final batch = <Future>[];
      for (int k = 0; k < 4 && i < sortedUnique.length; k++) {
        final c = sortedUnique[i];
        batch.add(fetchChunk(c['index'], c['path'], c['token']));
        i++;
      }
      await Future.wait(batch);
    }
    client.close();

    // 3. Merge
    // Optimized merge: Determine total size and allocate single buffer
    int totalLen = 0;
    final missingIndices = <int>[];
    for (int idx = 0; idx < parts.length; idx++) {
      if (parts[idx] == null) {
        missingIndices.add(idx);
      } else {
        totalLen += parts[idx]!.length;
      }
    }

    // Allocate final buffer of exact size
    final assembled = Uint8List(totalLen);
    int offset = 0;
    for (int idx = 0; idx < parts.length; idx++) {
      if (parts[idx] != null) {
        assembled.setRange(offset, offset + parts[idx]!.length, parts[idx]!);
        offset += parts[idx]!.length;
        // Free memory for this part immediately
        parts[idx] = null;
      }
    }

    print(
        '[Download] assembled byte length=${assembled.length} expected=$expectedBytes totalReceived=$totalBytesReceived missingChunks=${missingIndices.length}');

    if (expectedBytes > 0 && assembled.length != expectedBytes) {
      print(
          '[Download][WARN] assembled size (${assembled.length}) != expected size ($expectedBytes)');
      print('[Download][WARN] chunk map: ${sortedUnique.map((c) => {
            'index': c['index'],
            'path': c['path'],
            'size_mb': c['size_mb']
          }).toList()}');
      print('[Download][WARN] missing indices: $missingIndices');
      // Provide hint to developers: duplicates or mis-indexed chunks can cause this
      final dupCheck = <int, int>{};
      for (var c in chunks) {
        dupCheck[c['index']] = (dupCheck[c['index']] ?? 0) + 1;
      }
      final dups = dupCheck.entries
          .where((e) => e.value > 1)
          .map((e) => {'index': e.key, 'count': e.value})
          .toList();
      if (dups.isNotEmpty)
        print(
            '[Download][WARN] server returned duplicate chunk indices: $dups');
    }

    return assembled;
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
      throw Exception(
          'Failed to get eligible storage account: ${response.body}');
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

  // --- Streaming Logic for Large Files ---
  Future<void> downloadDistributedFileToFile(
      String fileIdRef, double totalSizeMb, File targetFile,
      {Function(double)? onProgress}) async {
    // 1. Info
    final infoResp = await http.post(
        Uri.parse('$backendUrl/api/files/download-info'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'fileIdRef': fileIdRef}));

    if (infoResp.statusCode != 200) throw Exception("Failed info");

    final data = jsonDecode(infoResp.body);
    final chunks = (data['chunks'] as List).cast<Map<String, dynamic>>();

    // Deduplicate
    final uniqueChunks = <int, Map<String, dynamic>>{};
    for (var c in chunks) uniqueChunks[c['index']] = c;
    final sortedUnique = uniqueChunks.values.toList()
      ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));

    // Stats
    int expectedBytes = (totalSizeMb * 1024 * 1024).round();
    // (Simpler calculation for now, progress is approximate)

    // Prepare
    if (await targetFile.exists()) await targetFile.delete();
    // Create parent if not exists
    if (!await targetFile.parent.exists())
      await targetFile.parent.create(recursive: true);

    final raf = await targetFile.open(mode: FileMode.write);

    // Temp Dir
    final tempDir = Directory(p.join(
        targetFile.parent.path, ".${p.basename(targetFile.path)}_parts"));
    if (!await tempDir.exists()) await tempDir.create();

    // State
    int nextWriteIndex = 0;
    final Map<int, File> completedParts = {};
    int totalBytesReceived = 0;

    // Helper to merge
    Future<void> _tryMerge() async {
      while (completedParts.containsKey(nextWriteIndex)) {
        final partFile = completedParts[nextWriteIndex]!;
        // Write block by block
        final reader = await partFile.open(mode: FileMode.read);
        final len = await reader.length();
        int off = 0;
        final bufSize = 1024 * 1024;
        while (off < len) {
          int count = (len - off < bufSize) ? (len - off) : bufSize;
          final bytes = await reader.read(count);
          await raf.writeFrom(bytes);
          off += bytes.length;
        }
        await reader.close();
        await partFile.delete();
        completedParts.remove(nextWriteIndex);
        nextWriteIndex++;
      }
    }

    final client = http.Client();

    try {
      Future<void> fetchAndStore(int index, String path, String token) async {
        final url = 'https://content.dropboxapi.com/2/files/download';
        final headers = {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': jsonEncode({"path": path}),
        };

        final partPath = p.join(tempDir.path, "$index.part");
        final partFile = File(partPath);

        // Retry loop
        int attempts = 0;
        while (true) {
          attempts++;
          try {
            final req = http.Request('POST', Uri.parse(url));
            req.headers.addAll(headers);
            final resp = await client.send(req);
            if (resp.statusCode != 200)
              throw Exception("Status: ${resp.statusCode}");

            final sink = partFile.openWrite();
            await resp.stream.listen((chunk) {
              sink.add(chunk);
              totalBytesReceived += chunk.length;
              if (onProgress != null && expectedBytes > 0) {
                double p = totalBytesReceived / expectedBytes;
                if (p > 1.0) p = 1.0;
                onProgress(p);
              }
            }).asFuture();
            await sink.close();

            completedParts[index] = partFile;
            await _tryMerge();
            break;
          } catch (e) {
            if (attempts >= 3) rethrow;
            await Future.delayed(Duration(seconds: attempts));
          }
        }
      }

      // Execution Loop (Batch of 3)
      int i = 0;
      while (i < sortedUnique.length) {
        final batch = <Future>[];
        for (int k = 0; k < 3 && i < sortedUnique.length; k++) {
          final c = sortedUnique[i];
          batch.add(fetchAndStore(c['index'], c['path'], c['token']));
          i++;
        }
        await Future.wait(batch);
      }
    } finally {
      client.close();
      await raf.close();
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {}
      }
    }
  }
}
