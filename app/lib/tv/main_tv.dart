// 剧播 TV · P2 正式入口（2026-11-07）
//
// 与手机主分支 lib/main.dart 并列，由 `-t lib/tv/main_tv.dart` 指定；
// Gradle 的 tv flavor 只管包名 / ABI / Manifest，不绑定 Dart 入口。
// 入口负责一次初始化（Store → Go 引擎 → 设备指纹/解码会话），
// 之后交给 TvHomePage 的分类/海报 → 详情/选集 → 播放闭环。
//
// 旧的 P0 五步诊断 + 四档 A/B 对照完整保留在 tv_probe_page.dart，
// 从主页顶部「解码诊断」进入，方便复现色彩问题与取证。

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../engine.dart';
import '../store.dart';
import '../theme.dart';
import 'device_profile.dart';
import 'tv_home_page.dart';
import 'tv_session.dart';
import 'tv_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 电视上不允许系统状态栏/导航栏占掉任何一条边；强制横屏 + 沉浸全屏。
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  unawaited(
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]),
  );
  runApp(const TvApp());
}

void _log(String message) {
  // ignore: avoid_print
  print('[TV-UI] $message');
}

void _decodeLog(String message) {
  // ignore: avoid_print
  print('[TV-DECODE] $message');
}

class TvApp extends StatelessWidget {
  const TvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '剧播 TV',
      debugShowCheckedModeBanner: false,
      // 直接复用手机端 Hg.theme()：色板 / 圆角 / 字号节奏保持一致，
      // 只把品牌主色用作 TV 焦点态（遥控器需要高对比）。
      theme: Hg.theme().copyWith(
        // 页面一律透明，颜色交给下面 builder 里的全屏背景层，避免
        // Scaffold 用自己的 backgroundColor 把铺满的背景盖掉。
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(
          primary: Hg.brand,
          secondary: Hg.brand2,
          surface: Hg.bg1,
          onSurface: Hg.text,
        ),
      ),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const TvBootPage(),
      // 2026-11-08：背景层放在整个 Navigator 底下，用 Positioned.fill
      // 从物理第 0 行/列画到最后一行/列。页面内部无论怎么套 SafeArea /
      // gutter，都不会再把「背景」一起内缩，四边必然触边。
      builder: (BuildContext context, Widget? child) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const Positioned.fill(child: TvBackdrop()),
          if (child != null) Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class TvBootPage extends StatefulWidget {
  const TvBootPage({super.key});

  @override
  State<TvBootPage> createState() => _TvBootPageState();
}

class _TvBootPageState extends State<TvBootPage> {
  String _error = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final Directory dir = await getApplicationSupportDirectory();
      await Directory(dir.path).create(recursive: true);
      await Store.instance.load();
      await Engine.instance.initialize(dir.path);
      await TvSession.instance.init();
      final TvDeviceProfile profile = TvSession.instance.profile;
      final DecodeDecision decision = TvSession.instance.decision;
      // 显示诊断：确认 Flutter view 是否真的铺满物理屏，以及系统 insets。
      // 电视本身若有「画面比例 / 过扫描」设置造成黑边，adb screecap 看不出来，
      // 这里把 view 尺寸打进 logcat 供现场核对。
      final view = PlatformDispatcher.instance.views.first;
      final vp = view.viewPadding;
      _log(
        'display physical=${view.physicalSize.width.round()}x'
        '${view.physicalSize.height.round()} dpr=${view.devicePixelRatio} '
        'viewPadding=${vp.left.round()}/${vp.top.round()}/'
        '${vp.right.round()}/${vp.bottom.round()}',
      );
      _log('boot ok device=${profile.summary}');
      _decodeLog('device=${profile.summary}');
      _decodeLog('fingerprint=${profile.fingerprint}');
      _decodeLog('hevcDecoders=[${profile.hevcDecoders.join(', ')}]');
      _decodeLog(
        'pref=${decision.preference.name} '
        'family=${decision.family.name} hwdec=${decision.hwdec} '
        'quality=${decision.quality}',
      );
      _decodeLog('reason=${decision.reason}');
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 240),
          pageBuilder: (_, _, _) => const TvHomePage(),
          transitionsBuilder: (
            _,
            Animation<double> animation,
            _,
            Widget child,
          ) => FadeTransition(opacity: animation, child: child),
        ),
      );
    } catch (error) {
      _log('boot FAILED: $error');
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Tv.logo2, Tv.logo],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Text(
                '剧',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '剧播 TV',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Tv.text,
              ),
            ),
            const SizedBox(height: 12),
            if (_error.isEmpty)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 60),
                child: Text(
                  _error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: Tv.danger),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _boot,
                child: const Text('重试（OK）', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
