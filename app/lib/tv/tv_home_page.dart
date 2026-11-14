// 剧播 TV · 主页（分类 / 海报网格）与详情页（选集），P2 正式 UI。
//
// 焦点分区：
//   zone 0 = 顶栏右侧搜索框（手工焦点，OK 打开搜索页）
//   zone 1 = 顶部横向行（分类 + 继续观看 + 搜索/历史/收藏 + 解码设置 + 诊断）
//   zone 2 = 海报网格（主页） / 分集网格（详情页）
// 区域间靠 TvFocusGrid 的 onUnhandledKey 在边界方向键上切换，OK 不用抢。
// 顶栏搜索框只占一个焦点位，不额外占一整行，避免挤掉已定型的 7 列 × 2 行网格。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine.dart';
import '../models.dart';
import '../store.dart';
import '../update/update_config.dart';
import '../update/update_flow.dart';
import 'decode_settings.dart';
import 'device_profile.dart';
import 'tv_calibration_page.dart';
import 'tv_library_page.dart';
import 'tv_player_page.dart';
import 'tv_probe_page.dart';
import 'tv_search_page.dart' show TvSearchPage;
import 'tv_session.dart';
import 'tv_ui.dart';

enum _RowKind {
  category,
  resume,
  settings,
  probe,
  search,
  history,
  saved,
  calibration,
  update,
}

class _RowItem {
  const _RowItem(
    this.label,
    this.kind, {
    this.value = '',
    this.subtitle = '',
    this.icon,
  });

  final String label;
  final _RowKind kind;
  final String value;
  final String subtitle;
  final IconData? icon;
}

class TvHomePage extends StatefulWidget {
  const TvHomePage({super.key});

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  List<CatalogCategory> _categories = const <CatalogCategory>[];
  List<Drama> _items = const <Drama>[];
  int _tabIndex = 0;
  int _zone = 1;
  int _page = 1;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String _error = '';
  int _loadTicket = 0;

  List<_RowItem> get _row => <_RowItem>[
    for (final CatalogCategory c in _categories)
      _RowItem(
        c.name,
        _RowKind.category,
        value: c.id,
        icon: Icons.grid_view_rounded,
      ),
    if (_resume != null)
      _RowItem(
        '继续观看',
        _RowKind.resume,
        subtitle: '${_resume!.mark.title} · 第${_resume!.mark.episode}集',
        icon: Icons.play_circle_outline,
      ),
    const _RowItem(
      '搜索',
      _RowKind.search,
      subtitle: '剧名 / 关键词',
      icon: Icons.search_rounded,
    ),
    _RowItem(
      '观看历史',
      _RowKind.history,
      subtitle: '${Store.instance.watchCount} 部',
      icon: Icons.history_rounded,
    ),
    const _RowItem(
      '我的收藏',
      _RowKind.saved,
      subtitle: '追剧 / 点赞',
      icon: Icons.star_border_rounded,
    ),
    _RowItem(
      '解码设置',
      _RowKind.settings,
      subtitle: TvSession.instance.decision.modeLabel,
      icon: Icons.tune,
    ),
    const _RowItem(
      '解码诊断',
      _RowKind.probe,
      subtitle: 'P0 档位对照',
      icon: Icons.bug_report_outlined,
    ),
    const _RowItem(
      '全屏校准',
      _RowKind.calibration,
      subtitle: '背景是否触边',
      icon: Icons.fullscreen_rounded,
    ),
    const _RowItem(
      '检查更新',
      _RowKind.update,
      subtitle: '自动升级',
      icon: Icons.system_update_alt_rounded,
    ),
  ];

  ({String id, WatchMark mark})? get _resume =>
      Store.instance.markList.isEmpty ? null : Store.instance.markList.first;

  String get _categoryId =>
      _tabIndex < _categories.length ? _categories[_tabIndex].id : '';

