import 'package:flutter/material.dart';

class InfernoThemes {
  /// Bundled emoji font ensures consistent rendering across all platforms.
  static const _emojiFallback = ['NotoColorEmoji'];

  static ThemeData inferno() => _buildTheme(
    primary: const Color(0xFFDC2626),
    primaryLight: const Color(0xFFF87171),
    primaryDark: const Color(0xFFB91C1C),
    gray950: const Color(0xFF0A0A09),
    gray900: const Color(0xFF141312),
    gray800: const Color(0xFF1E1C1B),
    gray700: const Color(0xFF2C2A29),
    gray600: const Color(0xFF403E3C),
    gray500: const Color(0xFF656361),
    gray400: const Color(0xFF878583),
    gray200: const Color(0xFFCCCBCA),
    gray50: const Color(0xFFF3F3F2),
  );

  static ThemeData frostfire() => _buildTheme(
    primary: const Color(0xFF2563EB),
    primaryLight: const Color(0xFF60A5FA),
    primaryDark: const Color(0xFF1D4ED8),
    gray950: const Color(0xFF0A0D14),
    gray900: const Color(0xFF111827),
    gray800: const Color(0xFF1F2937),
    gray700: const Color(0xFF374151),
    gray600: const Color(0xFF4B5563),
    gray500: const Color(0xFF6B7280),
    gray400: const Color(0xFF9CA3AF),
    gray200: const Color(0xFFD1D5DB),
    gray50: const Color(0xFFF9FAFB),
  );

  static ThemeData boron() => _buildTheme(
    primary: const Color(0xFF059669),
    primaryLight: const Color(0xFF34D399),
    primaryDark: const Color(0xFF047857),
    gray950: const Color(0xFF062014),
    gray900: const Color(0xFF0C2E1C),
    gray800: const Color(0xFF143D28),
    gray700: const Color(0xFF1E4D38),
    gray600: const Color(0xFF2A5D48),
    gray500: const Color(0xFF4D7A67),
    gray400: const Color(0xFF6B9A84),
    gray200: const Color(0xFFB0D0C0),
    gray50: const Color(0xFFE8F5EE),
  );

  static ThemeData brimstone() => _buildTheme(
    primary: const Color(0xFF7C3AED),
    primaryLight: const Color(0xFFA78BFA),
    primaryDark: const Color(0xFF6D28D9),
    gray950: const Color(0xFF0A0814),
    gray900: const Color(0xFF140F20),
    gray800: const Color(0xFF1E182C),
    gray700: const Color(0xFF2C2440),
    gray600: const Color(0xFF3C3354),
    gray500: const Color(0xFF5C5174),
    gray400: const Color(0xFF7C7094),
    gray200: const Color(0xFFBCB4D0),
    gray50: const Color(0xFFF0ECF8),
  );

  static ThemeData plasma() => _buildTheme(
    primary: const Color(0xFFDB2777),
    primaryLight: const Color(0xFFF472B6),
    primaryDark: const Color(0xFFBE185D),
    gray950: const Color(0xFF140A10),
    gray900: const Color(0xFF1E1018),
    gray800: const Color(0xFF2C1A24),
    gray700: const Color(0xFF3C2834),
    gray600: const Color(0xFF4C3644),
    gray500: const Color(0xFF6C5464),
    gray400: const Color(0xFF8C7484),
    gray200: const Color(0xFFCCB8C4),
    gray50: const Color(0xFFF8ECF4),
  );

  static ThemeData pulsar() => _buildTheme(
    primary: const Color(0xFFF59E0B),
    primaryLight: const Color(0xFFFBBF24),
    primaryDark: const Color(0xFFD97706),
    gray950: const Color(0xFF0A0A06),
    gray900: const Color(0xFF141310),
    gray800: const Color(0xFF1E1C18),
    gray700: const Color(0xFF2C2A24),
    gray600: const Color(0xFF403E36),
    gray500: const Color(0xFF656350),
    gray400: const Color(0xFF878570),
    gray200: const Color(0xFFCCCBB8),
    gray50: const Color(0xFFF3F3E8),
  );

