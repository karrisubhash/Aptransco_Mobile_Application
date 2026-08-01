import 'package:flutter/material.dart';

import 'li_style.dart';

/// The application-wide theme for the line-inspection platform.
///
/// This is the single source of truth for how core Material widgets look —
/// buttons, inputs, cards, chips, dialogs, the app bar and tab bar — so every
/// screen inherits one consistent, enterprise-grade visual language instead of
/// styling itself ad hoc.
ThemeData buildLiTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrandPrimary,
    brightness: Brightness.light,
  ).copyWith(
    primary: kBrandPrimary,
    onPrimary: Colors.white,
    secondary: kBrandAccent,
    onSecondary: Colors.white,
    surface: kCardBg,
    onSurface: kInk,
    error: kCritColor['critical'],
    outlineVariant: kOutline,
  );

  final baseText = Typography.blackMountainView;

  final textTheme = baseText
      .copyWith(
        displaySmall: baseText.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: kInk,
          letterSpacing: -0.5,
        ),
        headlineSmall: baseText.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: kInk,
          letterSpacing: -0.2,
        ),
        titleLarge: baseText.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: kInk,
          letterSpacing: -0.1,
        ),
        titleMedium: baseText.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: kInk,
        ),
        titleSmall: baseText.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: kInk,
        ),
        bodyLarge: baseText.bodyLarge?.copyWith(color: kInk, height: 1.4),
        bodyMedium: baseText.bodyMedium?.copyWith(color: kInk, height: 1.4),
        bodySmall: baseText.bodySmall?.copyWith(color: kInkSoft, height: 1.35),
        labelLarge: baseText.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      )
      .apply(fontFamily: 'Roboto');

  OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kSurface,
    canvasColor: kSurface,
    textTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,

    appBarTheme: const AppBarTheme(
      backgroundColor: kCardBg,
      foregroundColor: kInk,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: kOutline)),
      titleTextStyle: TextStyle(
        color: kInk,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      iconTheme: IconThemeData(color: kInk),
    ),

    cardTheme: CardThemeData(
      color: kCardBg,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shadowColor: kBrandPrimaryDark.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusLg),
        side: const BorderSide(color: kOutline),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kCardBg,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: const TextStyle(color: kInkFaint),
      labelStyle: const TextStyle(color: kInkSoft),
      prefixIconColor: kInkFaint,
      border: inputBorder(kOutline),
      enabledBorder: inputBorder(kOutline),
      focusedBorder: inputBorder(kBrandAccent, 1.6),
      errorBorder: inputBorder(kCritColor['critical']!),
      focusedErrorBorder: inputBorder(kCritColor['critical']!, 1.6),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kBrandPrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
          letterSpacing: 0.2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
      ),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kBrandPrimary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kBrandPrimary,
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        side: const BorderSide(color: kOutline, width: 1.4),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kBrandAccent,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: kCardBg,
      selectedColor: kBrandAccent.withValues(alpha: 0.14),
      checkmarkColor: kBrandPrimary,
      secondarySelectedColor: kBrandAccent.withValues(alpha: 0.14),
      labelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: kInk,
      ),
      secondaryLabelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: kBrandPrimary,
      ),
      side: const BorderSide(color: kOutline),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return kBrandPrimary;
          }
          return kCardBg;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return kInkSoft;
        }),
        side: const WidgetStatePropertyAll(BorderSide(color: kOutline)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusMd),
          ),
        ),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: kOutline,
      thickness: 1,
      space: 1,
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white70,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      unselectedLabelStyle: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
      ),
      indicator: const UnderlineTabIndicator(
        borderSide: BorderSide(color: Colors.white, width: 2.5),
        insets: EdgeInsets.symmetric(horizontal: 8),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: kCardBg,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusLg),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: kInk,
      ),
      contentTextStyle: const TextStyle(fontSize: 14, color: kInk, height: 1.4),
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: kCardBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusXl)),
      ),
      showDragHandle: true,
      dragHandleColor: kOutline,
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: kInk,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
      actionTextColor: kBlue100,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
    ),

    listTileTheme: const ListTileThemeData(
      iconColor: kInkSoft,
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: kInk,
      ),
      subtitleTextStyle: TextStyle(fontSize: 13, color: kInkSoft),
    ),

    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: kCardBg,
        border: inputBorder(kOutline),
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: kBrandAccent,
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: kBrandPrimary,
      foregroundColor: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusLg),
      ),
    ),

    iconTheme: const IconThemeData(color: kInkSoft),
  );
}
