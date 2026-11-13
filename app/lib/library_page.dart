import 'package:flutter/material.dart';

import 'engine.dart';
import 'feed_page.dart';
import 'mine_page.dart';
import 'models.dart';
import 'rank_page.dart';
import 'search_page.dart';
import 'theme.dart';
import 'webcat.dart';

Route<void> libraryRoute() =>
    MaterialPageRoute(builder: (_) => const LibraryPage());

/// 分类片库（对应桌面版左侧导航里的「片库」）：点卡片直接进播放流
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _scroll = ScrollController();
  final _items = <Drama>[];
  List<CatalogCategory> _categories = const [];
  String _category = '';
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _silent = false;
  int _gen = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_silent) return;
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
        _load();
      }
    });
    _load(reset: true);
    _loadCategories();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    try {
      final rows = await Engine.instance.categories();
      if (!mounted) return;
      final seen = <String>{};
      setState(() {
        _categories = rows
            .where((row) => row.name.isNotEmpty && row.name != '全部')
            .where((row) => seen.add('${row.id}|${row.name}'))
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final gen = ++_gen;
    setState(() {
      _loading = true;
      if (reset) {
        _error = '';
        _hasMore = true;
      }
    });
    try {
      final next = reset ? 1 : _page + 1;
      // 引擎的 App 接口只回真人剧，漫剧 / AI 剧走网页分类页
      final List<Drama> rows;
      if (_category.isEmpty) {
        rows = await WebCatalog.instance.mixedPage(next);
      } else {
        rows = await WebCatalog.instance.categoryPage(_category, next);
      }
      final result = rows.isEmpty
          ? await Engine.instance.catalog(page: next, category: _category)
          : CatalogPage(rows, rows.length >= 20, next, '');
      if (!mounted || gen != _gen) return;
      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(result.items);
        } else {
          _items.addAll(result.items);
        }
        _page = next;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  /// 刷新：清空当前列表、回到顶部、重新拉第一页，并给一个明确反馈
  Future<void> _refresh() async {
    if (_scroll.hasClients) {
      _silent = true;
      _scroll.jumpTo(0);
      _silent = false;
    }
    await _load(reset: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _items.isEmpty ? '没有拉到内容，检查网络后重试' : '已刷新 · ${_items.length}部',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        title: const Text(
          '片库',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
        actions: [
          IconButton(
            onPressed: () async {
              await Navigator.of(context).push(searchRoute());
              if (mounted) _load(reset: true);
            },
            icon: const Icon(Icons.search_rounded, size: 21, color: Hg.text2),
            tooltip: '搜索',
          ),
          IconButton(
            onPressed: () async {
              await Navigator.of(context).push(rankRoute());
              if (mounted) _load(reset: true);
            },
            icon: const Icon(
              Icons.leaderboard_rounded,
              size: 20,
              color: Hg.text2,
            ),
            tooltip: '榜单',
          ),
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Hg.text2),
            tooltip: '刷新',
          ),
          IconButton(
            onPressed: () async {
              await Navigator.of(context).push(mineRoute());
              if (mounted) setState(() {});
            },
            icon: const Icon(
              Icons.person_outline_rounded,
              size: 21,
              color: Hg.text2,
            ),
            tooltip: '我的',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_categories.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  _chip('全部', ''),
                  for (final category in _categories)
                    _chip(category.name, category.id),
                ],
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error,
                style: const TextStyle(fontSize: 12.5, color: Hg.brand2),
              ),
            ),
          Expanded(
            child: GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) {
    final active = value == _category;
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 7, bottom: 7),
      child: GestureDetector(
        onTap: () {
          if (_category == value) return;
          setState(() => _category = value);
          _load(reset: true);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? Hg.brandDim : Hg.bg2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: active ? Hg.brand : Hg.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: active ? Hg.brand2 : Hg.text2,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(Drama drama) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FeedPage(initialDrama: drama)),
      ),
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
