import 'package:flutter/material.dart';

import 'feed_page.dart';
import 'models.dart';
import 'store.dart';
import 'theme.dart';

Route<void> historyRoute() =>
    MaterialPageRoute(builder: (_) => const HistoryPage());

/// 观看记录：每部剧一条，点进去从上次那集接着播
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<({String id, WatchMark mark})> get _rows => Store.instance.markList;

  Future<void> _open(({String id, WatchMark mark}) row) async {
    final raw = row.mark.drama;
    if (raw == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这条记录缺少分集信息，去片库搜一下这部剧吧'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(milliseconds: 1800),
        ),
      );
      return;
    }
    final drama = Drama.fromJson(Map<String, dynamic>.from(raw));
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FeedPage(initialDrama: drama)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _remove(({String id, WatchMark mark}) row) async {
    final name = row.mark.title.isEmpty ? '这条记录' : '《${row.mark.title}》';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Hg.bg1,
        title: const Text(
          '删除记录',
          style: TextStyle(fontSize: 16, color: Hg.text),
        ),
        content: Text(
          '把$name的观看记录删掉？（点赞和追剧不受影响）',
          style: const TextStyle(fontSize: 13.5, color: Hg.text2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留', style: TextStyle(color: Hg.text2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Hg.brand2)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Store.instance.removeMark(row.id);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _clearAll() async {
    if (_rows.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Hg.bg1,
        title: const Text(
          '清空观看记录',
          style: TextStyle(fontSize: 16, color: Hg.text),
        ),
        content: const Text(
          '所有剧的观看进度都会清掉，点赞和追剧保留。',
          style: TextStyle(fontSize: 13.5, color: Hg.text2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Hg.text2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(color: Hg.brand2)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Store.instance.clearPlayback();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清空观看记录'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: 1500),
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
            const Text(
              '观看记录',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Hg.text,
              ),
            ),
            Text(
              rows.isEmpty ? '暂无记录' : '共${rows.length}部',
              style: const TextStyle(fontSize: 11, color: Hg.text3),
            ),
          ],
        ),
        actions: [
          if (rows.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: const Text(
                '清空',
                style: TextStyle(fontSize: 13, color: Hg.text2),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: rows.isEmpty ? _empty() : _list(rows),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.history_rounded,
            size: 44,
            color: Hg.text3,
          ),
          const SizedBox(height: 12),
          const Text(
            '还没有观看记录',
            style: TextStyle(fontSize: 13.5, color: Hg.text2),
          ),
          const SizedBox(height: 6),
          const Text(
            '随便播一部剧，这里就会自动记下看到哪了',
            style: TextStyle(fontSize: 11.5, color: Hg.text3),
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

  Widget _list(List<({String id, WatchMark mark})> rows) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      itemCount: rows.length,
      itemBuilder: (context, index) => _row(rows[index]),
    );
  }

  Widget _row(({String id, WatchMark mark}) row) {
    final mark = row.mark;
    final total = mark.drama == null
        ? 0
        : Drama.fromJson(Map<String, dynamic>.from(mark.drama!)).episodeCount;
    final progress = _clock(mark.ms);
    final when = _ago(mark.at);
    final sub = [
      '第${mark.episode}集',
      if (total > 0) '共$total集',
      if (mark.ms > 0) '看到 $progress',
      when,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Hg.bg1,
        borderRadius: BorderRadius.circular(Hg.radius),
        child: InkWell(
          onTap: () => _open(row),
          onLongPress: () => _remove(row),
          borderRadius: BorderRadius.circular(Hg.radius),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 56,
                    height: 74,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Hg.bg2),
                        if (mark.cover.isNotEmpty)
                          Image.network(
                            mark.cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const SizedBox.shrink(),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mark.title.isEmpty ? '未知剧集' : mark.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                          color: Hg.text,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: Hg.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: Hg.text3,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _clock(int ms) {
    if (ms <= 0) return '00:00';
    final total = ms ~/ 1000;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _ago(int at) {
    if (at <= 0) return '';
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(at),
    );
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${DateTime.fromMillisecondsSinceEpoch(at).year}-'
        '${DateTime.fromMillisecondsSinceEpoch(at).month.toString().padLeft(2, '0')}-'
        '${DateTime.fromMillisecondsSinceEpoch(at).day.toString().padLeft(2, '0')}';
  }
}
