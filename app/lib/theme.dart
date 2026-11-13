import 'package:flutter/material.dart';

/// 取自桌面版设计变量（:root / .theme-dark）
class Hg {
  const Hg._();

  static const bg = Color(0xFF0E0E12);
  static const bg1 = Color(0xFF15151B);
  static const bg2 = Color(0xFF1C1C24);
  static const bg3 = Color(0xFF24242E);
  static const bg4 = Color(0xFF2E2E3A);
  static const line = Color(0xFF2B2B36);
  static const line2 = Color(0xFF3A3A48);

  static const text = Color(0xFFE9E9F0);
  static const text2 = Color(0xFFA2A2B2);
  static const text3 = Color(0xFF6D6D7C);

  static const brand = Color(0xFFFF3B5C);
  static const brand2 = Color(0xFFFF6F85);
  static const brandDim = Color(0x24FF3B5C);

  /// 「剧」字图标底色（蓝色），只用于 logo 方块，不参与点赞/进度等红色语义
  static const logo = Color(0xFF2B5CF0);
  static const logo2 = Color(0xFF3F7BFF);

  static const ok = Color(0xFF3DDC97);
  static const warn = Color(0xFFFFB020);
  static const likeOn = Color(0xFFFE2C55);
  static const favOn = Color(0xFFFFC300);

  static const radius = 10.0;
  static const radiusLg = 14.0;

  /// 播放页遮罩：rgba(16,16,22,.94) + blur
  static const panel = Color(0xF0101016);

  static ThemeData theme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    colorScheme: const ColorScheme.dark(
      primary: brand,
      secondary: brand2,
      surface: bg1,
      onSurface: text,
    ),
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme().apply(bodyColor: text, displayColor: text),
  );
}
