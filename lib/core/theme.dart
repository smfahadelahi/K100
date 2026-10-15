import 'package:flutter/material.dart';

/// K100's visual language: a deep navy/indigo dark theme with an "aura" accent
/// gradient, generous rounding and low-contrast surfaces so the voice orb is the
/// brightest thing on screen while the learner is speaking.
///
/// Everything is defined here — screens never hard-code a `Color`.
class AppColors {
  AppColors._();

  /// App background (behind every gradient).
  static const Color background = Color(0xFF0B0D14);

  /// Elevated card fill.
  static const Color surface = Color(0xFF141826);

  /// Second-level surface: chips, inline cards, list rows inside a card.
  static const Color surfaceHigh = Color(0xFF1C2133);

  /// Hairline borders / disabled fills.
  static const Color outline = Color(0xFF2A3149);

  /// Primary brand — periwinkle.
  static const Color primary = Color(0xFF7C8CF8);

  /// Secondary — mint. Used for "good" states and the listening pulse.
  static const Color secondary = Color(0xFF4ADE80);

  /// Accent — cyan. Used for the learner's own voice/bubbles.
  static const Color accent = Color(0xFF38BDF8);

  /// Errors, destructive actions, and the "stop speaking" button.
  static const Color danger = Color(0xFFF87171);

  /// Warnings: missing model, low storage, degraded parse.
  static const Color warning = Color(0xFFFBBF24);

  /// Tertiary highlight — warm amber/violet used sparingly (streaks, scores).
  static const Color highlight = Color(0xFFC084FC);

  static const Color textPrimary = Color(0xFFF2F5FF);
  static const Color textSecondary = Color(0xFFA9B2CC);
  static const Color textTertiary = Color(0xFF6B7690);

  /// The signature gradient: violet → indigo. Used for the app icon, the
  /// "primary action" fills and the tutor's own chat bubble.
  static const LinearGradient auraGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF7C8CF8), Color(0xFFC084FC)],
  );

  /// Listening gradient — mint → cyan.
  static const LinearGradient listeningGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF4ADE80), Color(0xFF38BDF8)],
  );

  /// Thinking gradient — indigo → cyan.
  static const LinearGradient thinkingGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF7C8CF8), Color(0xFF38BDF8)],
  );

  /// Speaking gradient — violet → pink.
  static const LinearGradient speakingGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFFC084FC), Color(0xFFF472B6)],
  );

  /// Full-screen backdrop gradient (very subtle, keeps the app from looking flat).
  static const LinearGradient screenGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[Color(0xFF10131F), Color(0xFF0B0D14)],
  );
}

/// `ThemeData` factory plus a few semantic helpers.
class AppTheme {
  AppTheme._();

  /// Backwards-compatible aliases so widgets can read `AppTheme.surface` etc.
  static const Color background = AppColors.background;
  static const Color surface = AppColors.surface;
  static const Color surfaceHigh = AppColors.surfaceHigh;
  static const Color outline = AppColors.outline;
  static const Color primary = AppColors.primary;
  static const Color secondary = AppColors.secondary;
  static const Color accent = AppColors.accent;
  static const Color danger = AppColors.danger;
  static const Color warning = AppColors.warning;
  static const Color textPrimary = AppColors.textPrimary;
  static const Color textSecondary = AppColors.textSecondary;
  static const Color textTertiary = AppColors.textTertiary;
  static const LinearGradient auraGradient = AppColors.auraGradient;
  static const LinearGradient listeningGradient = AppColors.listeningGradient;
  static const LinearGradient thinkingGradient = AppColors.thinkingGradient;
  static const LinearGradient speakingGradient = AppColors.speakingGradient;
  static const LinearGradient screenGradient = AppColors.screenGradient;

  static const double radiusSmall = 10;
  static const double radiusMedium = 16;
  static const double radiusLarge = 22;
  static const double radiusPill = 999;

  /// Colour for a 0-100 fluency score. Red → amber → mint.
  static Color scoreColor(int score) {
    if (score >= 85) return AppColors.secondary;
    if (score >= 70) return AppColors.accent;
    if (score >= 50) return AppColors.warning;
    return AppColors.danger;
  }

  /// Soft tint used behind score pills and grammar cards.
  static Color tint(Color base, [double alpha = 0.14]) =>
      base.withValues(alpha: alpha);

  /// Standard card decoration: rounded, one hairline border, no shadow
  /// (shadows on a dark theme read as muddy).
  static BoxDecoration card({Color? fill, Color? border, double radius = radiusMedium}) =>
      BoxDecoration(
        color: fill ?? AppColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? AppColors.outline, width: 1),
      );

  static ThemeData dark() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: AppColors.primary,
      onPrimary: Color(0xFF0B0D14),
      secondary: AppColors.secondary,
      onSecondary: Color(0xFF0B0D14),
      tertiary: AppColors.accent,
      error: AppColors.danger,
      onError: Color(0xFF0B0D14),
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      surfaceContainerHighest: AppColors.surfaceHigh,
      outline: AppColors.outline,
    );

    final TextTheme base = Typography.material2021().white;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,

      textTheme: base.copyWith(
        displaySmall: base.displaySmall?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineSmall: base.headlineSmall?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleLarge: base.titleLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.bodyLarge?.copyWith(
          color: AppColors.textPrimary,
          height: 1.45,
        ),
        bodyMedium: base.bodyMedium?.copyWith(
          color: AppColors.textPrimary,
          height: 1.45,
        ),
        bodySmall: base.bodySmall?.copyWith(
          color: AppColors.textSecondary,
          height: 1.4,
        ),
        labelLarge: base.labelLarge?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: base.labelSmall?.copyWith(
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: base.titleMedium?.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),

      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
        thickness: 1,
        space: 1,
      ),

      iconTheme: const IconThemeData(color: AppColors.textSecondary),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: const Color(0xFF0B0D14),
          disabledBackgroundColor: AppColors.surfaceHigh,
          disabledForegroundColor: AppColors.textTertiary,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.outline),
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceHigh,
        selectedColor: AppColors.primary,
        side: const BorderSide(color: AppColors.outline),
        labelStyle: base.labelSmall?.copyWith(color: AppColors.textSecondary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusPill)),
      ),

      sliderTheme: const SliderThemeData(
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.surfaceHigh,
        thumbColor: AppColors.textPrimary,
        overlayColor: Color(0x337C8CF8),
        trackHeight: 4,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AppColors.textPrimary
              : AppColors.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : AppColors.surfaceHigh,
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(AppColors.outline),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.surfaceHigh,
        circularTrackColor: AppColors.surfaceHigh,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        hintStyle: const TextStyle(color: AppColors.textTertiary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: AppColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: const TextStyle(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
      ),

      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        textStyle: TextStyle(color: AppColors.textPrimary, fontSize: 12),
      ),
    );
  }
}
