import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Токены бренда VPNonLine, сведённые 1:1 по присланному HTML-макету
/// (vpnonline-app-mockup-2.html): --bg/--bg-card/--violet/--violet-2/
/// --violet-glow/--violet-dim/--text/--text-dim/--danger/--success,
/// шрифты Orbitron (display) + Inter (текст).
class AppColors {
  static const bg = Color(0xFF050308);
  static const bgCard = Color(0xFF0F0A1C);
  static const border = Color(0xFF241A3D);
  static const violet = Color(0xFF8B5CF6);
  static const violet2 = Color(0xFFA855F7);
  static const violetGlow = Color(0xFFC4B5FD);
  static const violetDim = Color(0xFF4C2F8A);
  static const text = Color(0xFFF3F0FF);
  static const textDim = Color(0xFF9C93C0);
  static const success = Color(0xFF35E0A1);
  static const danger = Color(0xFFFF6B8B);
  static const warning = Color(0xFFF4B740);

  static const LinearGradient violetGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [violet, violet2],
  );

  static List<BoxShadow> glow(Color color, {double blur = 14, double alpha = 0.4}) => [
        BoxShadow(color: color.withOpacity(alpha), blurRadius: blur, spreadRadius: 0.5),
      ];
}

/// Шрифт заголовков/лейблов/цифр — Orbitron, как в макете (лого, статус
/// подключения, суммы, screen-label). Обычный текст остаётся на Inter
/// через основной textTheme темы.
TextStyle orbitron({
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.w700,
  Color color = AppColors.text,
  double? letterSpacing,
}) =>
    GoogleFonts.orbitron(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing ?? 0.5,
    );

ThemeData buildAppTheme() {
  final interTextTheme = GoogleFonts.interTextTheme(ThemeData.dark().textTheme).apply(
    bodyColor: AppColors.text,
    displayColor: AppColors.text,
  );

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.dark(
      primary: AppColors.violet2,
      secondary: AppColors.violetGlow,
      surface: AppColors.bgCard,
      error: AppColors.danger,
    ),
    textTheme: interTextTheme,
    fontFamily: GoogleFonts.inter().fontFamily,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      elevation: 0,
      foregroundColor: AppColors.text,
    ),
    cardTheme: CardThemeData(
      color: AppColors.bgCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF1A1230), thickness: 1),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.violet2,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? AppColors.violet2 : AppColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.violet2.withOpacity(0.35)
            : AppColors.border,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.bgCard,
      indicatorColor: AppColors.violet2.withOpacity(0.18),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 10,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
          color: states.contains(WidgetState.selected) ? AppColors.violet2 : AppColors.textDim,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? AppColors.violet2 : AppColors.textDim,
        ),
      ),
    ),
  );
}
