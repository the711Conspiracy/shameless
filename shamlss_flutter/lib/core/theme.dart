import 'package:flutter/material.dart';

class ShamlssTheme {
  static const _black = Color(0xFF080B0F);
  static const _navy = Color(0xFF0D1117);
  static const _surface = Color(0xFF141921);
  static const _card = Color(0xFF1A2130);
  static const _amber = Color(0xFFE8A020);
  static const _amberDim = Color(0xFF9B6A14);
  static const _text = Color(0xFFE8E4DC);
  static const _textMuted = Color(0xFF8B8880);
  static const _divider = Color(0xFF232B38);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _black,
        colorScheme: const ColorScheme.dark(
          primary: _amber,
          secondary: _amberDim,
          surface: _surface,
          onPrimary: _black,
          onSurface: _text,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
        appBarTheme: const AppBarTheme(
          backgroundColor: _navy,
          foregroundColor: _text,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: _text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _navy,
          indicatorColor: _amber.withOpacity(0.15),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: _amber, size: 22);
            }
            return const IconThemeData(color: _textMuted, size: 22);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(color: _amber, fontSize: 11, fontWeight: FontWeight.w600);
            }
            return const TextStyle(color: _textMuted, fontSize: 11);
          }),
          height: 64,
        ),
        cardTheme: CardThemeData(
          color: _card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: _divider, width: 1),
          ),
          margin: EdgeInsets.zero,
        ),
        dividerTheme: const DividerThemeData(color: _divider, thickness: 1, space: 1),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: _amber),
          ),
          labelStyle: const TextStyle(color: _textMuted, fontSize: 13),
          hintStyle: const TextStyle(color: _textMuted, fontSize: 13),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _amber,
            foregroundColor: _black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          textColor: _text,
          iconColor: _textMuted,
          tileColor: Colors.transparent,
        ),
        extensions: const [ShamlssColors()],
      );
}

class ShamlssColors extends ThemeExtension<ShamlssColors> {
  const ShamlssColors();
  static const black = Color(0xFF080B0F);
  static const navy = Color(0xFF0D1117);
  static const surface = Color(0xFF141921);
  static const card = Color(0xFF1A2130);
  static const amber = Color(0xFFE8A020);
  static const amberDim = Color(0xFF9B6A14);
  static const text = Color(0xFFE8E4DC);
  static const textMuted = Color(0xFF8B8880);
  static const divider = Color(0xFF232B38);

  @override
  ShamlssColors copyWith() => const ShamlssColors();
  @override
  ShamlssColors lerp(ShamlssColors? other, double t) => const ShamlssColors();
}
