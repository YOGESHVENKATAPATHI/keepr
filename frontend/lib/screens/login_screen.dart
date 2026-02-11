import 'package:flutter/material.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import '../utils/storage_helper.dart';

import '../theme/keepr_theme.dart';
import '../services/api_service.dart';
import '../services/folder_upload_service.dart';
import 'file_manager_screen.dart';
import 'set_pin_screen.dart';

// Use dart-define to inject runtime config for web/mobile
const String kGoogleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID',
    defaultValue:
        '75763106036-6d5kmkr59sn567mbe41okqikb458r6cm.apps.googleusercontent.com');
const String kBackendBase = String.fromEnvironment('BACKEND_BASE',
    defaultValue: 'https://keepr-gold.vercel.app');

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
  bool _isGoogleLoading = false;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'openid'
    ], // avoid 'profile' to prevent People API usage on web
    clientId: kGoogleClientId.isNotEmpty ? kGoogleClientId : null,
  );
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  String? _lastIdToken;
  String? _lastAccessToken;

  // Services
  // NOTE: In production, configure these via environment variables or a DI container
  final _uploadService = FolderUploadService(backendUrl: kBackendBase);
  late final ApiService _api;

  @override
  void initState() {
    super.initState();
    _api = ApiService(backendBase: kBackendBase);
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
          ? Colors.redAccent.withAlpha((0.8 * 255).round())
          : Colors.green.withAlpha((0.8 * 255).round()),
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
        if (mounted) setState(() => _isOtpSent = true);
        _showSnack('OTP sent to $email');
      } else {
        _showSnack('Failed to send OTP. Try again.', error: true);
      }
    } catch (e) {
      _showSnack('Network error occurred', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailController.text.trim();
    final otp = _otpController.text.trim();

    if (otp.isEmpty) return _showSnack('Please enter the OTP', error: true);

    setState(() => _isLoading = true);
    try {
      final token = await _api.verifyOtp(email, otp);
      if (token != null) {
        // Persist token & user email for session & PIN workflows
        await _secureStorage.write(key: 'auth_token', value: token);
        await _secureStorage.write(key: 'user_email', value: email);

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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (mounted) setState(() => _isGoogleLoading = true);
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        if (mounted) setState(() => _isGoogleLoading = false);
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      final accessToken = auth.accessToken;

      // Save tokens for local debug
      _lastIdToken = idToken;
      _lastAccessToken = accessToken;

      // If idToken is missing, warn in console (avoid alerting user on the UI)
      if (idToken == null && accessToken != null) {
        print(
            '[Login] No id_token returned; falling back to access_token. Ensure web OAuth client & origins are configured.');
      }

      // Prefer idToken (JWT) for server-side verification; fall back to accessToken
      final serverToken = await _api.googleSignIn(
          idToken: idToken,
          accessToken: idToken == null ? accessToken : null,
          deviceInfo: 'flutter-app');
      if (serverToken == null) {
        _showSnack('Server rejected Google sign-in', error: true);
        if (mounted) setState(() => _isGoogleLoading = false);
        return;
      }

      // Persist token securely and save user email for PIN flows
      final stoken = serverToken!;
      await _secureStorage.write(key: 'auth_token', value: stoken);
      await _secureStorage.write(key: 'user_email', value: account.email);
      // Also mirror into localStorage on web so refresh reliably shows PIN unlock
      try {
        await setLocalStorageValue('user_email', account.email ?? '');
        await setLocalStorageValue('auth_token', stoken);
      } catch (_) {}

      // Fetch profile to check if PIN is set
      final profileResp = await _api.getProfile(stoken);
      final hasPin = profileResp != null &&
          profileResp['profile'] != null &&
          profileResp['profile']['has_pin'] == true;

      _showSnack('Signed in as ${account.email}');

      if (!mounted) return;

      if (!hasPin) {
        // ask user to set a PIN
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => SetPinScreen(
                api: _api,
                token: serverToken,
                userEmail: account.email,
                uploader: _uploadService)));
      } else {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (ctx) => FileManagerScreen(
                  userId: account.email,
                  api: _api,
                  uploader: _uploadService,
                )));
      }
    } catch (e) {
      print('[Login] Google sign-in error: $e');
      _showSnack('Google sign-in failed: ${e.toString()}', error: true);
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
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
                    color: KeeprTheme.primary.withAlpha((0.4 * 255).round()),
                    boxShadow: [
                      BoxShadow(
                          color:
                              KeeprTheme.primary.withAlpha((0.4 * 255).round()),
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
                    color: KeeprTheme.accent.withAlpha((0.4 * 255).round()),
                    boxShadow: [
                      BoxShadow(
                          color:
                              KeeprTheme.accent.withAlpha((0.4 * 255).round()),
                          blurRadius: 100,
                          spreadRadius: 40)
                    ]),
              ),
            ),

            // Main Content Area
            SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: isMobile ? size.width : 600),
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      // Illustration positioned behind card
                      Positioned(
                        top: isMobile ? -60 : -100,
                        right: isMobile ? 0 : -40,
                        left: isMobile ? 0 : null,
                        child: IgnorePointer(
                          child: Image.network(
                            'https://raw.githubusercontent.com/hicodersofficial/glassmorphism-login-form/master/assets/illustration.png',
                            height: isMobile ? 220 : 380,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Icon(Icons.person,
                                  size: isMobile ? 80 : 150,
                                  color: Colors.white54);
                            },
                          ),
                        ),
                      ),

                      Center(
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: isMobile ? size.width * 0.9 : 380,
                            maxHeight: size.height * 0.85,
                          ),
                          child: GlassmorphicContainer(
                            width: isMobile ? size.width * 0.9 : 380,
                            height: isMobile
                                ? (_isOtpSent ? 620.0 : 460.0)
                                : (size.height * 0.6),
                            borderRadius: 20,
                            blur: 8,
                            alignment: Alignment.center,
                            border: 2,
                            linearGradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withAlpha((0.1 * 255).round()),
                                Colors.white.withAlpha((0.05 * 255).round()),
                              ],
                            ),
                            borderGradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withAlpha((0.5 * 255).round()),
                                Colors.white.withAlpha((0.2 * 255).round()),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 20),
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(height: isMobile ? 56 : 40),
                                    Text(
                                      _isOtpSent ? 'VERIFY' : 'LOGIN',
                                      style: GoogleFonts.zillaSlab(
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white
                                            .withAlpha((0.8 * 255).round()),
                                        letterSpacing: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _isOtpSent
                                          ? 'Enter the code sent to your email'
                                          : 'Enter your email to continue',
                                      style: GoogleFonts.inter(
                                          color: Colors.white60, fontSize: 13),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 20),

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
                                          backgroundColor:
                                              const Color(0xFF15294a).withAlpha(
                                                  (0.9 * 255).round()),
                                          foregroundColor: Colors.white,
                                          elevation: 5,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 0),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(30),
                                              side: BorderSide(
                                                  color: Colors.white.withAlpha(
                                                      (0.1 * 255).round()))),
                                          shadowColor: Colors.black
                                              .withAlpha((0.3 * 255).round()),
                                        ),
                                        child: _isLoading
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white))
                                            : Text(
                                                _isOtpSent
                                                    ? 'VERIFY & LOGIN'
                                                    : 'SUBMIT',
                                                style: GoogleFonts.zillaSlab(
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
                                            style: TextStyle(
                                                color: Colors.white70)),
                                      ),

                                    const SizedBox(height: 10),

