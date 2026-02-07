import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/keepr_theme.dart';
import '../services/api_service.dart';
import '../services/folder_upload_service.dart';
import 'file_manager_screen.dart';

class SetPinScreen extends StatefulWidget {
  final ApiService api;
  final String token;
  final String userEmail;
  final FolderUploadService? uploader;

  const SetPinScreen(
      {super.key,
      required this.api,
      required this.token,
      required this.userEmail,
      this.uploader});

  @override
  State<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends State<SetPinScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isLoading = false;

  void _showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error
          ? Colors.redAccent.withAlpha((0.8 * 255).round())
          : Colors.green.withAlpha((0.8 * 255).round()),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    if (!RegExp(r"^\d{6}").hasMatch(pin)) {
      return _showSnack('PIN must be 6 digits', error: true);
    }
    if (pin != confirm) return _showSnack('PINs do not match', error: true);

    setState(() => _isLoading = true);
    try {
      final ok = await widget.api.setPin(widget.token, pin);
      if (ok) {
        _showSnack('PIN set successfully');
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => FileManagerScreen(
                userId: widget.userEmail,
                api: widget.api,
                uploader: widget.uploader ??
                    FolderUploadService(
                        backendUrl: 'https://keepr-gold.vercel.app'))));
      } else {
        _showSnack('Failed to set PIN', error: true);
      }
    } catch (e) {
      _showSnack('Network error', error: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: const Color(0xFF0b1220),
      body: Center(
        child: Container(
          width: size.width < 600 ? size.width * 0.92 : 520,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              KeeprTheme.primary.withAlpha(40),
              KeeprTheme.accent.withAlpha(20)
            ]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withAlpha(30)),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withAlpha(120),
                  blurRadius: 30,
                  offset: const Offset(0, 8))
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Create your 6‑digit PIN',
                  style: GoogleFonts.zillaSlab(
                      fontSize: 26,
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                  'This PIN grants quick access to your account across devices. Choose something you will remember but that others won\'t guess.',
                  style: GoogleFonts.inter(color: Colors.white60, fontSize: 13),
                  textAlign: TextAlign.center),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 6,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Enter PIN',
                        filled: true,
                        fillColor: Colors.white.withAlpha(8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none),
                      ),
                      style: const TextStyle(
                          letterSpacing: 8, fontSize: 20, color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _confirmController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 6,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Confirm',
                        filled: true,
                        fillColor: Colors.white.withAlpha(8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none),
                      ),
                      style: const TextStyle(
                          letterSpacing: 8, fontSize: 20, color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KeeprTheme.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text('Save & Continue',
                          style: GoogleFonts.zillaSlab(
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
