import 'dart:io';
import 'dart:async';
import 'dart:isolate';
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

  // Helper for background service or path-based uploads
  Future<void> uploadFileFromPath({
    required String path,
    required String name,
    required int size,
    required String userId,
    required String logicalPath,
    String? existingFileId,
    Function(double)? onProgress,
    bool Function()? isCancelled,
    bool Function()? isPaused,
    Function(String)? onFileIdCreated,
  }) async {
    final file = PlatformFile(
      name: name,
      size: size,
      path: path,
      bytes: null,
      readStream: null,
    );
    await _uploadFileDistributed(file, userId, logicalPath,
        existingFileId: existingFileId,
        onProgress: onProgress,
        isCancelled: isCancelled,
        isPaused: isPaused,
        onFileIdCreated: onFileIdCreated);
  }

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
      {String? existingFileId,
      Function(double)? onProgress,
      bool Function()? isCancelled,
      bool Function()? isPaused,
      Function(String)? onFileIdCreated}) async {
    final int chunkSize = 4 * 1024 * 1024; // 4MB
    final int totalSize = file.size;
    final int totalChunks = (totalSize / chunkSize).ceil();
    final String fileName = file.name;
    final double totalSizeMb = totalSize / (1024 * 1024);

    String fileId = existingFileId ?? '';
    Set<int> completedIndices = {};

    // 1. Init Upload (or Resume)
    if (fileId.isNotEmpty) {
      try {
        final statusResp = await http.post(
            Uri.parse('$backendUrl/api/upload/status'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'fileId': fileId}));
        
        if (statusResp.statusCode == 200) {
          final data = jsonDecode(statusResp.body);
          final chunks = (data['completedChunks'] as List).cast<Map<String, dynamic>>();
          for (var c in chunks) {
            completedIndices.add(c['index'] as int);
          }
           print('[Upload] Resuming upload for $fileId. Completed chunks: ${completedIndices.length}/$totalChunks');
        } else {
           print('[Upload] Failed to resume, starting fresh.');
           fileId = '';
        }
      } catch (e) {
         print('[Upload] Status check failed: $e, starting fresh.');
         fileId = '';
      }
    }

    if (fileId.isEmpty) {
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
      fileId = jsonDecode(initResp.body)['fileId'];
    }

    onFileIdCreated?.call(fileId);
    print(
        "Initialized upload for $fileName (ID: $fileId) with $totalChunks chunks");

    // 2. Prepare chunks
    List<Map<String, dynamic>> completedChunks = []; // Fixed variable name
    int bytesUploaded = 0;
    
    // Calculate initial bytesUploaded based on completed chunks
    if (completedIndices.isNotEmpty) {
       bytesUploaded = 0;
       for (var idx in completedIndices) {
          int size = chunkSize;
           if (idx == totalChunks - 1) {
             size = totalSize - (idx * chunkSize);
           }
           bytesUploaded += size;
       }
       if (bytesUploaded > totalSize) bytesUploaded = totalSize;
       if (onProgress != null) onProgress(bytesUploaded / totalSize);
    }

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
      Future<void> waitWhilePaused() async {
        while (isPaused?.call() ?? false) {
          if (isCancelled?.call() ?? false) {
            throw Exception('Cancelled');
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

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

        // Clamp bytesUploaded to totalSize to prevent > 100% UI
        if (bytesUploaded > totalSize) bytesUploaded = totalSize;

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
            (result) => completedChunks.add(result),
            isCancelled: isCancelled,
            isPaused: isPaused);

        // Final progress
        if (onProgress != null) onProgress(1.0);
      } else {
        // RANDOM ACCESS MODE (Bytes or RAF)

        void startNext() async {
          if (fatalErrors.isNotEmpty) return;
          if (isCancelled?.call() ?? false) {
            if (!doneCompleter.isCompleted) {
              fatalErrors.add(Exception("Cancelled"));
              doneCompleter.completeError(Exception("Cancelled"));
            }
            return;
          }
          if (isPaused?.call() ?? false) {
            await waitWhilePaused();
          }
          if (chunkIndex >= totalChunks) {
            if (activeUploads == 0 && !doneCompleter.isCompleted)
              doneCompleter.complete();
            return;
          }

          final i = chunkIndex++;

          // Skip if already uploaded
          if (completedIndices.contains(i)) {
             // We don't add to completedChunks (backend already has it)
             // Just proceed to next
             startNext();
             return;
          }

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
                isCancelled: isCancelled,
                isPaused: isPaused,
                onChunkProgress: (sent, total) {
                  // RESET LOGIC: If sent < prevSentForChunk, it implies a retry/restart
                  // within _processChunk, so we must reset our tracker.
                  // CRITICAL: We also need to handle the case where 'sent' jumps ahead but we *know* it's a retry
                  // because _processChunk manages its own retries invisibly to us.
                  // However, we can't easily detect a retry if the first progress event is > prevSentForChunk.
                  // For example, if prev was 50, and retry jumps to 70 immediately.
                  // In that case, we would add (70-50)=20. The total adds up to 70.
                  // This is functionally correct for the progress bar (it just doesn't dip back to 0).
                  // So the only danger is if we DON'T detect a lower value, but we somehow double count.
                  // If we don't detect a lower value, we simply add the delta.
                  // Since the retry starts sending from byte 0, the 'sent' value mirrors ONLY the current attempt.
                  // So if attempt 1 sent 50 bytes (sent=50), and attempt 2 sends 70 bytes (sent=70),
                  // if we treat it as a continuation, we add (70-50)=20 to the global sum.
                  // Total added to global sum = 50 + 20 = 70.
                  // This is CORRECT. The user sees progress go 50% -> 70% (skipping the dip to 0).
                  // This is actually better UX than dipping to 0.
                  // But wait, what if attempt 2 fails at 70?
                  // Then we have 70 added.
                  // Attempt 3 starts at 0.
                  // 0 < 70 -> We subtract 70 and reset to 0.
                  // Global sum reverts correctly.

                  // So the logic holds:
                  // 1. If sent < prev, we MUST reset because we are seeing "earlier" bytes again.
                  // 2. If sent >= prev, we assume progress continues (even if it's a new attempt that just caught up).

                  if (sent < prevSentForChunk) {
                    // Start of a retry: we revert the global bytesUploaded by the amount previously contributed by this chunk
                    bytesUploaded -= prevSentForChunk;
                    prevSentForChunk = 0;
                  }

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
    if (isCancelled?.call() ?? false) {
      throw Exception('Cancelled');
    }

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
      Function(Map<String, dynamic>) onChunkCompleted,
      {bool Function()? isCancelled,
      bool Function()? isPaused}) async {
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
      while (active.length >= concurrency) {
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        while (isPaused?.call() ?? false) {
          if (isCancelled?.call() ?? false) {
            throw Exception('Cancelled');
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }
        await Future.any(active);
      }
    }

    // Helper to start a chunk upload
    void startChunk(int idx, List<int> data) {
      activeChunkProgress[idx] = 0; // Initialize

      final f = _processChunk(
          fileId: fileId,
          chunkIndex: idx,
          chunkData: data,
          isCancelled: isCancelled,
          isPaused: isPaused,
          onChunkComplete: onChunkCompleted,
          onChunkProgress: (sent, total) {
            activeChunkProgress[idx] = sent;
            updateProgress();
          }).then((_) {
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
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        while (isPaused?.call() ?? false) {
          if (isCancelled?.call() ?? false) {
            throw Exception('Cancelled');
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }

        await waitForSlot();

        final chunkData = buffer.sublist(0, chunkSize);
        buffer.removeRange(0, chunkSize);

        startChunk(currentChunkIndex++, chunkData);
      }
    }

    if (buffer.isNotEmpty) {
      if (isCancelled?.call() ?? false) {
        throw Exception('Cancelled');
      }
      while (isPaused?.call() ?? false) {
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }

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
      bool Function()? isCancelled,
      bool Function()? isPaused,
      Function(int sent, int total)? onChunkProgress}) async {
    final sizeMb = chunkData.length / (1024 * 1024);

    // A. Allocate
    // A. Allocate (with retry)
    int allocAttempts = 0;
    int maxAllocAttempts = 3;
    Map<String, dynamic> alloc;
    while (true) {
      if (isCancelled?.call() ?? false) {
        throw Exception('Cancelled');
      }
      while (isPaused?.call() ?? false) {
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }

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
      if (isCancelled?.call() ?? false) {
        throw Exception('Cancelled');
      }
      while (isPaused?.call() ?? false) {
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }

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
        if (isCancelled?.call() ?? false) {
          throw Exception('Cancelled');
        }
        print('[Upload] upload attempt $uploadAttempts error: $e');
        // Friendly wrap for TLS handshake errors
        final errMsg = e.toString();
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

  Future<void> downloadFileToPath(String dropboxPath, File targetFile,
      {Function(double)? onProgress}) async {
    final token = await _getBestStorageToken();
    final dio = Dio();

    // We can use the /download endpoint directly
    final url = 'https://content.dropboxapi.com/2/files/download';

    await dio.download(
      url,
      targetFile.path,
      options: Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Dropbox-API-Arg': jsonEncode({"path": dropboxPath}),
        },
        responseType: ResponseType.bytes,
      ),
      onReceiveProgress: (received, total) {
        if (total != -1 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );
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
      {Function(double)? onProgress,
      bool Function()? isCancelled,
      bool Function()? isPaused}) async {
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

    if (sortedUnique.isEmpty) {
      throw Exception('No chunks available for download');
    }

    // Isolate Communication Ports
    final receivePort = ReceivePort(); // For progress & status
    SendPort? isolateControlPort;
    final completer = Completer<void>();
    StreamSubscription? sub;
    Timer? statusTimer;

    try {
      // Spawn execution in background isolate
      await Isolate.spawn(
        _downloadWorker,
        {
          'sendPort': receivePort.sendPort,
          'chunks': sortedUnique,
          'targetPath': targetFile.path,
          'totalSizeMb': totalSizeMb,
        },
      );

      sub = receivePort.listen((message) {
        if (message is SendPort) {
          isolateControlPort = message;

          // Start polling status to push to worker
          statusTimer?.cancel();
          statusTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
            if (isolateControlPort == null) return;

            bool cancelled = isCancelled?.call() ?? false;
            bool paused = isPaused?.call() ?? false;

            if (cancelled) {
              isolateControlPort!.send('cancel');
              timer.cancel();
            } else if (paused) {
              isolateControlPort!.send('pause');
            } else {
              isolateControlPort!.send('resume');
            }
          });
        } else if (message is Map) {
          final type = message['type'];
          if (type == 'progress') {
            final double p = message['value'];
            onProgress?.call(p);
          } else if (type == 'done') {
            completer.complete();
          } else if (type == 'error') {
            completer.completeError(message['error']);
          }
        }
      });

      await completer.future;
    } finally {
      statusTimer?.cancel();
      sub?.cancel();
      receivePort.close();
    }
  }
}

Future<void> _downloadWorker(Map<String, dynamic> args) async {
  final SendPort sendPort = args['sendPort'];
  final List<Map<String, dynamic>> sortedUnique =
      (args['chunks'] as List).cast<Map<String, dynamic>>();
  final String targetPath = args['targetPath'];
  final double totalSizeMb = args['totalSizeMb'];

  final controlPort = ReceivePort();
  sendPort.send(controlPort.sendPort);

  // Control State
  bool isCancelled = false;
  bool isPaused = false;

  controlPort.listen((msg) {
    if (msg == 'cancel') isCancelled = true;
    if (msg == 'pause') isPaused = true;
    if (msg == 'resume') isPaused = false;
  });

  try {
    // Stats
    int expectedBytes = (totalSizeMb * 1024 * 1024).round();

    // Prepare
    final targetFile = File(targetPath);
    if (await targetFile.exists()) await targetFile.delete();
    if (!await targetFile.parent.exists())
      await targetFile.parent.create(recursive: true);

    final raf = await targetFile.open(mode: FileMode.write);

    // Temp Dir
    final tempDir = Directory(p.join(
        targetFile.parent.path, ".${p.basename(targetFile.path)}_parts"));
    if (!await tempDir.exists()) await tempDir.create();

    // State
    int nextWriteIndex = sortedUnique.first['index'] as int;
    final int expectedChunkCount = sortedUnique.length;
    final Map<int, File> completedParts = {};
    int totalBytesReceived = 0;
    int mergedChunkCount = 0;
    int lastEmitTime = 0;

    void emitProgress() {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastEmitTime < 200) return; // Throttle
      lastEmitTime = now;

      double p = 0;
      if (expectedBytes > 0) p = totalBytesReceived / expectedBytes;
      if (p > 1.0) p = 1.0;
      sendPort.send({'type': 'progress', 'value': p});
    }

    // Helper to merge
    Future<void> _tryMerge() async {
      while (completedParts.containsKey(nextWriteIndex)) {
        final partFile = completedParts[nextWriteIndex]!;
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
        mergedChunkCount++;
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
          if (isCancelled) throw Exception("Cancelled");
          while (isPaused) {
            if (isCancelled) throw Exception("Cancelled");
            await Future.delayed(Duration(milliseconds: 500));
          }
          attempts++;
          int bytesReceivedForThisPart = 0;
          try {
            final req = http.Request('POST', Uri.parse(url));
            req.headers.addAll(headers);
            final resp = await client.send(req);
            if (resp.statusCode != 200)
              throw Exception("Status: ${resp.statusCode}");

            final sink = partFile.openWrite();
            await for (final chunk in resp.stream) {
              if (isCancelled) {
                await sink.close();
                throw Exception("Cancelled");
              }
              while (isPaused) {
                if (isCancelled) {
                  await sink.close();
                  throw Exception("Cancelled");
                }
                await Future.delayed(Duration(milliseconds: 500));
              }
              sink.add(chunk);
              bytesReceivedForThisPart += chunk.length;
              totalBytesReceived += chunk.length;
              emitProgress();
            }
            await sink.close();

            completedParts[index] = partFile;
            break;
          } catch (e) {
            totalBytesReceived -= bytesReceivedForThisPart;
            emitProgress();
            if (e.toString().contains("Cancelled")) rethrow;
            if (attempts >= 3) rethrow;
            await Future.delayed(Duration(seconds: attempts));
          }
        }
      }

      // Execution Loop (Batch of 3)
      int i = 0;
      while (i < sortedUnique.length) {
        if (isCancelled) throw Exception("Cancelled");
        while (isPaused) {
          if (isCancelled) throw Exception("Cancelled");
          await Future.delayed(Duration(milliseconds: 500));
        }
        final batch = <Future>[];
        for (int k = 0; k < 3 && i < sortedUnique.length; k++) {
          final c = sortedUnique[i];
          batch.add(fetchAndStore(c['index'], c['path'], c['token']));
          i++;
        }
        await Future.wait(batch);
        await _tryMerge();
      }
    } finally {
      client.close();
      await raf.close();
      controlPort.close();
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {}
      }
      if (isCancelled) {
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
      } else if (mergedChunkCount != expectedChunkCount) {
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        throw Exception(
            'Download incomplete: merged $mergedChunkCount/$expectedChunkCount chunks');
      }
    }

    sendPort.send({'type': 'done'});
  } catch (e) {
    sendPort.send({'type': 'error', 'error': e.toString()});
  }
}
