import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'appmeta.dart';
import 'engine.dart';
import 'feed_page.dart';
import 'nav.dart';
import 'store.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const HgApp());
}

class HgApp extends StatelessWidget {
  const HgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '剧播',
      debugShowCheckedModeBanner: false,
      theme: Hg.theme(),
      navigatorObservers: [routeObserver],
      // 系统组件（许可页标题、返回按钮提示等）走中文
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const BootPage(),
    );
  }
}

/// 启动即进推荐流：引擎就绪后直接全屏播放，不经过任何首页/详情页
class BootPage extends StatefulWidget {
  const BootPage({super.key});

  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> {
  String _error = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await Directory(dir.path).create(recursive: true);
      await AppMeta.load();
      await Store.instance.load();
      await Engine.instance.initialize(dir.path);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, _, _) => const FeedPage(),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Hg.logo2, Hg.logo],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: const Text(
                '剧',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_error.isEmpty)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0x66FFFFFF),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(
                  _error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Hg.text2,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() => _error = '');
                  _boot();
                },
                child: const Text('重试', style: TextStyle(color: Hg.brand2)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
