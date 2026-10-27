import 'package:flutter/material.dart';
import 'shapes.dart';

/// 以内容、可读性及一致的层级为中心的双端设计系统。
class AppTheme {
  static const ink = Color(0xFF282821);
  static const muted = Color(0xFF67675D);
  static const accent = Color(0xFFA84715);
  static const canvas = Color(0xFFF3F1EB);
  static const border = Color(0xFFD6D5CB);
  static const fontFamily = 'StudySans';
  static const fontFallback = [
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Segoe UI Symbol',
    'Segoe UI Emoji',
    'Noto Color Emoji',
    'sans-serif'
  ];

  static ThemeData _base(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final foreground = dark ? const Color(0xFFF3F1EB) : ink;
    final secondary = dark ? const Color(0xFFB7B7AA) : muted;
    final surface = dark ? const Color(0xFF252520) : const Color(0xFFFFFDF8);
    final background = dark ? const Color(0xFF1B1B18) : canvas;
    final line = dark ? const Color(0xFF48483F) : border;
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: dark ? const Color(0xFFF7B17D) : accent,
      surface: surface,
      onSurface: foreground,
      onSurfaceVariant: secondary,
      outline: line,
      outlineVariant: line,
    );
    final text = TextTheme(
      headlineLarge: TextStyle(
          fontSize: 32,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: foreground),
      headlineMedium: TextStyle(
          fontSize: 26,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: foreground),
      titleLarge: TextStyle(
          fontSize: 21,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: foreground),
      titleMedium: TextStyle(
          fontSize: 17,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: foreground),
      bodyLarge: TextStyle(fontSize: 17, height: 1.55, color: foreground),
      bodyMedium: TextStyle(fontSize: 15, height: 1.5, color: foreground),
      bodySmall: TextStyle(fontSize: 13, height: 1.45, color: secondary),
      labelLarge: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, color: foreground),
    ).apply(fontFamily: fontFamily, fontFamilyFallback: fontFallback);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      splashFactory: NoSplash.splashFactory,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      textTheme: text,
      scaffoldBackgroundColor: background,
      dividerColor: line,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: background,
        foregroundColor: foreground,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardTheme(
        color: surface,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape:
            const RoundedRectangleBorder(borderRadius: StudyShapes.cardBorder),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: .6),
      listTileTheme: ListTileThemeData(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          iconColor: scheme.primary),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: const StadiumBorder(),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: BorderSide(color: line),
        shape: const StadiumBorder(),
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: secondary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: StudyShapes.readerBorder,
            borderSide: BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: StudyShapes.readerBorder,
            borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: StudyShapes.readerBorder,
            borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: scheme.primary.withOpacity(.12),
        side: BorderSide.none,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        labelStyle:
            TextStyle(fontFamily: fontFamily, color: foreground, fontSize: 14),
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 76,
        elevation: 0,
        backgroundColor: surface,
        indicatorColor: scheme.primary.withOpacity(.12),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : secondary,
            size: 25)),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : secondary,
            )),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        selectedLabelTextStyle: TextStyle(
            fontFamily: fontFamily,
            color: scheme.primary,
            fontSize: 15,
            fontWeight: FontWeight.w600),
        unselectedLabelTextStyle:
            TextStyle(fontFamily: fontFamily, color: secondary, fontSize: 15),
        indicatorColor: scheme.primary.withOpacity(.12),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(StudyShapes.reader)),
        ),
      ),
    );
  }

  static final lightTheme = _base(Brightness.light);
  static final darkTheme = _base(Brightness.dark);
}