  static ThemeData obsidian() => _buildTheme(
    primary: const Color(0xFF9CA3AF),
    primaryLight: const Color(0xFFD1D5DB),
    primaryDark: const Color(0xFF6B7280),
    gray950: const Color(0xFF0A0A0A),
    gray900: const Color(0xFF141414),
    gray800: const Color(0xFF1E1E1E),
    gray700: const Color(0xFF2C2C2C),
    gray600: const Color(0xFF404040),
    gray500: const Color(0xFF656565),
    gray400: const Color(0xFF878787),
    gray200: const Color(0xFFCCCCCC),
    gray50: const Color(0xFFF3F3F3),
  );

  static ThemeData _buildTheme({
    required Color primary,
    required Color primaryLight,
    required Color primaryDark,
    required Color gray950,
    required Color gray900,
    required Color gray800,
    required Color gray700,
    required Color gray600,
    required Color gray500,
    required Color gray400,
    required Color gray200,
    required Color gray50,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      fontFamilyFallback: const ['NotoColorEmoji'],
      colorScheme: ColorScheme.dark(
        primary: primary,
        primaryContainer: primaryDark,
        secondary: primaryLight,
        surface: gray700,
        surfaceContainerHighest: gray800,
        surfaceContainerLow: gray600,
        error: const Color(0xFFDC2626),
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: gray200,
        onError: Colors.white,
        outline: gray900,
        outlineVariant: gray800,
      ),
      scaffoldBackgroundColor: gray700,
      appBarTheme: AppBarTheme(
        backgroundColor: gray700,
        foregroundColor: gray50,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(color: gray800, elevation: 0),
      dividerTheme: DividerThemeData(color: gray900, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: gray600,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        hintStyle: TextStyle(color: gray500),
        labelStyle: TextStyle(color: gray400),
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: gray200, fontSize: 15, fontFamilyFallback: _emojiFallback),
        bodyMedium: TextStyle(color: gray200, fontSize: 14, fontFamilyFallback: _emojiFallback),
        bodySmall: TextStyle(color: gray500, fontSize: 12, fontFamilyFallback: _emojiFallback),
        titleLarge: TextStyle(color: gray50, fontWeight: FontWeight.bold, fontSize: 20, fontFamilyFallback: _emojiFallback),
        titleMedium: TextStyle(color: gray50, fontWeight: FontWeight.w600, fontSize: 16, fontFamilyFallback: _emojiFallback),
        titleSmall: TextStyle(color: gray50, fontWeight: FontWeight.w600, fontSize: 14, fontFamilyFallback: _emojiFallback),
        labelLarge: TextStyle(color: gray400, fontSize: 12, fontWeight: FontWeight.w600, fontFamilyFallback: _emojiFallback),
        labelSmall: TextStyle(color: gray500, fontSize: 11, fontFamilyFallback: _emojiFallback),
      ),
      iconTheme: IconThemeData(color: gray400, size: 20),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: gray200,
          side: BorderSide(color: gray600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: gray800,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: gray800,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: gray800,
        contentTextStyle: TextStyle(color: gray200),
      ),
      listTileTheme: ListTileThemeData(
        textColor: gray200,
        iconColor: gray400,
      ),
      extensions: [
        InfernoColors(
          gray950: gray950,
          gray900: gray900,
          gray800: gray800,
          gray700: gray700,
          gray600: gray600,
          gray500: gray500,
          gray400: gray400,
          gray200: gray200,
          gray50: gray50,
          accent: primary,
          accentLight: primaryLight,
          accentDark: primaryDark,
          online: const Color(0xFF16A34A),
          idle: const Color(0xFFEAB308),
          dnd: const Color(0xFFDC2626),
          offline: const Color(0xFF656361),
        ),
      ],
    );
  }

  static final Map<String, ThemeData> _cache = {};

  static ThemeData forName(String name) {
    return _cache.putIfAbsent(name, () {
      switch (name) {
        case 'frostfire': return frostfire();
        case 'boron': return boron();
        case 'brimstone': return brimstone();
        case 'plasma': return plasma();
        case 'pulsar': return pulsar();
        case 'obsidian': return obsidian();
        default: return inferno();
      }
    });
  }

