import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String backendBase;

  ApiService({required this.backendBase});

  /// Convenience factory that reads backend base from compile-time define when
  /// running locally: `--dart-define=BACKEND_BASE=http://localhost:3000`.
  factory ApiService.forEnv() => ApiService(
      backendBase: const String.fromEnvironment('BACKEND_BASE',
          defaultValue: 'http://localhost:3000'));

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
}
