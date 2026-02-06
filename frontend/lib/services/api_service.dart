import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String backendBase;

  ApiService({required this.backendBase});

  Future<bool> sendOtp(String email) async {
    final url = Uri.parse('$backendBase/api/auth/send-otp');
    final resp = await http.post(url, body: jsonEncode({ 'email': email }), headers: {
      'Content-Type': 'application/json'
    });

    if (resp.statusCode == 200) return true;
    return false;
  }

  Future<bool> verifyOtp(String email, String otp) async {
    final url = Uri.parse('$backendBase/api/auth/verify-otp');
    final resp = await http.post(url, body: jsonEncode({ 'email': email, 'otp': otp }), headers: {
      'Content-Type': 'application/json'
    });

    if (resp.statusCode == 200) return true;
    return false;
  }

  // Files / Folders
  Future<Map<String, dynamic>> listFiles(String userId, {String path = '/'}) async {
    final url = Uri.parse('$backendBase/api/files/list?user_id=$userId&path=${Uri.encodeComponent(path)}');
    final resp = await http.get(url);
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    throw Exception('Failed to list files');
  }

  Future<bool> createFolder(String userId, String path) async {
    final url = Uri.parse('$backendBase/api/files/create-folder');
    final resp = await http.post(url, body: jsonEncode({ 'user_id': userId, 'path': path }), headers: {
      'Content-Type': 'application/json'
    });
    return resp.statusCode == 200;
  }

  Future<bool> uploadMetadata(String userId, String path, String name, double sizeMb, String dropboxPath) async {
    final url = Uri.parse('$backendBase/api/files/upload-metadata');
    final resp = await http.post(url, body: jsonEncode({ 'user_id': userId, 'path': path, 'name': name, 'size_mb': sizeMb, 'dropbox_path': dropboxPath }), headers: {
      'Content-Type': 'application/json'
    });
    return resp.statusCode == 200;
  }
}