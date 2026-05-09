import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:palette_generator/palette_generator.dart';

// ─── Fixed brand tokens ────────────────────────────────────────────────────

class SleeveTokens {
  SleeveTokens._();

  static const ink   = Color(0xFF13102B);
  static const paper = Color(0xFFF0EEF8);
  static const rust  = Color(0xFFC96442);
  static const online = Color(0xFF3FCB6A);
  static const warn  = Color(0xFFE8A020);
  static const error = Color(0xFFE84A30);
  static const black = Color(0xFF0A0908);
}

// ─── Adaptive tints derived from album art ─────────────────────────────────

class SleeveTints {
  final Color base;
  final Color surface;
  final Color surfaceHi;
  final Color line;
  final Color text;
  final Color textMute;
  final Color textDim;
  final Color accent;
  final Color accentSoft;

  const SleeveTints({
    required this.base,
    required this.surface,
    required this.surfaceHi,
    required this.line,
    required this.text,
    required this.textMute,
    required this.textDim,
    required this.accent,
    required this.accentSoft,
  });

  /// Fallback when no album art is available.
  static const brand = SleeveTints(
    base:       Color(0xFF13102B),
    surface:    Color(0xFF1C1838),
    surfaceHi:  Color(0xFF251F42),
    line:       Color(0x29F0EEF8), // paper @ 16%
    text:       Color(0xFFF0EEF8),
    textMute:   Color(0x99F0EEF8), // 60%
    textDim:    Color(0x52F0EEF8), // 32%
    accent:     Color(0xFFC96442),
    accentSoft: Color(0x47C96442), // 28%
  );

  /// Build adaptive tints from the two most important palette colours.
  factory SleeveTints.from(Color darkBase, Color brightAccent) {
    // Derive surface layers by brightening the dark base slightly.
    final hslBase = HSLColor.fromColor(darkBase);
    final surface = hslBase
        .withLightness((hslBase.lightness + 0.04).clamp(0.0, 1.0))
        .toColor();
    final surfaceHi = hslBase
        .withLightness((hslBase.lightness + 0.09).clamp(0.0, 1.0))
        .toColor();

    const paper = SleeveTokens.paper;
    const paper18 = Color(0x2EF4F1EA);

    // Blend paper toward the base hue slightly for text.
    final text = Color.lerp(paper, surface, 0.05)!;
    final textMute = text.withOpacity(0.60);
    final textDim  = text.withOpacity(0.32);

    final accentSoft = brightAccent.withOpacity(0.28);

    return SleeveTints(
      base:       darkBase,
      surface:    surface,
      surfaceHi:  surfaceHi,
      line:       paper18,
      text:       text,
      textMute:   textMute,
      textDim:    textDim,
      accent:     brightAccent,
      accentSoft: accentSoft,
    );
  }
}

// ─── Palette extraction from art URL ───────────────────────────────────────

Future<SleeveTints> tintsFromUrl(String? url) async {
  if (url == null || url.isEmpty) return SleeveTints.brand;
  try {
    final provider = NetworkImage(url);
    final generator = await PaletteGenerator.fromImageProvider(
      provider,
      maximumColorCount: 16,
    );

    // Choose darkest muted for base.
    final darkMuted = generator.darkMutedColor?.color
        ?? generator.darkVibrantColor?.color
        ?? const Color(0xFF1A1612);

    // Choose brightest vibrant for accent.
    final vibrant = generator.vibrantColor?.color
        ?? generator.lightVibrantColor?.color
        ?? generator.dominantColor?.color
        ?? SleeveTokens.rust;

    return SleeveTints.from(darkMuted, vibrant);
  } catch (_) {
    return SleeveTints.brand;
  }
}

// ─── InheritedWidget provider ──────────────────────────────────────────────

class SleeveTintsProvider extends InheritedWidget {
  final SleeveTints tints;

  const SleeveTintsProvider({
    super.key,
    required this.tints,
    required super.child,
  });

  /// Returns [SleeveTints.brand] when no provider is in the tree —
  /// safe to call from any build method.
  static SleeveTints of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<SleeveTintsProvider>();
    return provider?.tints ?? SleeveTints.brand;
  }

  @override
  bool updateShouldNotify(SleeveTintsProvider old) => tints != old.tints;
}

// ─── ThemeData ─────────────────────────────────────────────────────────────

class ShamlssTheme {
  ShamlssTheme._();

  static ThemeData get theme {
    final tt = GoogleFonts.interTightTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: SleeveTokens.ink,
      colorScheme: const ColorScheme.dark(
        primary:    SleeveTokens.rust,
        secondary:  SleeveTokens.warn,
        surface:    Color(0xFF1C1838),
        onPrimary:  SleeveTokens.paper,
        onSurface:  SleeveTokens.paper,
      ),
      useMaterial3: true,
      textTheme: tt,
      appBarTheme: AppBarTheme(
        backgroundColor: SleeveTokens.ink,
        foregroundColor: SleeveTokens.paper,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.jetBrainsMono(
          color: SleeveTokens.paper,
          fontSize: 11,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.18,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: SleeveTokens.ink,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: SleeveTokens.rust, size: 22);
          }
          return IconThemeData(color: SleeveTokens.paper.withOpacity(0.4), size: 22);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final base = GoogleFonts.jetBrainsMono(
            fontSize: 9,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.18,
          );
          if (states.contains(WidgetState.selected)) {
            return base.copyWith(color: SleeveTokens.rust);
          }
          return base.copyWith(color: SleeveTokens.paper.withOpacity(0.32));
        }),
        height: 64,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF1C1838),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(0),
          side: BorderSide(color: SleeveTokens.paper.withOpacity(0.18), width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: SleeveTokens.paper.withOpacity(0.18),
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1C1838),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: SleeveTokens.paper.withOpacity(0.18)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: SleeveTokens.paper.withOpacity(0.18)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: SleeveTokens.rust),
        ),
        labelStyle: TextStyle(color: SleeveTokens.paper.withOpacity(0.60), fontSize: 13),
        hintStyle: TextStyle(color: SleeveTokens.paper.withOpacity(0.60), fontSize: 13),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: SleeveTokens.rust,
          foregroundColor: SleeveTokens.paper,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.jetBrainsMono(fontWeight: FontWeight.w500, letterSpacing: 0.05),
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: SleeveTokens.paper,
        iconColor: SleeveTokens.paper.withOpacity(0.60),
        tileColor: Colors.transparent,
      ),
      extensions: const [ShamlssColors()],
    );
  }
}

// ─── ShamlssColors — backward-compat shim (other screens reference these) ──

class ShamlssColors extends ThemeExtension<ShamlssColors> {
  const ShamlssColors();

  // Keep names that existing screens use, mapped to new tokens.
  static const black     = SleeveTokens.black;
  static const navy      = Color(0xFF13102B);         // ink
  static const surface   = Color(0xFF1C1838);
  static const card      = Color(0xFF2A2420);
  static const amber     = SleeveTokens.rust;         // primary accent
  static const amberDim  = Color(0xFF8A4430);         // rust dimmed
  static const text      = SleeveTokens.paper;
  static const textMuted = Color(0x99F4F1EA);         // paper @ 60%
  static const divider   = Color(0x2EF4F1EA);         // paper @ 18%

  @override
  ShamlssColors copyWith() => const ShamlssColors();
  @override
  ShamlssColors lerp(ShamlssColors? other, double t) => const ShamlssColors();
}
