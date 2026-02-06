import 'package:flutter/material.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/keepr_theme.dart';
import '../services/api_service.dart';
import '../services/folder_upload_service.dart';
import 'file_manager_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();

  bool _isOtpSent = false;
  bool _isLoading = false;

  // Services
  // NOTE: In production, configure these via environment variables or a DI container
  final _uploadService =
      FolderUploadService(backendUrl: 'https://keepr-gold.vercel.app');
  late final ApiService _api;

  @override
  void initState() {
    super.initState();
    _api = ApiService(backendBase: 'https://keepr-gold.vercel.app');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error
          ? Colors.redAccent.withOpacity(0.8)
          : Colors.green.withOpacity(0.8),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _handleSubmit() async {
    if (_isOtpSent) {
      await _verifyOtp();
    } else {
      await _sendOtp();
    }
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      return _showSnack('Please enter a valid email address', error: true);
    }

    setState(() => _isLoading = true);
    try {
      final ok = await _api.sendOtp(email);
      if (ok) {
        setState(() => _isOtpSent = true);
        _showSnack('OTP sent to $email');
      } else {
        _showSnack('Failed to send OTP. Try again.', error: true);
      }
    } catch (e) {
      _showSnack('Network error occurred', error: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final otp = _otpController.text.trim();

    if (otp.isEmpty) return _showSnack('Please enter the OTP', error: true);

    setState(() => _isLoading = true);
    try {
      final ok = await _api.verifyOtp(email, otp);
      if (ok) {
        _showSnack('Login successful!');
        if (!mounted) return;

        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (ctx) => FileManagerScreen(
                  userId: email,
                  api: _api,
                  uploader: _uploadService,
                )));
      } else {
        _showSnack('Invalid OTP', error: true);
      }
    } catch (e) {
      _showSnack('Network error occurred', error: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // KeeprTheme colors
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 800;

    return Scaffold(
      backgroundColor: KeeprTheme.background,
      body: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Background decorations
            Positioned(
              top: size.height * 0.1,
              left: -size.width * 0.1,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: KeeprTheme.primary.withOpacity(0.4),
                    boxShadow: [
                      BoxShadow(
                          color: KeeprTheme.primary.withOpacity(0.4),
                          blurRadius: 100,
                          spreadRadius: 40)
                    ]),
              ),
            ),
            Positioned(
              bottom: size.height * 0.1,
              right: -size.width * 0.1,
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: KeeprTheme.accent.withOpacity(0.4),
                    boxShadow: [
                      BoxShadow(
                          color: KeeprTheme.accent.withOpacity(0.4),
                          blurRadius: 100,
                          spreadRadius: 40)
                    ]),
              ),
            ),

            // Main Content Area
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Stack for Card + Image interactions
                  SizedBox(
                    // On mobile, we use full width minus padding. On desktop, fixed width 350 + slight overflow area
                    width: isMobile ? size.width : 450,
                    height: isMobile
                        ? (_isOtpSent ? 600 : 550)
                        : null, // Container for stack
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        // 1. Illustration (Re-ordered to be BEHIND on mobile)
                        Positioned(
                          top: isMobile ? -60 : -100,
                          // Center on mobile, Side on desktop
                          right: isMobile ? 0 : -40,
                          left: isMobile ? 0 : null,
                          child: IgnorePointer(
                            child: isMobile
                                ? Align(
                                    alignment: Alignment.topCenter,
                                    child: Transform.translate(
                                      offset: const Offset(
                                          40, 0), // Shift slightly right
                                      child: Image.network(
                                        'https://raw.githubusercontent.com/hicodersofficial/glassmorphism-login-form/master/assets/illustration.png',
                                        // Render behind glass
                                        height: 220,
                                        fit: BoxFit.contain,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                          return const Icon(Icons.person,
                                              size: 80, color: Colors.white54);
                                        },
                                      ),
                                    ),
                                  )
                                : Image.network(
                                    'https://raw.githubusercontent.com/hicodersofficial/glassmorphism-login-form/master/assets/illustration.png',
                                    height: 380,
                                    fit: BoxFit.contain,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Icon(Icons.person,
                                          size: 150, color: Colors.white54);
                                    },
                                  ),
                          ),
                        ),

                        // 2. Card (On Top)
                        GlassmorphicContainer(
                          width: isMobile ? size.width * 0.9 : 380,
                          // Increased height to prevent overflow when OTP fields are shown
                          height: _isOtpSent
                              ? (isMobile ? 620 : 600)
                              : (isMobile ? 460 : 460),
                          borderRadius: 20,
                          blur: 8,
                          alignment: Alignment.center,
                          border: 2,
                          linearGradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.1),
                              Colors.white.withOpacity(0.05),
                            ],
                          ),
                          borderGradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.5),
                              Colors.white.withOpacity(0.2),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 40),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Less spacing needed on mobile since image is behind
                                SizedBox(height: isMobile ? 80 : 60),
                                Text(
                                  _isOtpSent ? 'VERIFY' : 'LOGIN',
                                  style: GoogleFonts.zillaSlab(
                                    // Changed font to serif-like if needed or keep outfit? Screenshot looks like serif or bold sans. Sticking to design
                                    fontSize: 35,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white.withOpacity(0.8),
                                    letterSpacing: 2,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _isOtpSent
                                      ? 'Enter the code sent to your email'
                                      : 'Enter your email to continue',
                                  style: GoogleFonts.inter(
                                      color: Colors.white60, fontSize: 13),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 30),

                                // Email
                                _buildTextField(
                                  controller: _emailController,
                                  hint: 'Email Address',
                                  icon: Icons.email_outlined,
                                  enabled:
                                      !_isOtpSent, // Lock email when verifying
                                ),

                                // Password / OTP
                                if (_isOtpSent) ...[
                                  const SizedBox(height: 20),
                                  _buildTextField(
                                    controller: _otpController,
                                    hint: 'OTP Code',
                                    icon: Icons.lock_clock_outlined,
                                    isPassword: false,
                                    isNumber: true,
                                  ),
                                ],

                                const SizedBox(height: 40),

                                // Submit Button
                                SizedBox(
                                  width: double.infinity,
                                  height: 50,
                                  child: ElevatedButton(
                                    onPressed:
                                        _isLoading ? null : _handleSubmit,
                                    style: ElevatedButton.styleFrom(
                                      // Deep blue button from screenshot
                                      backgroundColor: const Color(0xFF15294a)
                                          .withOpacity(0.9),
                                      foregroundColor: Colors.white,
                                      elevation: 5,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 0),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(30),
                                          side: BorderSide(
                                              color: Colors.white
                                                  .withOpacity(0.1))),
                                      shadowColor:
                                          Colors.black.withOpacity(0.3),
                                    ),
                                    child: _isLoading
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                        : Text(
                                            _isOtpSent
                                                ? 'VERIFY & LOGIN'
                                                : 'SUBMIT', // Changed to SUBMIT per screenshot
                                            style: GoogleFonts.zillaSlab(
                                                // Matching the button font style if needed
                                                letterSpacing: 1.5,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16)),
                                  ),
                                ),

                                const SizedBox(height: 15),

                                if (_isOtpSent)
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _isOtpSent = false;
                                        _otpController.clear();
                                      });
                                    },
                                    child: const Text('Change Email',
                                        style:
                                            TextStyle(color: Colors.white70)),
                                  )
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool isPassword = false,
    bool isNumber = false,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Update input style: removed icon if strictly following screenshot (screenshot has no icons inside inputs?)
        // Screenshot: "USERNAME" is placeholder text inside. No icon visible.
        // Let's remove the icon to match the screenshot exactly.
        Container(
          height: 55, // Fixed height for inputs
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:
                Colors.white.withOpacity(0.05), // Lighter fill like screenshot
            borderRadius: BorderRadius.circular(
                4), // Slightly less rounded? Screenshot has slightly rounded corners, maybe not full pill.
            // Screenshot looks definitely less rounded than 30. Maybe 8 or 10.
            // Actually screenshot has sharp corners inside glass card? No, they look like standard input fields with slight radius.
            border: Border(
                bottom: BorderSide(
                    color: Colors.white.withOpacity(
                        0.1))), // Or full border? Screenshot looks sunken.
            // Let's stick to a subtle box.
          ),
          child: TextField(
            controller: controller,
            obscureText: isPassword,
            keyboardType:
                isNumber ? TextInputType.number : TextInputType.emailAddress,
            enabled: enabled,
            style: TextStyle(
                color: enabled ? Colors.white : Colors.white54,
                fontFamily: GoogleFonts.zillaSlab()
                    .fontFamily), // Using serif for input text too?
            decoration: InputDecoration(
              hintText: hint.toUpperCase(), // Uppercase hints
              hintStyle: GoogleFonts.zillaSlab(
                  color: Colors.white.withOpacity(0.3),
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1),
              // removing prefixIcon
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 0), // Centered vertically
              filled: false,
            ),
            onSubmitted: (_) => _handleSubmit(),
          ),
        ),
      ],
    );
  }
}
