// 剧播 TV · 搜索页（P3，2026-11-08）
//
// 电视没有触屏、中文输入极不方便，所以这里不照搬手机端的 TextField 搜索页：
//   · 顶栏下方是常驻搜索框，支持外接键盘 / 系统输入法 / adb input text；
//   · 左侧屏上键盘用 DPAD 逐字输入（英文、数字、剧名缩写）；
//   · 右侧把「联想词 / 搜索历史 / 大家都在看」做成一键可搜的词条，
//     中文剧名靠这一栏覆盖，绝大多数场景不用打字；
//   · 底部结果网格复用 TvPosterCard，OK 直达详情播放。
// 数据源与手机端共用 WebCatalog（真分页 + 联想），网页源失败时回退 Go 引擎
// 的 catalog+query 搜索；搜索历史沿用手机端的 hg.search.history.v1，两端互通。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine.dart';
import '../models.dart';
import '../webcat.dart' as webcat;
import 'tv_ui.dart';

typedef TvOpenDrama = void Function(Drama drama);

class TvSearchPage extends StatefulWidget {
  const TvSearchPage({
    super.key,
    required this.onOpenDrama,
    this.initialKeyword = '',
  });

  final TvOpenDrama onOpenDrama;
  final String initialKeyword;

  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  static const String _kHistory = 'hg.search.history.v1';
  static const List<String> _defaultHot = <String>[
    '霸总',
    '重生',
    '赘婿',
    '甜宠',
    '逆袭',
    '年代',
    '复仇',
    '穿越',
    '都市',
    '萌宝',
  ];
  static const List<String> _keys = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '空格',
    '退格',
    '清空',
    '搜索',
    '输入法',
    '词条',
    '返回',
  ];

  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  Timer? _debounce;

  List<String> _history = <String>[];
  List<String> _hot = _defaultHot;
  List<String> _suggestions = <String>[];
  List<Drama> _items = <Drama>[];
  String _keyword = '';
  String _error = '';
  bool _loading = false;
  bool _hasMore = true;
  bool _searched = false;
  int _page = 0;
  int _zone = 0;
  int _loadTicket = 0;

  List<String> get _words {
    final List<String> out = <String>[..._suggestions, ..._history, ..._hot];
    final Set<String> seen = <String>{};
    return out
        .where((String w) => w.trim().isNotEmpty && seen.add(w.trim()))
        .take(18)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    if (widget.initialKeyword.isNotEmpty) {
      _input.text = widget.initialKeyword;
      unawaited(_submit(widget.initialKeyword));
    }
    unawaited(_restore());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _debounce?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _history = prefs.getStringList(_kHistory) ?? <String>[];
    try {
      final webcat.RankBoardPage board = await webcat.WebCatalog.instance
          .rankBoard('hongguo', 1);
      final List<String> names = board.items
          .take(10)
          .map((webcat.RankEntry e) => e.drama.title.trim())
          .where((String s) => s.isNotEmpty && s != '未命名')
          .toList();
      if (names.isNotEmpty) _hot = names;
    } catch (_) {
      // 榜单不可用就保留内置热词。
    }
    if (mounted) setState(() {});
  }

  Future<void> _remember(String keyword) async {
    _history.remove(keyword);
    _history.insert(0, keyword);
    if (_history.length > 12) _history = _history.sublist(0, 12);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHistory, _history);
    if (mounted) setState(() {});
  }

  void _onChanged(String value) {
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final String query = value.trim();
      if (query.isEmpty) {
        if (mounted) setState(() => _suggestions = <String>[]);
        return;
      }
      try {
        final List<String> words = await webcat.WebCatalog.instance.suggest(
          query,
        );
        if (mounted) setState(() => _suggestions = words);
      } catch (_) {
        // 联想失败不影响手动搜索。
      }
    });
  }

  Future<void> _submit(String raw) async {
    final String keyword = raw.trim();
    if (keyword.isEmpty) return;
    _inputFocus.unfocus();
    await _remember(keyword);
    final int ticket = ++_loadTicket;
    setState(() {
      _keyword = keyword;
      _items = <Drama>[];
      _page = 0;
      _hasMore = true;
      _searched = true;
      _error = '';
      _loading = true;
      _zone = 2;
    });
    await _loadMore(ticket);
  }

  Future<void> _loadMore([int? ticket]) async {
    final int current = ticket ?? _loadTicket;
    if (_loading && ticket == null) return;
    if (!_hasMore || _keyword.isEmpty) return;
    final int next = _page + 1;
    setState(() => _loading = true);
    try {
      final webcat.SearchPage result = await webcat.WebCatalog.instance.search(
        _keyword,
        next,
      );
      if (!mounted || current != _loadTicket) return;
      setState(() {
        _items = <Drama>[
          ..._items,
          ...result.items.where((Drama d) => d.id.isNotEmpty),
        ];
        _page = next;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      // 网页源不可用时回退到 Go 引擎的红果搜索（一次性返回全部命中）。
      try {
        final CatalogPage page = await Engine.instance.search(_keyword);
        if (!mounted || current != _loadTicket) return;
        setState(() {
          _items = <Drama>[
            ..._items,
            ...page.items.where((Drama d) => d.id.isNotEmpty),
          ];
          _page = next;
          _hasMore = false;
          _loading = false;
        });
      } catch (error) {
        if (!mounted || current != _loadTicket) return;
        setState(() {
          _error = error.toString();
          _loading = false;
          _hasMore = false;
        });
      }
    }
  }

  void _pressKey(String value) {
    switch (value) {
      case '返回':
        Navigator.of(context).maybePop();
        return;
      case '输入法':
        _inputFocus.requestFocus();
        return;
      case '词条':
        // 键盘是 8 列网格，靠方向键走到行末再切区太绕，给一个直达按钮。
        setState(() => _zone = 1);
        return;
      case '搜索':
        unawaited(_submit(_input.text));
        return;
      case '清空':
        _input.clear();
        _suggestions = <String>[];
        break;
      case '退格':
        if (_input.text.isNotEmpty) {
          _input.text = _input.text.substring(0, _input.text.length - 1);
        }
        break;
      case '空格':
        _input.text = '${_input.text} ';
        break;
      default:
        _input.text = '${_input.text}$value';
    }
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _onChanged(_input.text);
  }

  void _activateWord(int index) {
    final List<String> words = _words;
    if (index >= words.length) return;
    final String word = words[index];
    _input.text = word;
    unawaited(_submit(word));
  }

  bool _onKey(KeyEvent event) {
    if (!tvIsCurrent(context) || event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (TvKeys.back(key) && _zone > 0) {
      setState(() => _zone -= 1);
      return true;
    }
    if (TvKeys.menu(key)) {
      setState(() {
        _input.clear();
        _suggestions = <String>[];
        _zone = 0;
      });
      return true;
    }
    // 遥控器数字键直达三个区，避免方向键必须走到边界才能切区。
    if (key == LogicalKeyboardKey.digit0) {
      setState(() => _zone = 0);
      return true;
    }
    if (key == LogicalKeyboardKey.digit1) {
      setState(() => _zone = 1);
      return true;
    }
    if (key == LogicalKeyboardKey.digit2) {
      setState(() => _zone = 2);
      return true;
    }
    // 结果为空 / 报错时网格不渲染，TvFocusGrid 收不到按键，这里兜底切区与重试。
    if (_zone == 2 && _items.isEmpty) {
      if (TvKeys.up(key)) {
        setState(() => _zone = 1);
        return true;
      }
      if (TvKeys.left(key)) {
        setState(() => _zone = 0);
        return true;
      }
      if (TvKeys.activate(key) && _error.isNotEmpty) {
        unawaited(_submit(_keyword));
        return true;
      }
    }
    return false;
  }

  bool _keyboardUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.right(key)) {
      setState(() => _zone = 1);
      return true;
    }
    return false;
  }

  bool _wordsUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.left(key)) {
      setState(() => _zone = 0);
      return true;
    }
    if (TvKeys.down(key)) {
      setState(() => _zone = 2);
      return true;
    }
    return false;
  }

  bool _resultUnhandled(LogicalKeyboardKey key, int index) {
    if (TvKeys.up(key)) {
      setState(() => _zone = 1);
      return true;
    }
    if (TvKeys.left(key)) {
      setState(() => _zone = 0);
      return true;
    }
    if (TvKeys.down(key)) {
      unawaited(_loadMore());
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> words = _words;
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
                title: '搜索',
                subtitle: _keyword.isEmpty
                    ? '关键词 / 剧名 · 也可用热词一键搜索'
                    : '「$_keyword」· ${_items.length} 部结果',
                trailing: const <Widget>[
                  Text(
                    '数字 0 键盘 / 1 词条 / 2 结果 · OK 输入搜索 · 菜单键 清空 · 返回键 回主页',
                    style: TextStyle(fontSize: 10.5, color: Tv.text2),
                  ),
                ],
              ),
              const SizedBox(height: Tv.sectionGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 380,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _searchBox(),
                          const SizedBox(height: 8),
                          Text(
                            '屏上键盘 · 中文请用「输入法」或选右侧词条',
                            style: TextStyle(fontSize: 10.5, color: Tv.text3),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: TvFocusGrid(
                              key: const ValueKey<String>('search-keys'),
                              itemCount: _keys.length,
                              columns: 8,
                              itemExtent: 48,
                              gap: 6,
                              active: _zone == 0,
                              onSelect: (int i) => _pressKey(_keys[i]),
                              onUnhandledKey: _keyboardUnhandled,
                              itemBuilder: (_, int index, bool focused) {
                                final String label = _keys[index];
                                final bool action = label.length > 1;
                                return tvFrame(
                                  focused: focused,
                                  padding: EdgeInsets.zero,
                                  child: Center(
                                    child: Text(
                                      label,
                                      style: TextStyle(
                                        fontSize: action ? 10.5 : 15,
                                        fontWeight: FontWeight.w700,
                                        color: action ? Tv.accent : Tv.text,
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
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Text(
                                '联想 / 历史 / 大家都在看',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: Tv.text,
                                ),
                              ),
                              const Spacer(),
                              if (_history.isNotEmpty)
                                GestureDetector(
                                  onTap: () async {
                                    final SharedPreferences prefs =
                                        await SharedPreferences.getInstance();
                                    await prefs.remove(_kHistory);
                                    _history = <String>[];
                                    if (mounted) setState(() {});
                                  },
                                  child: const Text(
                                    '清空历史',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: Tv.warn,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TvFocusGrid(
                            key: const ValueKey<String>('search-words'),
                            axis: Axis.horizontal,
                            itemCount: words.length,
                            itemExtent: 160,
                            crossExtent: 42,
                            gap: 8,
                            active: _zone == 1,
                            onSelect: _activateWord,
                            onUnhandledKey: _wordsUnhandled,
                            itemBuilder: (_, int index, bool focused) => TvChip(
                              label: words[index],
                              icon: Icons.search,
                              focused: focused,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Expanded(child: _resultView()),
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

  Widget _searchBox() {
    return tvFrame(
      focused: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: SizedBox(
        height: 46,
        child: Row(
          children: <Widget>[
            const Icon(Icons.search_rounded, size: 20, color: Tv.text2),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                style: const TextStyle(fontSize: 15, color: Tv.text),
                cursorColor: Tv.accent,
                textInputAction: TextInputAction.search,
                onSubmitted: (String v) => unawaited(_submit(v)),
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: '输入剧名 / 关键词，回车搜索',
                  hintStyle: TextStyle(fontSize: 13, color: Tv.text3),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_input.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _input.clear();
                  _onChanged('');
                },
                child: const Icon(Icons.close, size: 17, color: Tv.text3),
              ),
          ],
        ),
      ),
    );
  }

  /// 未搜索时把右栏下半部的空白填成操作引导，避免整页看起来只有一条词条行。
  Widget _guideView() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Tv.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Tv.radius),
        border: Border.all(color: Tv.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            '怎么搜',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Tv.text,
            ),
          ),
          const SizedBox(height: 14),
          _guideRow(
            Icons.touch_app_rounded,
            '选词直接搜',
            '右侧词条来自联想、搜索历史与热播榜，OK 立即出结果',
          ),
          _guideRow(Icons.keyboard_rounded, '屏上键盘', '左侧方向键移动、OK 输入字母数字，适合剧名缩写'),
          _guideRow(
            Icons.translate_rounded,
            '中文剧名',
            '按「输入法」调系统输入法，或接 USB 键盘 / 手机遥控 App',
          ),
          _guideRow(
            Icons.dialpad_rounded,
            '快速切区',
            '数字 0 键盘 · 1 词条 · 2 结果；也可按「词条」键直达',
          ),
        ],
      ),
    );
  }

  Widget _guideRow(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: Tv.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Tv.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(fontSize: 11, color: Tv.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultView() {
    if (!_searched) return _guideView();
    if (_loading && _items.isEmpty) {
      return const TvStateView(message: '正在搜索…', busy: true);
    }
    if (_error.isNotEmpty && _items.isEmpty) {
      return TvStateView(
        message: _error,
        onRetry: () => unawaited(_submit(_keyword)),
      );
    }
    if (_items.isEmpty) {
      return const TvStateView(message: '没有找到相关短剧，换个关键词试试');
    }
    return TvFocusGrid(
      key: const ValueKey<String>('search-results'),
      itemCount: _items.length,
      columns: 5,
      itemExtent: 196,
      gap: 12,
      active: _zone == 2,
      onSelect: (int i) => widget.onOpenDrama(_items[i]),
      onUnhandledKey: _resultUnhandled,
      onNearEnd: () => unawaited(_loadMore()),
      itemBuilder: (_, int index, bool focused) =>
          TvPosterCard(drama: _items[index], focused: focused),
    );
  }
}
