import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feed_page.dart';
import 'models.dart';
import 'theme.dart';
import 'webcat.dart';

Route<void> searchRoute() =>
    MaterialPageRoute(builder: (_) => const SearchPage());

/// 片库搜索：网页版 /api/search/result 接口，支持分页
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _kHistory = 'hg.search.history.v1';

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _items = <Drama>[];
  final _history = <String>[];
  final _hot = <String>[];

  String _keyword = '';
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _searched = false;
  String _error = '';

  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      final has = _input.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 700) {
        _loadMore();
      }
    });
    _restore();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_kHistory) ?? const <String>[];
    if (!mounted) return;
    setState(() => _history.addAll(rows.take(12)));
    // 热搜词用总榜前十的剧名顶上，比空着好看
    try {
      final board = await WebCatalog.instance.rankBoard('hongguo', 1);
      if (!mounted) return;
      setState(() {
        _hot
          ..clear()
          ..addAll(board.items.take(10).map((e) => e.drama.title));
      });
    } catch (_) {}
  }

  Future<void> _remember(String keyword) async {
    _history.remove(keyword);
    _history.insert(0, keyword);
    if (_history.length > 12) _history.removeLast();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHistory, _history);
  }

  Future<void> _clearHistory() async {
    setState(_history.clear);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistory);
  }

  void _submit(String raw) {
    final keyword = raw.trim();
    if (keyword.isEmpty) return;
    _focus.unfocus();
    _input.text = keyword;
    setState(() {
      _keyword = keyword;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _error = '';
      _searched = true;
    });
    _remember(keyword);
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _keyword.isEmpty) return;
    setState(() => _loading = true);
    final next = _page + 1;
    final target = _keyword;
    try {
      final result = await WebCatalog.instance.search(target, next);
      if (!mounted || target != _keyword) return;
      setState(() {
        _items.addAll(result.items);
        _page = next;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _loading = false;
        if (result.items.isEmpty && next == 1) _error = '没有找到相关短剧';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _reset() {
    _input.clear();
    setState(() {
      _keyword = '';
      _items.clear();
      _page = 0;
      _hasMore = true;
      _searched = false;
      _error = '';
    });
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        titleSpacing: 0,
        title: Container(
          height: 36,
          margin: const EdgeInsets.only(right: 14),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Hg.bg2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Hg.line),
          ),
          child: Row(
            children: [
              const Icon(Icons.search_rounded, size: 17, color: Hg.text3),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  autofocus: false,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 13.5, color: Hg.text),
                  cursorColor: Hg.brand,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '搜剧名、演员、题材',
                    hintStyle: TextStyle(fontSize: 13.5, color: Hg.text3),
                  ),
                  onSubmitted: _submit,
                ),
              ),
              if (_hasText)
                GestureDetector(
                  onTap: _reset,
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.cancel,
                      size: 16,
                      color: Hg.text3,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _submit(_input.text),
            child: const Text(
              '搜索',
              style: TextStyle(fontSize: 13.5, color: Hg.brand2),
            ),
          ),
        ],
      ),
      body: _searched ? _resultView() : _discoverView(),
    );
  }

  Widget _resultView() {
    if (_error.isNotEmpty && _items.isEmpty) {
      return Center(
        child: Text(
          _error,
          style: const TextStyle(fontSize: 13, color: Hg.text2),
        ),
      );
    }
    if (_items.isEmpty && _loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Hg.text3),
        ),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.54,
        crossAxisSpacing: 10,
        mainAxisSpacing: 16,
      ),
      itemCount: _items.length + (_loading ? 3 : 0),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Container(
            decoration: BoxDecoration(
              color: Hg.bg2,
              borderRadius: BorderRadius.circular(Hg.radius),
            ),
          );
        }
        return _card(_items[index]);
      },
    );
  }

  Widget _discoverView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            children: [
              const Text(
                '搜索历史',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Hg.text,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _clearHistory,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: Hg.text3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in _history)
                _wordChip(word, () => _submit(word), history: true),
            ],
          ),
          const SizedBox(height: 20),
        ],
        if (_hot.isNotEmpty) ...[
          const Text(
            '大家都在看',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Hg.text,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final word in _hot) _wordChip(word, () => _submit(word)),
            ],
          ),
        ],
        const SizedBox(height: 24),
        const Text(
          '输入关键词，搜全站真人剧 / 漫剧 / AI 剧',
          style: TextStyle(fontSize: 11.5, color: Hg.text3),
        ),
      ],
    );
  }

  Widget _wordChip(String word, VoidCallback onTap, {bool history = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: history ? Hg.bg2 : Hg.bg1,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: history ? Hg.line : Hg.line2),
        ),
        child: Text(
          word,
          style: TextStyle(
            fontSize: 12.5,
            color: history ? Hg.text2 : Hg.brand2,
          ),
        ),
      ),
    );
  }

  Widget _card(Drama drama) {
    return GestureDetector(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => FeedPage(initialDrama: drama))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Hg.radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Hg.bg2),
                  if (drama.cover.isNotEmpty)
                    Image.network(
                      drama.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(7, 14, 7, 6),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xCC000000)],
                        ),
                      ),
                      child: Text(
                        '共${drama.episodeCount}集',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
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
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.28,
              color: Hg.text,
            ),
          ),
          if (drama.category.isNotEmpty)
            Text(
              drama.category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Hg.text3),
            ),
        ],
      ),
    );
  }
}