  /// Returns just the InfernoColors for a theme name — used by infernoColorsProvider.
  static final Map<String, InfernoColors> _colorsCache = {};

  static InfernoColors colorsForName(String name) {
    return _colorsCache.putIfAbsent(name, () {
      return forName(name).extension<InfernoColors>()!;
    });
  }

  static const themeNames = ['inferno', 'frostfire', 'boron', 'brimstone', 'plasma', 'pulsar', 'obsidian'];

  static Color primaryColorForName(String name) {
    switch (name) {
      case 'frostfire': return const Color(0xFF2563EB);
      case 'boron': return const Color(0xFF059669);
      case 'brimstone': return const Color(0xFF7C3AED);
      case 'plasma': return const Color(0xFFDB2777);
      case 'pulsar': return const Color(0xFFF59E0B);
      case 'obsidian': return const Color(0xFF9CA3AF);
      default: return const Color(0xFFDC2626);
    }
  }
}

/// Custom theme extension for accessing the full gray palette
class InfernoColors extends ThemeExtension<InfernoColors> {
  final Color gray950, gray900, gray800, gray700, gray600, gray500, gray400, gray200, gray50;
  final Color accent, accentLight, accentDark;
  final Color online, idle, dnd, offline;

  const InfernoColors({
    required this.gray950, required this.gray900, required this.gray800,
    required this.gray700, required this.gray600, required this.gray500,
    required this.gray400, required this.gray200, required this.gray50,
    required this.accent, required this.accentLight, required this.accentDark,
    required this.online, required this.idle, required this.dnd, required this.offline,
  });

  @override
  InfernoColors copyWith({
    Color? gray950, Color? gray900, Color? gray800, Color? gray700, Color? gray600,
    Color? gray500, Color? gray400, Color? gray200, Color? gray50,
    Color? accent, Color? accentLight, Color? accentDark,
    Color? online, Color? idle, Color? dnd, Color? offline,
  }) {
    return InfernoColors(
      gray950: gray950 ?? this.gray950, gray900: gray900 ?? this.gray900,
      gray800: gray800 ?? this.gray800, gray700: gray700 ?? this.gray700,
      gray600: gray600 ?? this.gray600, gray500: gray500 ?? this.gray500,
      gray400: gray400 ?? this.gray400, gray200: gray200 ?? this.gray200,
      gray50: gray50 ?? this.gray50, accent: accent ?? this.accent,
      accentLight: accentLight ?? this.accentLight, accentDark: accentDark ?? this.accentDark,
      online: online ?? this.online, idle: idle ?? this.idle,
      dnd: dnd ?? this.dnd, offline: offline ?? this.offline,
    );
  }

  @override
  InfernoColors lerp(ThemeExtension<InfernoColors>? other, double t) {
    if (other is! InfernoColors) return this;
    return InfernoColors(
      gray950: Color.lerp(gray950, other.gray950, t)!, gray900: Color.lerp(gray900, other.gray900, t)!,
      gray800: Color.lerp(gray800, other.gray800, t)!, gray700: Color.lerp(gray700, other.gray700, t)!,
      gray600: Color.lerp(gray600, other.gray600, t)!, gray500: Color.lerp(gray500, other.gray500, t)!,
      gray400: Color.lerp(gray400, other.gray400, t)!, gray200: Color.lerp(gray200, other.gray200, t)!,
      gray50: Color.lerp(gray50, other.gray50, t)!, accent: Color.lerp(accent, other.accent, t)!,
      accentLight: Color.lerp(accentLight, other.accentLight, t)!, accentDark: Color.lerp(accentDark, other.accentDark, t)!,
      online: Color.lerp(online, other.online, t)!, idle: Color.lerp(idle, other.idle, t)!,
      dnd: Color.lerp(dnd, other.dnd, t)!, offline: Color.lerp(offline, other.offline, t)!,
    );
  }
}