  String get _sectionTitle =>
      _tabIndex < _categories.length ? _categories[_tabIndex].name : '推荐';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(_boot());
    // 启动进首页、首帧稳定后静默检查一次更新，有新版才弹窗（不抢启动焦点）。
    Future<void>.delayed(const Duration(seconds: 3), () async {
      if (!mounted) return;
      // 顺手清掉过期安装包（只清 3 天前的，不会误删刚下好待安装的包）。
      await UpdateFlow.cleanup();
      if (!mounted) return;
      await UpdateFlow.checkOnStartup(context, assetKey: UpdateConfig.tvAssetKey);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final List<CatalogCategory> rows = await Engine.instance.categories();
      if (!mounted) return;
      _categories = <CatalogCategory>[
        CatalogCategory('', '推荐'),
        ...rows.where((CatalogCategory c) => c.name.isNotEmpty),
      ];
    } catch (_) {
      _categories = <CatalogCategory>[CatalogCategory('', '推荐')];
    }
    await _load();
  }

  Future<void> _load({bool reset = true}) async {
    // 切分类时作废旧请求，避免旧分类的结果混进新分类的网格。
    final int ticket = reset ? ++_loadTicket : _loadTicket;
    final String categoryId = _categoryId;
    if (reset) {
      setState(() {
        _loading = true;
        _error = '';
        _page = 1;
        _hasMore = true;
        _items = const <Drama>[];
      });
    }
    try {
      final CatalogPage page = await Engine.instance.catalog(
        page: _page,
        category: categoryId,
      );
      if (!mounted || ticket != _loadTicket) return;
      setState(() {
        _items = <Drama>[
          ..._items,
          ...page.items.where((Drama d) => d.id.isNotEmpty),
        ];
        _hasMore = page.hasMore;
        _page = page.page + 1;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || ticket != _loadTicket) return;
      setState(() {
        _error = error.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _loadMore() {
    if (!_hasMore || _loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    unawaited(_load(reset: false));
  }

  bool _onKey(KeyEvent event) {
    if (!tvIsCurrent(context) || event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (TvKeys.menu(key)) {
      unawaited(_openSettings());
      return true;
    }
    if (TvKeys.back(key)) {
      if (_zone > 1) {
        setState(() => _zone = 1);
        return true;
      }
      if (_zone == 1) {
        setState(() => _zone = 0);
        return true;
      }
      return false; // 搜索框这一层再按返回就交给系统退出 App
    }
    if (_zone == 0) {
      if (TvKeys.activate(key)) {
        unawaited(_openSearch());
        return true;
      }
      if (TvKeys.down(key)) {
        setState(() => _zone = 1);
        return true;
      }
    }
    return false;
  }

  Future<void> _openSettings() async {
    final DecodePreference? picked = await showDecodeSettings(
      context,
      profile: TvSession.instance.profile,
      preference: TvSession.instance.preference,
    );
    if (picked == null || !mounted) return;
    await TvSession.instance.setPreference(picked);
    setState(() {});
  }

  Future<void> _activateRow(int index) async {
    final List<_RowItem> row = _row;
    if (index >= row.length) return;
    final _RowItem item = row[index];
    switch (item.kind) {
      case _RowKind.category:
        // 分类项固定在顶部行前 N 个，index 就是 _categories 的下标。
        if (index >= _categories.length) return;
        setState(() {
          _tabIndex = index;
          _zone = 1;
        });
        await _load();
        break;
      case _RowKind.resume:
        final resume = _resume;
        if (resume == null) return;
        final Map<String, dynamic> raw = resume.mark.drama != null
            ? Map<String, dynamic>.from(resume.mark.drama!)
            : <String, dynamic>{
                'id': resume.id,
                'title': resume.mark.title,
                'cover': resume.mark.cover,
              };
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => TvDetailPage(drama: Drama.fromJson(raw)),
          ),
        );
        if (mounted) setState(() {});
        break;
      case _RowKind.settings:
        await _openSettings();
        break;
      case _RowKind.probe:
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const TvProbePage()),
        );
        if (mounted) setState(() {});
        break;
      case _RowKind.calibration:
        if (!mounted) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => const TvCalibrationPage()),
        );
        if (mounted) setState(() {});
        break;
      case _RowKind.search:
        await _openSearch();
        break;
      case _RowKind.history:
        await _openLibrary(0);
        break;
      case _RowKind.saved:
        await _openLibrary(1);
        break;
      case _RowKind.update:
        await UpdateFlow.checkManually(context, assetKey: UpdateConfig.tvAssetKey);
        break;
    }
  }

  /// 供搜索 / 历史 / 收藏页复用：同样进入详情页，返回后刷新主页的续播角标。
  void _openDramaExternal(Drama drama) {
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute<void>(builder: (_) => TvDetailPage(drama: drama)),
          )
          .then((_) {
            if (mounted) setState(() {});
          }),
    );
  }

  Future<void> _openSearch() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TvSearchPage(onOpenDrama: _openDramaExternal),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openLibrary(int tab) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            TvLibraryPage(onOpenDrama: _openDramaExternal, initialTab: tab),
      ),
    );
    if (mounted) setState(() {});
  }

  void _openDrama(int index) {
    if (index >= _items.length) return;
    unawaited(
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute<void>(
              builder: (_) => TvDetailPage(drama: _items[index]),
            ),
          )
          .then((_) {
            if (mounted) setState(() {});
          }),
    );
  }

  bool _rowUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.down(key)) {
      setState(() => _zone = 2);
      return true;
    }
    if (TvKeys.up(key)) {
      setState(() => _zone = 0);
      return true;
    }
    return false;
  }

  bool _gridUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.up(key)) {
      setState(() => _zone = 1);
      return true;
    }
    if (TvKeys.down(key)) {
      _loadMore();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final TvSession session = TvSession.instance;
    final List<_RowItem> row = _row;
    final DecodeDecision decision = session.decision;
    final String? resumeId = _resume?.id;
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
                title: '剧播 TV',
                subtitle: session.profile.summary,
                trailing: <Widget>[
                  _searchBox(),
                  const SizedBox(width: 10),
                  _statusPill('解码 ${decision.modeLabel}', Tv.ok),
                  const SizedBox(width: 10),
                  _statusPill(decision.family.label, Tv.accent),
                ],
              ),
              const SizedBox(height: Tv.sectionGap),
              TvFocusGrid(
                key: const ValueKey<String>('tv-home-row'),
                axis: Axis.horizontal,
                itemCount: row.length,
                itemExtent: Tv.chipStep,
                crossExtent: Tv.chipHeight,
                active: _zone == 1,
                initialIndex: _tabIndex,
                onSelect: _activateRow,
                onUnhandledKey: _rowUnhandled,
                itemBuilder: (_, int index, bool focused) => TvChip(
                  label: row[index].label,
                  subtitle: row[index].subtitle,
                  icon: row[index].icon,
                  focused: focused,
                  selected:
                      row[index].kind == _RowKind.category &&
                      index == _tabIndex,
                ),
              ),
              const SizedBox(height: Tv.sectionGap),
              Row(
                children: <Widget>[
                  Text(
                    '$_sectionTitle · ${_items.length} 部'
                    '${_loadingMore ? ' · 加载中…' : ''}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Tv.text,
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    '↑↓ 切换区域 · OK 进入 · 菜单键 解码设置 · 顶栏 ↑ 到搜索框',
                    style: TextStyle(fontSize: 10.5, color: Tv.text2),
                  ),
                ],
              ),
              const SizedBox(height: Tv.tightGap),
              Expanded(
                child: _loading
                    ? const TvStateView(message: '正在读取剧库…', busy: true)
                    : _error.isNotEmpty
                    ? TvStateView(
                        message: _error,
                        onRetry: () => unawaited(_load()),
                      )
                    : _items.isEmpty
                    ? const TvStateView(message: '这个分类暂时没有内容')
                    : TvFocusGrid(
                        key: ValueKey<String>('grid-$_categoryId'),
                        itemCount: _items.length,
                        columns: Tv.gridColumns,
                        itemExtent: Tv.gridStep,
                        gap: Tv.gridGap,
                        padding: const EdgeInsets.only(bottom: 6, right: 2),
                        active: _zone == 2,
                        onSelect: _openDrama,
                        onUnhandledKey: _gridUnhandled,
                        onNearEnd: _loadMore,
                        itemBuilder: (_, int index, bool focused) =>
                            TvPosterCard(
                              drama: _items[index],
                              focused: focused,
                              badge: resumeId == _items[index].id ? '看过' : '',
                            ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶栏常驻搜索框：视觉上是输入框，遥控器按 ↑ 从分类行到达、OK 打开搜索页。
  /// 触摸 / 鼠标也能直接点，方便在带触摸的电视或模拟器上使用。
  Widget _searchBox() {
    return GestureDetector(
      onTap: () => unawaited(_openSearch()),
      child: tvFrame(
        focused: _zone == 0,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 210,
          height: 36,
          child: Row(
            children: <Widget>[
              Icon(
                Icons.search_rounded,
                size: 17,
                color: _zone == 0 ? Tv.accent : Tv.text2,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '搜索剧名 / 关键词',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: Tv.text2),
                ),
              ),
              const Icon(
                Icons.keyboard_return_rounded,
                size: 13,
                color: Tv.text3,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 详情页：左侧封面/简介，右侧「播放」大按钮 + 分集网格。
class TvDetailPage extends StatefulWidget {
  const TvDetailPage({super.key, required this.drama});

  final Drama drama;

  @override
  State<TvDetailPage> createState() => _TvDetailPageState();
}

class _TvDetailPageState extends State<TvDetailPage> {
  DramaDetail? _detail;
  bool _loading = true;
  String _error = '';
  int _zone = 0;
  int _resumeIndex = 0;

  List<Episode> get _episodes => _detail?.episodes ?? const <Episode>[];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(_load());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final DramaDetail detail = await Engine.instance.detail(widget.drama);
      if (!mounted) return;
      final WatchMark? mark = Store.instance.mark(widget.drama.id);
      int index = 0;
      if (mark != null) {
        final int found = detail.episodes.indexWhere(
          (Episode e) => e.number == mark.episode,
        );
        if (found >= 0) index = found;
      }
      setState(() {
        _detail = detail;
        _resumeIndex = index;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  bool _onKey(KeyEvent event) {
    if (!tvIsCurrent(context) || event is! KeyDownEvent) return false;
    if (TvKeys.menu(event.logicalKey)) {
      unawaited(_openSettings());
      return true;
    }
    return false;
  }

  Future<void> _openSettings() async {
    final DecodePreference? picked = await showDecodeSettings(
      context,
      profile: TvSession.instance.profile,
      preference: TvSession.instance.preference,
    );
    if (picked == null || !mounted) return;
    await TvSession.instance.setPreference(picked);
    setState(() {});
  }

  void _play(int index) {
    if (index < 0 || index >= _episodes.length) return;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => TvPlayerPage(
            drama: widget.drama,
            episodes: _episodes,
            initialIndex: index,
          ),
        ),
      ),
    );
  }

  void _activateAction(int index) {
    switch (index) {
      case 0:
        _play(_resumeIndex);
        return;
      case 1:
        unawaited(_toggleFav());
        return;
      default:
        unawaited(_toggleLike());
    }
  }

  /// TV 上产生收藏数据的入口：手机端靠触摸长按，这里给遥控器一个明确按钮。
  Future<void> _toggleFav() async {
    await Store.instance.toggleFav(widget.drama);
    if (mounted) setState(() {});
  }

  Future<void> _toggleLike() async {
    await Store.instance.toggleLike(widget.drama);
    if (mounted) setState(() {});
  }

  bool _playUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.down(key)) {
      setState(() => _zone = 1);
      return true;
    }
    return false;
  }

  bool _episodeUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.up(key)) {
      setState(() => _zone = 0);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final List<Episode> episodes = _episodes;
    final WatchMark? mark = Store.instance.mark(widget.drama.id);
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
                title: widget.drama.title,
                subtitle: <String>[
                  if (widget.drama.category.isNotEmpty) widget.drama.category,
                  if (episodes.isNotEmpty) '共${episodes.length}集',
                  if (widget.drama.releaseStatus.isNotEmpty &&
                      widget.drama.releaseStatus.toLowerCase() != 'unknown')
                    widget.drama.releaseStatus,
                ].join(' · '),
                trailing: const <Widget>[
                  Text(
                    '返回键 回到首页 · 菜单键 解码设置',
                    style: TextStyle(fontSize: 10.5, color: Tv.text2),
                  ),
                ],
              ),
              const SizedBox(height: Tv.sectionGap),
              if (_loading)
                const Expanded(
                  child: TvStateView(message: '正在读取分集…', busy: true),
                )
              else if (_error.isNotEmpty)
                Expanded(
                  child: TvStateView(
                    message: _error,
                    onRetry: () => unawaited(_load()),
                  ),
                )
              else
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 200,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(Tv.radius),
                              child: SizedBox(
                                width: 190,
                                height: 266,
                                child: widget.drama.cover.isNotEmpty
                                    ? Image.network(
                                        widget.drama.cover,
                                        fit: BoxFit.cover,
                                        cacheWidth: 260,
                                        errorBuilder: (_, _, _) =>
                                            const _DetailCoverFallback(),
                                      )
                                    : const _DetailCoverFallback(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.drama.description.isEmpty
                                  ? '暂无简介'
                                  : widget.drama.description,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.5,
                                color: Tv.text2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            TvFocusGrid(
                              key: const ValueKey<String>('detail-actions'),
                              axis: Axis.horizontal,
                              itemCount: 3,
                              itemExtent: 200,
                              crossExtent: 58,
                              active: _zone == 0,
                              onSelect: _activateAction,
                              onUnhandledKey: _playUnhandled,
                              itemBuilder: (_, int index, bool focused) {
                                switch (index) {
                                  case 0:
                                    return TvChip(
                                      label: mark != null
                                          ? '▶ 续播 第${mark.episode}集'
                                          : '▶ 播放第1集',
                                      subtitle:
                                          TvSession.instance.decision.modeLabel,
                                      icon: Icons.play_arrow_rounded,
                                      focused: focused,
                                      color: Tv.ok,
                                    );
                                  case 1:
                                    final bool fav = Store.instance.isFav(
                                      widget.drama.id,
                                    );
                                    return TvChip(
                                      label: fav ? '★ 已追剧' : '☆ 追剧',
                                      subtitle: '我的收藏',
                                      icon: Icons.star_rounded,
                                      focused: focused,
                                      selected: fav,
                                    );
                                  default:
                                    final bool liked = Store.instance.isLiked(
                                      widget.drama.id,
                                    );
                                    return TvChip(
                                      label: liked ? '♥ 已点赞' : '♡ 点赞',
                                      subtitle: '我的点赞',
                                      icon: Icons.favorite_rounded,
                                      focused: focused,
                                      selected: liked,
                                    );
                                }
                              },
                            ),
                            const SizedBox(height: Tv.sectionGap),
                            const Text(
                              '选集',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Tv.text,
                              ),
                            ),
                            const SizedBox(height: Tv.tightGap),
                            Expanded(
                              child: TvFocusGrid(
                                key: const ValueKey<String>('detail-episodes'),
                                itemCount: episodes.length,
                                columns: 12,
                                itemExtent: 62,
                                gap: 9,
                                active: _zone == 1,
                                initialIndex: _resumeIndex,
                                onSelect: _play,
                                onUnhandledKey: _episodeUnhandled,
                                itemBuilder: (_, int index, bool focused) {
                                  final bool watched = Store.instance
                                      .watched(widget.drama.id)
                                      .contains(episodes[index].number);
                                  return tvFrame(
                                    focused: focused,
                                    padding: EdgeInsets.zero,
                                    child: Center(
                                      child: Text(
                                        '${episodes[index].number}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: watched ? Tv.text3 : Tv.text,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
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
}

class _DetailCoverFallback extends StatelessWidget {
  const _DetailCoverFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Tv.surface2,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_outlined, size: 38, color: Tv.text3),
    );
  }
}
