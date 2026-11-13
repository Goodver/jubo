// 剧播 TV · 观看历史 / 我的追剧 / 我的点赞（P3，2026-11-08）
//
// 数据层完全复用手机端 Store：markList / favList / likeList 本来就是
// SharedPreferences 持久化的，与手机端同一份数据。TV 只补一层 10-foot 的
// tab + 海报网格，以及遥控器可用的删除（菜单键 / DEL）与清空（数字 0 双击确认）。
// 收藏数据由详情页的「追剧」按钮产生，TV 端不再需要触摸长按。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../store.dart';
import 'tv_search_page.dart' show TvOpenDrama;
import 'tv_ui.dart';

class _Entry {
  const _Entry({
    required this.id,
    required this.drama,
    required this.caption,
    this.badge = '',
  });

  final String id;
  final Drama drama;
  final String caption;
  final String badge;
}

class TvLibraryPage extends StatefulWidget {
  const TvLibraryPage({
    super.key,
    required this.onOpenDrama,
    this.initialTab = 0,
  });

  final TvOpenDrama onOpenDrama;
  final int initialTab;

  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage> {
  static const List<String> _tabs = <String>['观看历史', '我的追剧', '我的点赞'];

  int _tab = 0;
  int _zone = 0;
  int _focusIndex = 0;
  int _clearArmedAt = 0;
  String _toast = '';
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, _tabs.length - 1);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _toastTimer?.cancel();
    super.dispose();
  }

  List<_Entry> get _entries {
    switch (_tab) {
      case 0:
        return <_Entry>[
          for (final row in Store.instance.markList)
            _Entry(
              id: row.id,
              drama: _dramaFromMark(row.mark.drama, row.id, row.mark),
              caption: <String>[
                '第${row.mark.episode}集',
                _clock(row.mark.ms),
                if (_ago(row.mark.at).isNotEmpty) _ago(row.mark.at),
              ].join(' · '),
              badge: '看过',
            ),
        ];
      case 1:
        return <_Entry>[
          for (final SavedDrama saved in Store.instance.favList)
            _Entry(
              id: saved.id,
              drama: _dramaFromSaved(saved),
              caption: saved.caption.isEmpty
                  ? '共${saved.episodes}集'
                  : saved.caption,
              badge: '追剧',
            ),
        ];
      default:
        return <_Entry>[
          for (final SavedDrama saved in Store.instance.likeList)
            _Entry(
              id: saved.id,
              drama: _dramaFromSaved(saved),
              caption: saved.caption.isEmpty
                  ? '共${saved.episodes}集'
                  : saved.caption,
              badge: '点赞',
            ),
        ];
    }
  }

  Drama _dramaFromMark(Map<String, dynamic>? raw, String id, WatchMark mark) {
    if (raw != null) return Drama.fromJson(Map<String, dynamic>.from(raw));
    return Drama.fromJson(<String, dynamic>{
      'id': id,
      'title': mark.title,
      'cover': mark.cover,
    });
  }

  Drama _dramaFromSaved(SavedDrama saved) {
    return saved.drama ??
        Drama.fromJson(<String, dynamic>{
          'id': saved.id,
          'title': saved.title,
          'cover': saved.cover,
          'category': saved.category,
          'episodes': saved.episodes,
        });
  }

  static String _clock(int ms) {
    final int seconds = ms < 0 ? 0 : ms ~/ 1000;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  static String _ago(int at) {
    if (at <= 0) return '';
    final int diff = DateTime.now().millisecondsSinceEpoch - at;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = '');
    });
  }

  Future<void> _remove(int index) async {
    final List<_Entry> entries = _entries;
    if (index < 0 || index >= entries.length) return;
    final _Entry entry = entries[index];
    switch (_tab) {
      case 0:
        await Store.instance.removeMark(entry.id);
        break;
      case 1:
        await Store.instance.removeFav(entry.id);
        break;
      default:
        await Store.instance.removeLike(entry.id);
    }
    if (!mounted) return;
    _showToast('已移除「${entry.drama.title}」');
  }

  Future<void> _clearAll() async {
    switch (_tab) {
      case 0:
        // 只清观看进度与已看完记录，不影响点赞/追剧。
        await Store.instance.clearPlayback();
        break;
      case 1:
        await Store.instance.clearFavs();
        break;
      default:
        await Store.instance.clearLikes();
    }
    if (!mounted) return;
    _showToast('已清空「${_tabs[_tab]}」');
  }

  void _armClear() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _clearArmedAt < 4000) {
      _clearArmedAt = 0;
      unawaited(_clearAll());
    } else {
      _clearArmedAt = now;
      _showToast('再按一次数字 0 确认清空「${_tabs[_tab]}」');
    }
  }

  bool _onKey(KeyEvent event) {
    if (!tvIsCurrent(context) || event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (TvKeys.back(key) && _zone == 1) {
      setState(() => _zone = 0);
      return true;
    }
    if (TvKeys.menu(key) || key == LogicalKeyboardKey.delete) {
      unawaited(_remove(_focusIndex));
      return true;
    }
    if (key == LogicalKeyboardKey.digit0) {
      _armClear();
      return true;
    }
    return false;
  }

  bool _tabUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.down(key)) {
      setState(() => _zone = 1);
      return true;
    }
    return false;
  }

  bool _gridUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.up(key)) {
      setState(() => _zone = 0);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final List<_Entry> entries = _entries;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tv.gutter,
            vertical: Tv.pagePaddingV,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TvTopBar(
                title: '我的',
                subtitle: '${_tabs[_tab]} · ${entries.length} 部',
                trailing: const <Widget>[
                  Text(
                    '菜单键/DEL 移除当前 · 数字 0 清空 · 返回键 回主页',
                    style: TextStyle(fontSize: 10.5, color: Tv.text2),
                  ),
                ],
              ),
              const SizedBox(height: Tv.sectionGap),
              TvFocusGrid(
                key: const ValueKey<String>('library-tabs'),
                axis: Axis.horizontal,
                itemCount: _tabs.length,
                itemExtent: Tv.chipStep,
                crossExtent: Tv.chipHeight,
                active: _zone == 0,
                initialIndex: _tab,
                onSelect: (int index) => setState(() {
                  _tab = index;
                  _zone = 1;
                  _focusIndex = 0;
                }),
                onUnhandledKey: _tabUnhandled,
                itemBuilder: (_, int index, bool focused) => TvChip(
                  label: _tabs[index],
                  subtitle: index == 0
                      ? '${Store.instance.watchCount} 部'
                      : index == 1
                      ? '${Store.instance.favCount} 部'
                      : '${Store.instance.likeCount} 部',
                  icon: index == 0
                      ? Icons.history_rounded
                      : index == 1
                      ? Icons.star_rounded
                      : Icons.favorite_rounded,
                  focused: focused,
                  selected: index == _tab,
                ),
              ),
              const SizedBox(height: Tv.sectionGap),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    entries.isEmpty
                        ? TvStateView(
                            message: _tab == 0
                                ? '还没有观看记录，去首页看一集吧'
                                : _tab == 1
                                ? '还没有追剧，在详情页按「追剧」即可加入'
                                : '还没有点赞的短剧',
                          )
                        : TvFocusGrid(
                            key: ValueKey<String>('library-grid-$_tab'),
                            itemCount: entries.length,
                            columns: Tv.gridColumns,
                            itemExtent: Tv.gridStep,
                            gap: Tv.gridGap,
                            active: _zone == 1,
                            onSelect: (int i) =>
                                widget.onOpenDrama(entries[i].drama),
                            onUnhandledKey: _gridUnhandled,
                            onFocusChange: (int i) => _focusIndex = i,
                            itemBuilder: (_, int index, bool focused) =>
                                _card(entries[index], focused),
                          ),
                    if (_toast.isNotEmpty)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xEE121A2C),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Tv.accent),
                            ),
                            child: Text(
                              _toast,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Tv.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(_Entry entry, bool focused) {
    return tvFrame(
      focused: focused,
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  entry.drama.cover.isNotEmpty
                      ? Image.network(
                          entry.drama.cover,
                          fit: BoxFit.cover,
                          cacheWidth: 240,
                          errorBuilder: (_, _, _) => const _Fallback(),
                        )
                      : const _Fallback(),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xCC080B14),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        entry.badge,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Tv.ok,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.drama.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Tv.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            entry.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Tv.text3),
          ),
        ],
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Tv.surface2,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_outlined, size: 32, color: Tv.text3),
    );
  }
}
