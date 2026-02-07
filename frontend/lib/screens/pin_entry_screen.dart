import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/api_service.dart';
import '../services/folder_upload_service.dart';
import 'file_manager_screen.dart';

class PinEntryScreen extends StatefulWidget {
  final ApiService api;
  final FolderUploadService uploader;

  const PinEntryScreen({super.key, required this.api, required this.uploader});

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final _pinController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  bool _isLoading = false;
  String? _email;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEmail();
  }

  Future<void> _loadEmail() async {
    final e = await _secureStorage.read(key: 'user_email');
    setState(() => _email = e);
  }

  void _showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Colors.redAccent : Colors.green,
    ));
  }

  Future<void> _submit() async {
    if (_email == null) return _showSnack('No account found', error: true);
    final pin = _pinController.text.trim();
    if (!RegExp(r"^\d{6}").hasMatch(pin)) {
      setState(() => _error = 'PIN must be 6 digits');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final token =
          await widget.api.pinLogin(_email!, pin, deviceInfo: 'flutter-app');
      if (token != null) {
        await _secureStorage.write(key: 'auth_token', value: token);
        _showSnack('Access granted');
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (ctx) => FileManagerScreen(
                  userId: _email!,
                  api: widget.api,
                  uploader: widget.uploader,
                )));
      } else {
        setState(() => _error = 'Invalid PIN');
      }
    } catch (e) {
      setState(() => _error = 'Network error');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return Scaffold(
      backgroundColor: const Color(0xFF0b1220),
      body: Center(
        child: Container(
          width: isMobile ? size.width * 0.9 : 480,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha((0.04 * 255).round()),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 20,
                offset: const Offset(0, 6),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Welcome back',
                  style: GoogleFonts.zillaSlab(
                      fontSize: 24,
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('Enter your 6-digit PIN to unlock',
                  style:
                      GoogleFonts.inter(color: Colors.white60, fontSize: 14)),
              const SizedBox(height: 18),
              Text(_email ?? '',
                  style: GoogleFonts.inter(color: Colors.white70)),
              const SizedBox(height: 18),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: Colors.white.withAlpha((0.03 * 255).round()),
                  hintText: '••••••',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
                style: const TextStyle(
                    letterSpacing: 8, fontSize: 20, color: Colors.white),
                textAlign: TextAlign.center,
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2b7cff),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text('Unlock',
                          style: GoogleFonts.zillaSlab(
                              fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  // Clear stored session to go back to login
                  await _secureStorage.delete(key: 'auth_token');
                  await _secureStorage.delete(key: 'user_email');
                  if (!mounted) return;
                  Navigator.of(context).pushReplacementNamed('/login');
                },
                child: const Text('Use different account',
                    style: TextStyle(color: Colors.white70)),
              )
            ],
          ),
        ),
      ),
    );
  }
}
