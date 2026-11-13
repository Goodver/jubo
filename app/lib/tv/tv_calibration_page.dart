// 剧播 TV · 全屏边缘校准（2026-11-08）
//
// 用户反馈「首页背景四边没触边」。adb screencap 取到的是 framebuffer，
// 电视自身的画面比例 / 缩放 / 过扫描造成的物理黑边不会出现在截图里，
// 光看代码和截图分不清是 App 没画满还是电视 scaler 缩小了整个画面。
// 这页把贴边红线和四角 L 标记画在 App 画面的最外 1 像素，现场一眼定性：
//   红线贴屏幕边 → App 已铺满；
//   红线外还有黑边 → 电视缩放（需调「全屏 / 点对点 / 100%」）；
//   红线或四角被切掉 → 电视过扫描（需关掉或调小）。

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'tv_ui.dart';

class TvCalibrationPage extends StatelessWidget {
  const TvCalibrationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final view = PlatformDispatcher.instance.views.first;
    final String logical = '${mq.size.width.round()}×${mq.size.height.round()}';
    final String physical =
        '${view.physicalSize.width.round()}×${view.physicalSize.height.round()}';
    final String padding = <String>[
      mq.viewPadding.left.round().toString(),
      mq.viewPadding.top.round().toString(),
      mq.viewPadding.right.round().toString(),
      mq.viewPadding.bottom.round().toString(),
    ].join(' / ');
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: tvPageBody(
        calibration: true,
        content: Center(
          child: Container(
            width: 660,
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
            decoration: BoxDecoration(
              color: Tv.panel,
              borderRadius: BorderRadius.circular(Tv.radiusLg),
              border: Border.all(color: Tv.line),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '全屏边缘校准',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Tv.text,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '红线与四角 L 标记画在 App 画面的最外层像素，背景渐变也必须顶到四边。',
                  style: TextStyle(fontSize: 12, color: Tv.text2),
                ),
                const SizedBox(height: 14),
                _line(Tv.ok, '红线四边紧贴屏幕 → App 背景已铺满，无需再改代码。'),
                const SizedBox(height: 7),
                _line(
                  Tv.warn,
                  '红线外还有一圈黑边 → 电视把整个画面缩小了：到「图像 / 画面比例 / 缩放」调成「全屏、点对点或 100%」。',
                ),
                const SizedBox(height: 7),
                _line(Tv.danger, '红线或四角标记被切掉 → 电视过扫描，关掉过扫描或调小画面放大。'),
                const SizedBox(height: 14),
                Container(height: 1, color: Tv.line),
                const SizedBox(height: 10),
                Text(
                  '逻辑 $logical · 物理 $physical · dpr ${view.devicePixelRatio}',
                  style: const TextStyle(fontSize: 11, color: Tv.text3),
                ),
                const SizedBox(height: 3),
                Text(
                  '系统 viewPadding 左/上/右/下 = $padding',
                  style: const TextStyle(fontSize: 11, color: Tv.text3),
                ),
                const SizedBox(height: 3),
                const Text(
                  '返回键回到首页',
                  style: TextStyle(fontSize: 11, color: Tv.text2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(Color color, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          margin: const EdgeInsets.only(top: 5, right: 9),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11.5, color: Tv.text, height: 1.5),
          ),
        ),
      ],
    );
  }
}
