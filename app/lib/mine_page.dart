import 'package:flutter/material.dart';

import 'appmeta.dart';
import 'history_page.dart';
import 'saved_page.dart';
import 'settings_page.dart';
import 'store.dart';
import 'theme.dart';

Route<void> mineRoute() => MaterialPageRoute(builder: (_) => const MinePage());

/// 我的：点赞 / 追剧 / 设置的入口
class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  @override
  Widget build(BuildContext context) {
    final likes = Store.instance.likeCount;
    final favs = Store.instance.favCount;
    final watched = Store.instance.watchCount;

    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        title: const Text(
          '我的',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Hg.logo2, Hg.logo],
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '剧',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    AppMeta.appName,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Hg.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'v${AppMeta.versionLabel}',
                    style: const TextStyle(fontSize: 11.5, color: Hg.text3),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Hg.bg1,
              borderRadius: BorderRadius.circular(Hg.radius),
            ),
            child: Row(
              children: [
                _stat('$likes', '点赞', () => _open(likes: true)),
                _statDivider(),
                _stat('$favs', '追剧', () => _open(likes: false)),
                _statDivider(),
                _stat('$watched', '观看记录', () => _push(historyRoute())),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _tile(
            icon: Icons.favorite_rounded,
            iconColor: Hg.likeOn,
            title: '我的点赞',
            subtitle: likes == 0 ? '还没有点赞过的短剧' : '共$likes部 · 长按可移除',
            onTap: () => _open(likes: true),
          ),
          _tile(
            icon: Icons.star_rounded,
            iconColor: Hg.favOn,
            title: '我的追剧',
            subtitle: favs == 0 ? '还没有追的剧' : '共$favs部 · 长按可移除',
            onTap: () => _open(likes: false),
          ),
          _tile(
            icon: Icons.history_rounded,
            title: '观看记录',
            subtitle: watched == 0 ? '还没有观看记录' : '共$watched部',
            onTap: () => _push(historyRoute()),
          ),
          _tile(
            icon: Icons.settings_rounded,
            title: '设置',
            subtitle: '许可 · 清空缓存 · 关于',
            onTap: () => _push(settingsRoute()),
          ),
          const SizedBox(height: 26),
          const Center(
            child: Text(
              '内容来自公开网络 · 仅供学习交流',
              style: TextStyle(fontSize: 11, color: Hg.text3),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open({required bool likes}) async {
    await Navigator.of(context).push(savedRoute(likes: likes));
    if (mounted) setState(() {});
  }

  Future<void> _push(Route<void> route) async {
    await Navigator.of(context).push(route);
    if (mounted) setState(() {});
  }

  Widget _stat(String value, String label, VoidCallback? onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Hg.text,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: Hg.text3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statDivider() =>
      Container(width: 1, height: 26, color: Hg.line);

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Hg.bg1,
        borderRadius: BorderRadius.circular(Hg.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Hg.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor ?? Hg.text2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Hg.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 11.5, color: Hg.text3),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Hg.text3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
