import 'package:flutter/material.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'theme/keepr_theme.dart';
import 'services/folder_upload_service.dart';
import 'services/api_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/file_manager_screen.dart';
import 'screens/login_screen.dart';
import 'screens/pin_entry_screen.dart';

// Entry Point
void main() {
  runApp(const KeeprApp());
}

class KeeprApp extends StatelessWidget {
  const KeeprApp({super.key});

  Future<Widget> _initialScreen() async {
    // Check for stored user email - if present, show PIN entry to unlock session
    final storage = const FlutterSecureStorage();
    final email = await storage.read(key: 'user_email');

    final api = ApiService.forEnv();
    final uploader = FolderUploadService(
        backendUrl: const String.fromEnvironment('BACKEND_BASE',
            defaultValue: 'http://localhost:3000'));

    if (email != null) {
      return PinEntryScreen(api: api, uploader: uploader);
    }
    return const LoginScreen();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Keepr',
      debugShowCheckedModeBanner: false,
      theme: KeeprTheme.darkTheme,
      home: FutureBuilder<Widget>(
        future: _initialScreen(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return snapshot.data ?? const LoginScreen();
        },
      ),
      routes: {
        '/login': (ctx) => const LoginScreen(),
      },
    );
  }
}

// Keeping WelcomeScreen for now but unused as main route
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController otpController = TextEditingController();
  bool isOtpSent = false;
  bool isLoading = false;

  // NOTE: In production, use env variables
  final uploadService =
      FolderUploadService(backendUrl: 'http://localhost:3000');
  // API client for auth
  late final ApiService api;

  @override
  void initState() {
    super.initState();
    api = ApiService(backendBase: 'http://localhost:3000');
  }

  void _showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message), backgroundColor: error ? Colors.red : null));
  }

  Future<void> _sendOtp() async {
    final email = emailController.text.trim();
    if (email.isEmpty) return _showSnack('Please enter an email', error: true);
    setState(() {
      isLoading = true;
    });
    try {
      final ok = await api.sendOtp(email);
      if (ok) {
        setState(() {
          isOtpSent = true;
        });
        _showSnack('OTP sent to $email');
      } else {
        _showSnack('Failed to send OTP', error: true);
      }
    } catch (e) {
      _showSnack('Network error', error: true);
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _verifyOtp() async {
    final email = emailController.text.trim();
    final otp = otpController.text.trim();
    if (otp.isEmpty) return _showSnack('Enter OTP', error: true);
    setState(() {
      isLoading = true;
    });
    try {
      final token = await api.verifyOtp(email, otp);
      if (token != null) {
        // Persist token and user email so session unlocks via PIN on refresh
        final storage = const FlutterSecureStorage();
        await storage.write(key: 'auth_token', value: token);
        await storage.write(key: 'user_email', value: email);

        _showSnack('Login successful');
        // Navigate to File Manager
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (ctx) => FileManagerScreen(
                  userId: email,
                  api: api,
                  uploader: uploadService,
                )));
      } else {
        _showSnack('Invalid OTP', error: true);
      }
    } catch (e) {
      _showSnack('Network error', error: true);
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F1115), Color(0xFF1F1535)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // Content
          Center(
            child: GlassmorphicContainer(
              width: 400,
              height: 500,
              borderRadius: 20,
              blur: 20,
              alignment: Alignment.center,
              border: 2,
              linearGradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withAlpha((0.1 * 255).round()),
                  Colors.white.withAlpha((0.05 * 255).round()),
                ],
                stops: [0.1, 1],
              ),
              borderGradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.5),
                  Colors.white.withOpacity(0.5),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      "Keepr.",
                      style: Theme.of(context).textTheme.displayLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Zero-Cost Distributed Cloud",
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 48),
                    if (!isOtpSent) ...[
                      TextField(
                        controller: emailController,
                        decoration: InputDecoration(
                          hintText: "Enter Email",
                          prefixIcon:
                              Icon(Icons.email_outlined, color: Colors.white54),
                        ),
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: isLoading ? null : _sendOtp,
                        child: isLoading
                            ? SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text("Start Session"),
                      ),
                    ] else ...[
                      TextField(
                        controller: otpController,
                        decoration: InputDecoration(
                          hintText: "Enter OTP",
                          prefixIcon:
                              Icon(Icons.lock_outline, color: Colors.white54),
                        ),
                        style: TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: isLoading ? null : _verifyOtp,
                        child: isLoading
                            ? SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : Text("Connect to Mesh"),
                      ),
                      TextButton(
                        onPressed: () => setState(() => isOtpSent = false),
                        child: Text("Back"),
                      )
                    ]
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
