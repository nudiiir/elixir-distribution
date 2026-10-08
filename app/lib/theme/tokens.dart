import 'package:flutter/material.dart';

/// Elixir design tokens — matches the Elixir website and the mobile app:
/// cream/warm neutrals, ink, mint accent, IBM Plex Mono for numbers & codes.
abstract final class T {
  // Surfaces
  static const bg = Color(0xFFF6F7F6); // screen background
  static const cream = Color(0xFFF0EFE9); // page cream
  static const surface = Colors.white;

  // Ink
  static const ink = Color(0xFF0F1113);
  static const ink2 = Color(0xFF141414);
  // Readability first: every text colour passes 4.5:1 on white except
  // `ghost`, kept for placeholders and disabled items only.
  static const muted = Color(0xFF4D5452);
  static const faint = Color(0xFF666E6B);
  static const ghost = Color(0xFF9AA19E);

  // Borders
  static const border = Color(0xFFE9E8E4);
  static const border2 = Color(0xFFECEAE4);
  static const border3 = Color(0xFFE4E2DC);

  // Brand
  static const mint = Color(0xFF00CC99);
  static const mintDeep = Color(0xFF00A87C);
  static const mintDark = Color(0xFF00795C);
  static const mintTint = Color(0x1400CC99);
  static const mintTint2 = Color(0x2800CC99);

  // Status
  static const warn = Color(0xFFE0A020);
  static const warnDark = Color(0xFFA3661F);
  static const warnTint = Color(0x14E0A020);
  static const danger = Color(0xFFE5484D);
  static const dangerDark = Color(0xFFC0393E);
  static const dangerTint = Color(0x14E5484D);

  // Radii
  static const rCard = 14.0;
  static const rInner = 10.0;
  static const rChip = 7.0;

  static const sans = 'PlusJakartaSans';
  static const mono = 'IBMPlexMono';

  // ---- Text styles ----
  // Minimum readable sizes on screen: body 14.5, secondary 13, labels 13.
  // Never go below 12 in the UI (print/PDF code has its own sizes).
  static const h1 = TextStyle(
      fontFamily: sans, fontSize: 24, fontWeight: FontWeight.w800,
      color: ink, height: 1.15, letterSpacing: -0.4);
  static const h2 = TextStyle(
      fontFamily: sans, fontSize: 17, fontWeight: FontWeight.w700,
      color: ink, letterSpacing: -0.2);
  static const body = TextStyle(
      fontFamily: sans, fontSize: 14.5, fontWeight: FontWeight.w500,
      color: ink, height: 1.35);
  static const bodyMuted = TextStyle(
      fontFamily: sans, fontSize: 14, fontWeight: FontWeight.w500,
      color: muted, height: 1.35);
  static const small = TextStyle(
      fontFamily: sans, fontSize: 13, fontWeight: FontWeight.w500,
      color: faint);

  /// Field / column / section label: plain words, normal case, readable.
  static const label = TextStyle(
      fontFamily: sans, fontSize: 13, fontWeight: FontWeight.w600,
      color: muted, letterSpacing: 0);

  /// Money & codes.
  static const monoBig = TextStyle(
      fontFamily: mono, fontSize: 26, fontWeight: FontWeight.w600,
      color: ink, letterSpacing: -0.5);
  static const monoBody = TextStyle(
      fontFamily: mono, fontSize: 14, fontWeight: FontWeight.w500, color: ink);
  static const monoSmall = TextStyle(
      fontFamily: mono, fontSize: 13, fontWeight: FontWeight.w400,
      color: muted);

  static ThemeData theme() => ThemeData(
        useMaterial3: true,
        fontFamily: sans,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: mint,
          primary: mint,
          surface: bg,
        ),
        splashFactory: InkSparkle.splashFactory,
        dividerTheme: const DividerThemeData(color: border, thickness: 1, space: 1),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
              fontFamily: sans, fontSize: 13, color: Colors.white),
        ),
      );
}

/// Formats centimes as "12 345,50 DA".
String fmtDA(int centimes) {
  final neg = centimes < 0;
  final v = centimes.abs();
  final units = v ~/ 100;
  final cents = v % 100;
  final s = units.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return '${neg ? '-' : ''}$buf,${cents.toString().padLeft(2, '0')} DA';
}

/// Formats milli-quantities: 3000 -> "3", 1475 -> "1,475".
String fmtQty(int qtyMilli) {
  final neg = qtyMilli < 0;
  final v = qtyMilli.abs();
  final units = v ~/ 1000;
  final frac = v % 1000;
  final base = neg ? '-$units' : '$units';
  if (frac == 0) return base;
  var f = frac.toString().padLeft(3, '0');
  while (f.endsWith('0')) {
    f = f.substring(0, f.length - 1);
  }
  return '$base,$f';
}

/// Integer division with half-up rounding — mirror of the server's roundDiv.
int roundDiv(int n, int d) {
  if (d == 0) return 0;
  if (n >= 0) return (n + d ~/ 2) ~/ d;
  return -((-n + d ~/ 2) ~/ d);
}

/// Droit de timbre de quittance — mirror of the server's domain.Timbre:
/// nothing up to 300 DA, then per started 100 DA tranche 1 DA (≤ 30 000 DA),
/// 1,5 DA (≤ 100 000 DA) or 2 DA beyond, whole DA, floor 5 DA, ceiling 10 000 DA.
int timbreFor(int totalTTC) {
  if (totalTTC <= 30000) return 0;
  final rate = totalTTC > 10000000 ? 200 : (totalTTC > 3000000 ? 150 : 100);
  var t = ((totalTTC + 9999) ~/ 10000) * rate;
  t = ((t + 99) ~/ 100) * 100;
  if (t < 500) t = 500;
  if (t > 1000000) t = 1000000;
  return t;
}

/// Parses a DA amount ("649,44" / "649.44" / "1 200") to centimes. Null if invalid.
int? parseDA(String input) {
  final s = input.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null) return null;
  return (v * 100).round();
}

/// Parses a quantity ("3" / "1,475") to milli-units. Null if invalid.
int? parseQty(String input) {
  final s = input.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null) return null;
  return (v * 1000).round();
}

/// Formats centimes as a plain editable value ("649,44" — no unit, no grouping).
String editDA(int centimes) {
  final units = centimes ~/ 100;
  final cents = centimes % 100;
  return cents == 0 ? '$units' : '$units,${cents.toString().padLeft(2, '0')}';
}
