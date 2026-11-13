import 'package:flutter/material.dart';

import 'feed_page.dart';
import 'store.dart';
import 'theme.dart';

Route<void> savedRoute({required bool likes}) =>
    MaterialPageRoute(builder: (_) => SavedPage(likes: likes));

/// 我的点赞 / 我的追剧：同一套三列网格，长按剧照可删除
class SavedPage extends StatefulWidget {
  const SavedPage({super.key, required this.likes});

  final bool likes;

  @override
  State<SavedPage> createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
  List<SavedDrama> get _rows =>
      widget.likes ? Store.instance.likeList : Store.instance.favList;

  String get _title => widget.likes ? '我的点赞' : '我的追剧';

  Future<void> _open(SavedDrama saved) async {
    final drama = saved.drama;
    if (drama == null) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这部剧缺少分集信息，请到片库搜索打开'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(milliseconds: 1800),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FeedPage(initialDrama: drama)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _confirmRemove(SavedDrama saved) async {
    final name = saved.title.isEmpty ? '这部剧' : '《${saved.title}》';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Hg.bg1,
        title: Text(
          widget.likes ? '取消点赞' : '取消追剧',
          style: const TextStyle(fontSize: 16, color: Hg.text),
        ),
        content: Text(
          '把$name从这里移除？',
          style: const TextStyle(fontSize: 13.5, color: Hg.text2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留', style: TextStyle(color: Hg.text2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除', style: TextStyle(color: Hg.brand2)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (widget.likes) {
      await Store.instance.removeLike(saved.id);
    } else {
      await Store.instance.removeFav(saved.id);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已移除$name'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Hg.text,
              ),
            ),
            Text(
              rows.isEmpty ? '暂无内容' : '共${rows.length}部',
              style: const TextStyle(fontSize: 11, color: Hg.text3),
            ),
          ],
        ),
      ),
      body: rows.isEmpty
          ? _empty()
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.54,
                crossAxisSpacing: 10,
                mainAxisSpacing: 16,
              ),
              itemCount: rows.length,
              itemBuilder: (context, index) => _card(rows[index]),
            ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.likes
                ? Icons.favorite_border_rounded
                : Icons.star_border_rounded,
            size: 44,
            color: Hg.text3,
          ),
          const SizedBox(height: 12),
          Text(
            widget.likes ? '还没有点赞过的短剧' : '还没有追的剧',
            style: const TextStyle(fontSize: 13.5, color: Hg.text2),
          ),
          const SizedBox(height: 6),
          Text(
            widget.likes ? '播放时点右侧的「点赞」就会收进来' : '播放时点右侧的「追剧」就会收进来',
            style: const TextStyle(fontSize: 11.5, color: Hg.text3),
          ),
          const SizedBox(height: 18),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('去片库逛逛', style: TextStyle(color: Hg.brand2)),
          ),
        ],
      ),
    );
  }

  Widget _card(SavedDrama saved) {
    return GestureDetector(
      onTap: () => _open(saved),
      onLongPress: () => _confirmRemove(saved),
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
                  if (saved.cover.isNotEmpty)
                    Image.network(
                      saved.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xAA000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        widget.likes
                            ? Icons.favorite_rounded
                            : Icons.star_rounded,
                        size: 12,
                        color: widget.likes ? Hg.likeOn : Hg.favOn,
                      ),
                    ),
                  ),
                  if (saved.episodes > 0)
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
                          '共${saved.episodes}集',
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
            saved.title.isEmpty ? '未知剧集' : saved.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.28,
              color: Hg.text,
            ),
          ),
          Text(
            saved.caption.isEmpty ? '长按可移除' : saved.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Hg.text3),
          ),
        ],
      ),
    );
  }
}
