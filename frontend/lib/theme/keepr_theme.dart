import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class KeeprTheme {
  static const Color background = Color(0xFF0F1115);
  static const Color surface = Color(0xFF181B21);
  static const Color primary = Color(0xFF6C63FF);
  static const Color accent = Color(0xFF00E5FF);
  static const Color textHigh = Color(0xFFEEEEEE);
  static const Color textMed = Color(0xFFAAAAAA);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      primaryColor: primary,
      brightness: Brightness.dark,

      // Typography
      textTheme: TextTheme(
        displayLarge: GoogleFonts.outfit(
            fontSize: 32, fontWeight: FontWeight.bold, color: textHigh),
        bodyLarge: GoogleFonts.inter(fontSize: 16, color: textHigh),
        bodyMedium: GoogleFonts.inter(fontSize: 14, color: textMed),
      ),

      // Input Decoration (Glassmorphism inspired)
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface.withAlpha((0.5 * 255).round()),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white10),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary),
        ),
        hintStyle: TextStyle(color: Colors.white24),
      ),

      // Button Theme
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.outfit(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