// Google Sign-In (only on platforms where supported)
                                    if (kIsWeb ||
                                        defaultTargetPlatform ==
                                            TargetPlatform.android ||
                                        defaultTargetPlatform ==
                                            TargetPlatform.iOS) ...[
                                      SizedBox(
                                        width: double.infinity,
                                        height: 48,
                                        child: ElevatedButton.icon(
                                          onPressed: _isGoogleLoading
                                              ? null
                                              : _handleGoogleSignIn,
                                          icon: Icon(Icons.login,
                                              size: 24, color: Colors.white),
                                          label: _isGoogleLoading
                                              ? const SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white))
                                              : const Text(
                                                  'Sign in with Google'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white
                                                .withAlpha(
                                                    (0.08 * 255).round()),
                                            foregroundColor: Colors.white,
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(10)),
                                          ),
                                        ),
                                      ),
                                    ],
                                    // On unsupported platforms, optionally show nothing or a disabled hint
                                    if (!(kIsWeb ||
                                        defaultTargetPlatform ==
                                            TargetPlatform.android ||
                                        defaultTargetPlatform ==
                                            TargetPlatform.iOS)) ...[
                                      const SizedBox(height: 10),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 48,
                                        child: OutlinedButton(
                                          onPressed: null,
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.white54,
                                            backgroundColor: Colors.white
                                                .withAlpha(
                                                    (0.03 * 255).round()),
                                          ),
                                          child: const Text(
                                              'Sign in with Google (not available on desktop)'),
                                        ),
                                      ),
                                    ],

                                    const SizedBox(height: 10),

                                    // Dev debug button: send last tokens to backend debug endpoint
                                    SizedBox(
                                      width: double.infinity,
                                      child: TextButton(
                                        onPressed:
                                            (_lastIdToken == null &&
                                                        _lastAccessToken ==
                                                            null) ||
                                                    _isGoogleLoading
                                                ? null
                                                : () async {
                                                    showDialog(
                                                      context: context,
                                                      barrierDismissible: false,
                                                      builder: (ctx) =>
                                                          const Center(
                                                              child:
                                                                  CircularProgressIndicator()),
                                                    );
                                                    try {
                                                      final payload = await _api
                                                          .debugGoogleToken(
                                                              idToken:
                                                                  _lastIdToken,
                                                              accessToken:
                                                                  _lastAccessToken);
                                                      if (mounted)
                                                        Navigator.of(context)
                                                            .pop();
                                                      if (mounted)
                                                        await showDialog(
                                                            context: context,
                                                            builder:
                                                                (ctx) =>
                                                                    AlertDialog(
                                                                      title: const Text(
                                                                          'Debug token payload'),
                                                                      content: SingleChildScrollView(
                                                                          child:
                                                                              Text(payload.toString())),
                                                                      actions: [
                                                                        TextButton(
                                                                            onPressed: () =>
                                                                                Navigator.of(ctx).pop(),
                                                                            child: const Text('Close'))
                                                                      ],
                                                                    ));
                                                    } catch (e) {
                                                      if (mounted)
                                                        Navigator.of(context)
                                                            .pop();
                                                      if (mounted)
                                                        _showSnack(
                                                            'Debug request failed: ${e.toString()}',
                                                            error: true);
                                                    }
                                                  },
                                        child: const Text(''),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    ],
                  ),
                ),
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
            color: Colors.white.withAlpha(
                (0.05 * 255).round()), // Lighter fill like screenshot
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
