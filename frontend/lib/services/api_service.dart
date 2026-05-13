import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class ExportedNoteFile {
  final Uint8List bytes;
  final String fileName;
  final String contentType;

  ExportedNoteFile({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });
}

class ApiService {
  final String backendBase;

  ApiService({required this.backendBase});

  /// Convenience factory that reads backend base from compile-time define when
  /// running locally: `--dart-define=BACKEND_BASE=https://keepr-gold.vercel.app`.
  factory ApiService.forEnv() => ApiService(
      backendBase: const String.fromEnvironment('BACKEND_BASE',
          defaultValue: 'https://keepr-gold.vercel.app'));

  Future<bool> sendOtp(String email) async {
    final url = Uri.parse('$backendBase/api/auth/send-otp');
    final resp = await http.post(url,
        body: jsonEncode({'email': email}),
        headers: {'Content-Type': 'application/json'});

    if (resp.statusCode == 200) return true;
    return false;
  }

  // Returns a token string on success, null on failure
  Future<String?> verifyOtp(String email, String otp) async {
    final url = Uri.parse('$backendBase/api/auth/verify-otp');
    final resp = await http.post(url,
        body: jsonEncode({'email': email, 'otp': otp}),
        headers: {'Content-Type': 'application/json'});

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['token'] as String?;
    }
    return null;
  }

  // Auth: Google Sign-In (send idToken or accessToken to backend and get revocable token)
  Future<String?> googleSignIn(
      {String? idToken, String? accessToken, String? deviceInfo}) async {
    final url = Uri.parse('$backendBase/api/auth/google-signin');
    final body = <String, dynamic>{
      if (idToken != null) 'idToken': idToken,
      if (accessToken != null) 'accessToken': accessToken,
      if (deviceInfo != null) 'deviceInfo': deviceInfo,
    };

    final resp = await http.post(url,
        body: jsonEncode(body), headers: {'Content-Type': 'application/json'});

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['token'] as String?;
    }
    return null;
  }

  // Development debug helper: sends Google token to backend debug endpoint and returns parsed payload
  Future<Map<String, dynamic>> debugGoogleToken(
      {String? idToken, String? accessToken}) async {
    final url = Uri.parse('$backendBase/api/debug/google-payload');
    final body = <String, dynamic>{
      if (idToken != null) 'idToken': idToken,
      if (accessToken != null) 'accessToken': accessToken,
    };

    final resp = await http.post(url,
        body: jsonEncode(body), headers: {'Content-Type': 'application/json'});
    if (resp.statusCode == 200)
      return jsonDecode(resp.body) as Map<String, dynamic>;
    throw Exception('Debug request failed: ${resp.statusCode} ${resp.body}');
  }

  Future<bool> setPin(String token, String pin) async {
    final url = Uri.parse('$backendBase/api/auth/set-pin');
    final resp = await http.post(url, body: jsonEncode({'pin': pin}), headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token'
    });
    return resp.statusCode == 200;
  }

  Future<String?> pinLogin(String email, String pin,
      {String? deviceInfo}) async {
    final url = Uri.parse('$backendBase/api/auth/pin-login');
    final resp = await http.post(url,
        body:
            jsonEncode({'email': email, 'pin': pin, 'deviceInfo': deviceInfo}),
        headers: {'Content-Type': 'application/json'});

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      return data['token'] as String?;
    }
    return null;
  }

  Future<bool> requestPinReset(String email, {String? resetUrlBase}) async {
    final url = Uri.parse('$backendBase/api/auth/request-pin-reset');
    final resp = await http.post(url,
        body: jsonEncode({'email': email, 'resetUrlBase': resetUrlBase}),
        headers: {'Content-Type': 'application/json'});
    return resp.statusCode == 200;
  }

  Future<bool> confirmPinReset(String resetToken, String newPin) async {
    final url = Uri.parse('$backendBase/api/auth/confirm-pin-reset');
    final resp = await http.post(url,
        body: jsonEncode({'resetToken': resetToken, 'newPin': newPin}),
        headers: {'Content-Type': 'application/json'});
    return resp.statusCode == 200;
  }

  Future<bool> revokeToken(String token) async {
    final url = Uri.parse('$backendBase/api/auth/revoke-token');
    final resp = await http.post(url, headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token'
    });
    return resp.statusCode == 200;
  }

  Future<Map<String, dynamic>?> getProfile(String token) async {
    final url = Uri.parse('$backendBase/api/auth/profile');
    final resp = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode == 200)
      return jsonDecode(resp.body) as Map<String, dynamic>;
    return null;
  }

  // Files / Folders
  Future<Map<String, dynamic>> listFiles(String userId,
      {String path = '/'}) async {
    final url = Uri.parse(
        '$backendBase/api/files/list?user_id=$userId&path=${Uri.encodeComponent(path)}');
    final resp = await http.get(url);
    if (resp.statusCode == 200)
      return jsonDecode(resp.body) as Map<String, dynamic>;
    throw Exception('Failed to list files');
  }

  Future<bool> createFolder(String userId, String path) async {
    final url = Uri.parse('$backendBase/api/files/create-folder');
    final resp = await http.post(url,
        body: jsonEncode({'user_id': userId, 'path': path}),
        headers: {'Content-Type': 'application/json'});
    return resp.statusCode == 200;
  }

  Future<bool> deleteFile(String userId, String path) async {
    final url = Uri.parse('$backendBase/api/files/delete');
    final resp = await http.post(url,
        body: jsonEncode({'userId': userId, 'path': path}),
        headers: {'Content-Type': 'application/json'});
    if (resp.statusCode != 200) {
      throw Exception('Delete failed: ${resp.body}');
    }
    return true;
  }

  Future<bool> uploadMetadata(String userId, String path, String name,
      double sizeMb, String dropboxPath) async {
    final url = Uri.parse('$backendBase/api/files/upload-metadata');
    final resp = await http.post(url,
        body: jsonEncode({
          'user_id': userId,
          'path': path,
          'name': name,
          'size_mb': sizeMb,
          'dropbox_path': dropboxPath
        }),
        headers: {'Content-Type': 'application/json'});
    return resp.statusCode == 200;
  }

  // Saved messages
  Future<List<Map<String, dynamic>>> listSavedMessages(String token) async {
    final url = Uri.parse('$backendBase/api/messages/saved');
    final resp = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to list saved messages: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (data['items'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return items;
  }

  Future<Map<String, dynamic>> createSavedMessage(
      String token, String messageText,
      {List<String> tags = const [], bool isPinned = false}) async {
    final url = Uri.parse('$backendBase/api/messages/saved');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(
            {'messageText': messageText, 'tags': tags, 'isPinned': isPinned}));

    if (resp.statusCode != 200) {
      throw Exception('Failed to create saved message: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(data['item'] as Map);
  }

  Future<void> deleteSavedMessage(String token, int id) async {
    final url = Uri.parse('$backendBase/api/messages/saved/$id');
    final resp = await http.delete(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to delete saved message: ${resp.body}');
    }
  }

  // Notes
  Future<List<Map<String, dynamic>>> listNotes(String token) async {
    final url = Uri.parse('$backendBase/api/notes');
    final resp = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to list notes: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['items'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createNote(
    String token, {
    required String title,
    String contentText = '',
    Map<String, dynamic> contentJson = const {},
  }) async {
    final url = Uri.parse('$backendBase/api/notes');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'title': title,
          'contentText': contentText,
          'contentJson': contentJson,
        }));

    if (resp.statusCode != 200) {
      throw Exception('Failed to create note: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(data['item'] as Map);
  }

  Future<Map<String, dynamic>> getNote(String token, int id) async {
    final url = Uri.parse('$backendBase/api/notes/$id');
    final resp = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch note: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateNote(
    String token,
    int id, {
    required String title,
    required String contentText,
    Map<String, dynamic> contentJson = const {},
  }) async {
    final url = Uri.parse('$backendBase/api/notes/$id');
    final resp = await http.put(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'title': title,
          'contentText': contentText,
          'contentJson': contentJson,
        }));
    if (resp.statusCode != 200) {
      throw Exception('Failed to update note: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(data['item'] as Map);
  }

  Future<void> deleteNote(String token, int id) async {
    final url = Uri.parse('$backendBase/api/notes/$id');
    final resp = await http.delete(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to delete note: ${resp.body}');
    }
  }

  Future<Map<String, dynamic>> initNoteMediaUpload(
    String token,
    int noteId, {
    required String fileName,
    required String mimeType,
    required double sizeMb,
  }) async {
    final url = Uri.parse('$backendBase/api/notes/$noteId/media/init');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(
            {'fileName': fileName, 'mimeType': mimeType, 'sizeMb': sizeMb}));
    if (resp.statusCode != 200) {
      throw Exception('Failed to init media upload: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> completeNoteMediaUpload(
    String token,
    int noteId, {
    required String assetName,
    required String mimeType,
    required double sizeMb,
    required String dropboxPath,
    required String storageSource,
    required String storageShardRef,
  }) async {
    final url = Uri.parse('$backendBase/api/notes/$noteId/media/complete');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'assetName': assetName,
          'mimeType': mimeType,
          'sizeMb': sizeMb,
          'dropboxPath': dropboxPath,
          'storageSource': storageSource,
          'storageShardRef': storageShardRef,
        }));
    if (resp.statusCode != 200) {
      throw Exception('Failed to complete media upload: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(data['item'] as Map);
  }

  Future<String> getNoteMediaTemporaryLink(
    String token, {
    required String dropboxPath,
    required String storageSource,
    required String storageShardRef,
  }) async {
    final url = Uri.parse('$backendBase/api/notes/media/temp-link');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'dropboxPath': dropboxPath,
          'storageSource': storageSource,
          'storageShardRef': storageShardRef,
        }));
    if (resp.statusCode != 200) {
      throw Exception('Failed to get media link: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['link']?.toString() ?? '';
  }

  Future<void> deleteNoteAsset(String token, int noteId, int assetId) async {
    final url = Uri.parse('$backendBase/api/notes/$noteId/assets/$assetId');
    final resp = await http.delete(url, headers: {'Authorization': 'Bearer $token'});
    if (resp.statusCode != 200) {
      throw Exception('Failed to delete asset: ${resp.body}');
    }
  }

  Future<ExportedNoteFile> exportNote(
    String token,
    int noteId,
    String format,
  ) async {
    final url = Uri.parse('$backendBase/api/notes/$noteId/export');
    final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'format': format}));

    if (resp.statusCode != 200) {
      throw Exception('Failed to export note: ${resp.body}');
    }

    final disposition = resp.headers['content-disposition'] ?? '';
    String fileName = 'note.$format';
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    if (match != null && match.groupCount >= 1) {
      fileName = match.group(1) ?? fileName;
    }

    return ExportedNoteFile(
      bytes: resp.bodyBytes,
      fileName: fileName,
      contentType: resp.headers['content-type'] ?? 'application/octet-stream',
    );
  }

  Future<Map<String, dynamic>> getStorageStats(String token) async {
    final url = Uri.parse('$backendBase/api/storage/stats');
    final resp = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    });
    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch storage stats: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // LaTeX documents
  
}
