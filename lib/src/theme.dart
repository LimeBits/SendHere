import 'package:flutter/material.dart';

/// Design tokens from Docs/UI改版设计稿_v0.4.html.
///
/// The palette follows the NoteHere UI 规范 v0.15 approach: a grey-white paper
/// background, white cards, grey chips, hairline dividers, and exactly one
/// highlighted control per screen. The accent is "现代蓝" rather than the old
/// Material indigo, which read as purple-grey and dated.
class SendHereColors {
  const SendHereColors._();

  /// Page background.
  static const paper = Color(0xFFF9F9F9);

  /// Cards, input fields.
  static const card = Color(0xFFFFFFFF);

  /// Unselected chips, icon backgrounds, received bubbles, disabled fills.
  static const chip = Color(0xFFF0F0F0);

  /// Hairline dividers and card borders, drawn at 0.5 logical pixels.
  static const line = Color(0xFFEBEBEB);

  /// Primary text, and fills that must read as "ink" rather than accent.
  static const ink = Color(0xFF111111);

  /// Text on top of [ink].
  static const onInk = Color(0xFFFFFFFF);

  /// Secondary text: timestamps, status lines, section labels.
  static const sub = Color(0xFF6B6B70);

  /// Filled accent: the single highlighted control on a screen (send button).
  static const brand = Color(0xFF2563EB);

  /// Pressed state for [brand] fills.
  static const brandPressed = Color(0xFF1D4FD7);

  /// Soft accent: own message bubbles, selected rows, device icon backgrounds.
  static const brandSoft = Color(0xFFE8EFFD);

  /// Accent text and icons. One step darker than [brand] because the same blue
  /// that works as a button fill lacks contrast at 11-12 pt on white.
  static const brandText = Color(0xFF1D4FD7);

  /// Text and icons on top of [brand].
  static const onBrand = Color(0xFFFFFFFF);

  /// Unread badges. Reserved for "needs your attention right now".
  static const unread = Color(0xFFFF4F32);

  /// Warnings: paused, processing, unreachable.
  static const warn = Color(0xFFE8890C);

  /// Online indicator. Informational, not a control, so green is allowed here.
  static const online = Color(0xFF34A853);
}

/// Corner radii, from the design doc's 4.2 table.
class SendHereRadius {
  const SendHereRadius._();

  /// Cards.
  static const card = 16.0;

  /// Message bubbles, except the corner facing the sender.
  static const bubble = 14.0;

  /// The bubble corner on the sender's own side.
  static const bubbleTail = 5.0;

  /// Desktop composer box, footer buttons.
  static const box = 14.0;

  /// Selected rows, inline selectors, image thumbnails in bubbles.
  static const small = 12.0;

  /// Thumbnails inside bubbles.
  static const thumb = 8.0;
}

/// The app-wide [ThemeData]. Material 3 derives most roles from a seed, which
/// previously tinted every surface with indigo's purple-grey. Seeding from
/// [SendHereColors.brand] and overriding the surface roles keeps cards and
/// bubbles neutral.
ThemeData sendHereTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: SendHereColors.brand,
    primary: SendHereColors.brand,
    onPrimary: SendHereColors.onBrand,
    primaryContainer: SendHereColors.brandSoft,
    onPrimaryContainer: SendHereColors.ink,
    secondaryContainer: SendHereColors.brandSoft,
    onSecondaryContainer: SendHereColors.brandText,
    surface: SendHereColors.card,
    onSurface: SendHereColors.ink,
    surfaceContainerHighest: SendHereColors.chip,
    onSurfaceVariant: SendHereColors.sub,
    outlineVariant: SendHereColors.line,
    error: const Color(0xFFD92D20),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: SendHereColors.paper,
    // Material 3 tints elevated surfaces with the primary colour. The design
    // calls for plain white cards, so the tint is switched off globally.
    cardTheme: const CardThemeData(
      color: SendHereColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(SendHereRadius.card)),
        side: BorderSide(color: SendHereColors.line, width: 0.5),
      ),
      margin: EdgeInsets.zero,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: SendHereColors.card,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: SendHereColors.card,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: SendHereColors.card,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(
      color: SendHereColors.line,
      thickness: 0.5,
      space: 0.5,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: SendHereColors.paper,
      surfaceTintColor: Colors.transparent,
      foregroundColor: SendHereColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
    ),
    textTheme: const TextTheme(
      // Timestamps and delivery status under each bubble.
      bodySmall: TextStyle(fontSize: 11, color: SendHereColors.sub),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SendHereColors.brand,
        foregroundColor: SendHereColors.onBrand,
        disabledBackgroundColor: SendHereColors.chip,
        disabledForegroundColor: SendHereColors.sub,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SendHereColors.ink,
        side: const BorderSide(color: SendHereColors.line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SendHereRadius.box),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: SendHereColors.brandText),
    ),
    listTileTheme: const ListTileThemeData(
      selectedTileColor: SendHereColors.brandSoft,
      selectedColor: SendHereColors.ink,
    ),
  );
}
