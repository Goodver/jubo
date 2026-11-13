import 'package:flutter/material.dart';

import 'feed_page.dart';
import 'theme.dart';
import 'webcat.dart';

Route<void> rankRoute() => MaterialPageRoute(builder: (_) => const RankPage());

/// 分类排行榜：网页版 /rank/* 的榜单，四类分开看
class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  static const _keys = ['hongguo', 'real', 'comic', 'ai'];

  final _scroll = ScrollController();
  final _items = <RankEntry>[];
  String _board = 'hongguo';
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  String _error = '';
  String _updated = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 700) {
        _load();
      }
    });
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;
    setState(() {
      _loading = true;
      if (reset) _error = '';
    });
    final next = reset ? 1 : _page + 1;
    final target = _board;
    try {
      final result = await WebCatalog.instance.rankBoard(target, next);
      if (!mounted || target != _board) return;
      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(result.items);
        } else {
          _items.addAll(result.items);
        }
        _page = next;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _updated = result.updatedText;
        if (_items.isEmpty) _error = '这个榜单暂时没有数据';
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

  void _switch(String key) {
    if (_board == key) return;
    setState(() {
      _board = key;
      _items.clear();
      _page = 0;
      _hasMore = true;
      _updated = '';
      _error = '';
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        titleSpacing: 16,
        title: const Text(
          '榜单',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
        actions: [
          IconButton(
            onPressed: () => _load(reset: true),
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Hg.text2),
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final key in _keys)
                  _chip(
                    WebCatalog.boards[key]?.label ?? key,
                    key,
                  ),
              ],
            ),
          ),
          if (_updated.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _updated,
                  style: const TextStyle(fontSize: 11.5, color: Hg.text3),
                ),
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                _error,
                style: const TextStyle(fontSize: 12.5, color: Hg.brand2),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              itemCount: _items.length + (_loading ? 3 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) return _skeleton(index - _items.length);
                return _row(_items[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String key) {
    final active = key == _board;
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 7, bottom: 7),
      child: GestureDetector(
        onTap: () => _switch(key),
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

  Widget _skeleton(int i) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      height: 104,
      decoration: BoxDecoration(
        color: Hg.bg2,
        borderRadius: BorderRadius.circular(Hg.radius),
      ),
    );
  }

  Widget _row(RankEntry entry) {
    final drama = entry.drama;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => FeedPage(initialDrama: drama))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: Hg.bg1,
          borderRadius: BorderRadius.circular(Hg.radius),
          border: Border.all(color: Hg.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 26, child: _rankBadge(entry.rank)),
            const SizedBox(width: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 66,
                height: 88,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Hg.bg3),
                    if (drama.cover.isNotEmpty)
                      Image.network(
                        drama.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    drama.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.28,
                      fontWeight: FontWeight.w600,
                      color: Hg.text,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (entry.heat.isNotEmpty)
                        _metric(entry.heat, Icons.local_fire_department_rounded),
                      if (entry.score.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _metric(entry.score, Icons.star_rounded),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (drama.episodeCount > 0) '共${drama.episodeCount}集',
                      if (entry.favorite.isNotEmpty) entry.favorite,
                      if (entry.like.isNotEmpty) entry.like,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Hg.text3),
                  ),
                  if (drama.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      drama.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: Hg.text2),
                    ),
                  ],
                  if (drama.tags.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        for (final tag in drama.tags.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Hg.bg3,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Hg.text2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String text, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Hg.brand2),
        const SizedBox(width: 2),
        Text(text, style: const TextStyle(fontSize: 11.5, color: Hg.brand2)),
      ],
    );
  }

  Widget _rankBadge(int rank) {
    if (rank <= 3) {
      const colors = [
        Color(0xFFFF4D4F),
        Color(0xFFFF8A3D),
        Color(0xFFFFC53D),
      ];
      return Container(
        width: 24,
        height: 24,
        margin: const EdgeInsets.only(top: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors[rank - 1],
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$rank',
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '$rank',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Hg.text3,
        ),
      ),
    );
  }
}
