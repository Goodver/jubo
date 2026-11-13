import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 网页版分类页目录（免签名）。
///
/// 本地引擎（短聚站源）的 App 接口只回真人剧，漫剧 / AI 剧分类返回空；
/// 网页版的 /category/{comic-drama|ai-drama|real-drama} 依然有全量数据，
/// 且 series_id 与 App 接口同一体系，播放仍然交给引擎按 series_id 解析。
class WebCatalog {
  WebCatalog._();

  static final WebCatalog instance = WebCatalog._();

  static const _base = 'https://hongguoduanju.com';
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; MI 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  /// 榜单页只有给搜索引擎 UA 时才吐结构性数据，普通 UA 拿到的是空壳
  static const _botUa =
      'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

  /// 分类键（引擎分类 id）→ 网页路由 + 展示名
  static const routes = <String, ({String path, String label})>{
    'comic_series': (path: 'comic-drama', label: '漫剧'),
    'ai_series': (path: 'ai-drama', label: 'AI剧'),
    'short_play': (path: 'real-drama', label: '真人剧'),
  };

  /// 榜单键 → 网页路由 + 展示名
  static const boards = <String, ({String path, String label})>{
    'hongguo': (path: 'hot-drama', label: '热播总榜'),
    'real': (path: 'hot-real-drama', label: '真人剧榜'),
    'comic': (path: 'hot-comic-drama', label: '漫剧榜'),
    'ai': (path: 'hot-ai-drama', label: 'AI剧榜'),
  };

  int _page = 0;
  bool _exhausted = false;

  bool get exhausted => _exhausted;

  void reset() {
    _page = 0;
    _exhausted = false;
  }

  /// 当前已翻到的页码（1-based，0 表示还没开始）。
  int get page => _page;

  /// 每个推荐流会话换一个随机起点页，别永远从热榜第 1 页开始取剧。
  void startFeedSession(int startPage) {
    reset();
    _page = startPage.clamp(1, 12) - 1;
  }

  /// 一次预取连续 count 页并合并去重；并发请求、先占页码避免取到同一页。
  /// 冷启动用多页混洗，避免只在单页那几十部剧里打转。
  Future<List<Drama>> seedPages(int count) async {
    final start = _page + 1;
    _page += count;
    final batches = await Future.wait([
      for (var i = 0; i < count; i++) _safeMixedPage(start + i),
    ]);
    final out = <Drama>[];
    final seen = <String>{};
    for (final rows in batches) {
      for (final drama in rows) {
        if (drama.id.isEmpty || !seen.add(drama.id)) continue;
        out.add(drama);
      }
    }
    if (out.isEmpty) {
      // 随机起点越过了站点实际总页数：退回第 1 页，后面还能顺序翻完
      _page = 1;
      for (final drama in await _safeMixedPage(1)) {
        if (drama.id.isEmpty || !seen.add(drama.id)) continue;
        out.add(drama);
      }
    }
    return out;
  }

  Future<List<Drama>> _safeMixedPage(int page) async {
    try {
      return await mixedPage(page);
    } catch (_) {
      return const <Drama>[];
    }
  }

  /// 推荐流用：三类混一起，一页约 72 部
  Future<List<Drama>> nextPage() async {
    if (_exhausted) return const [];
    final page = _page + 1;
    final rows = await mixedPage(page);
    if (rows.isEmpty) {
      _exhausted = true;
      return const [];
    }
    _page = page;
    return rows;
  }

  /// 三类合并的指定页（片库「全部」用）
  Future<List<Drama>> mixedPage(int page) async {
    final results = await Future.wait(
      routes.values.map((route) => _fetchRoute(route.path, route.label, page)),
    );
    final out = <Drama>[];
    final seen = <String>{};
    for (final rows in results) {
      for (final drama in rows) {
        if (drama.id.isEmpty || !seen.add(drama.id)) continue;
        out.add(drama);
      }
    }
    return out;
  }

  /// 片库用：按单个分类翻页
  Future<List<Drama>> categoryPage(String categoryId, int page) async {
    final route = routes[categoryId];
    if (route == null) return const [];
    return _fetchRoute(route.path, route.label, page);
  }

  // ------------------------------------------------------------------ 榜单

  /// 榜单列表（含名次与热度文案）
  Future<RankBoardPage> rankBoard(String boardKey, int page) async {
    final board = boards[boardKey];
    if (board == null) return const RankBoardPage([], false, 1, '');
    // 第 1 页带 ?page=1 会被 301 回无参地址，直接不带更稳
    final suffix = page <= 1 ? '' : '?page=$page';
    final body = await _get('$_base/rank/${board.path}$suffix', ua: _botUa);
    if (body == null) return RankBoardPage(const [], false, page, '');
    final data = _routerData(body);
    if (data == null) return RankBoardPage(const [], false, page, '');
    final loader = data['loaderData'];
    if (loader is! Map) return RankBoardPage(const [], false, page, '');

    // key 形如 rank_hot-drama/page，取第一个带 content 的
    Map? node;
    for (final value in loader.values) {
      if (value is Map && value['content'] is Map) {
        node = Map<String, dynamic>.from(value);
        break;
      }
    }
    if (node == null) return RankBoardPage(const [], false, page, '');
    final content = node['content'] as Map;
    final list = content['rankList'];
    if (list is! List) return RankBoardPage(const [], false, page, '');

    final pagination = content['pagination'];
    var hasMore = false;
    if (pagination is Map) {
      final total = _int(pagination['totalPages']);
      final current = _int(pagination['pageNum']);
      hasMore = total > 0 && current < total;
    }

    final out = <RankEntry>[];
    for (final row in list) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final seriesId = _text(map['seriesId']);
      final title = _text(map['title']);
      if (seriesId.isEmpty || title.isEmpty) continue;
      final tags = <String>[];
      for (final tag in (map['tags'] as List? ?? const [])) {
        final value = _text(tag);
        if (value.isNotEmpty && !tags.contains(value)) tags.add(value);
      }
      final status = <String>[];
      for (final tag in (map['statusTags'] as List? ?? const [])) {
        final value = _text(tag);
        if (value.isNotEmpty) status.add(value);
      }
      out.add(
        RankEntry(
          rank: _int(map['rank']) > 0 ? _int(map['rank']) : out.length + 1,
          heat: _text(map['heatText']),
          score: _text(map['scoreText']),
          favorite: _text(map['favoriteText']),
          like: _text(map['likeText']),
          status: status,
          drama: Drama({
            'id': 'hongguo:$seriesId',
            'source': 'hongguo',
            'sourceId': seriesId,
            'title': title,
            'description': _text(map['description']),
            'cover': _text(map['cover']),
            'episodes': _int(map['episodeCount']),
            'category': board.label,
            'tags': [...status, ...tags],
          }),
        ),
      );
    }
    return RankBoardPage(out, hasMore, page, _text(node['updatedText']));
  }

  // ------------------------------------------------------------------ 搜索

  /// 关键词搜索（支持分页）
  Future<SearchPage> search(String keyword, int page) async {
    final query = keyword.trim();
    if (query.isEmpty) return const SearchPage([], false, 0);
    final uri = Uri.parse(
      '$_base/api/search/result/',
    ).replace(queryParameters: {'query': query, 'page': '$page'});
    final body = await _get(uri.toString());
    if (body == null) return const SearchPage([], false, 0);
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const SearchPage([], false, 0);
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return const SearchPage([], false, 0);
    }
    final rows = json['searchList'];
    final total = _int(json['totalCount']);
    final totalPages = _int(json['totalPages']);
    final current = _int(json['pageNum']);
    final hasMore = json['hasMore'] == true || (totalPages > current);

    final out = <Drama>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final video = row['video_data'];
        if (video is! Map) continue;
        final seriesId = _text(video['series_id']);
        final title =
            _text(video['series_title']).isNotEmpty
            ? _text(video['series_title'])
            : _text(row['name']);
        if (seriesId.isEmpty || title.isEmpty) continue;
        final tags = <String>[];
        final genres = video['category_list'];
        if (genres is List) {
          for (final g in genres) {
            final value = g is Map
                ? _text(g['name'] ?? g['title'])
                : _text(g);
            if (value.isNotEmpty && !tags.contains(value)) tags.add(value);
          }
        }
        final genre = _text(video['genre']);
        // genre 是大类数字 id（205/203…），不是给人看的名字，跳过
        if (genre.isNotEmpty &&
            int.tryParse(genre) == null &&
            !tags.contains(genre)) {
          tags.insert(0, genre);
        }
        out.add(
          Drama({
            'id': 'hongguo:$seriesId',
            'source': 'hongguo',
            'sourceId': seriesId,
            'title': title,
            'description': _text(video['series_intro']),
            'cover': _text(video['series_cover']),
            'episodes': _int(video['episode_cnt']),
            'category': tags.isNotEmpty ? tags.first : '',
            'tags': tags,
          }),
        );
      }
    }
    return SearchPage(out, hasMore, total);
  }

  /// 搜索联想词
  Future<List<String>> suggest(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final uri = Uri.parse(
      '$_base/api/search/suggestion/',
    ).replace(queryParameters: {'query': query});
    final body = await _get(uri.toString());
    if (body == null) return const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final rows = decoded['suggestionList'];
      if (rows is! List) return const [];
      final out = <String>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final name = _text(row['name']);
        if (name.isNotEmpty && !out.contains(name)) out.add(name);
        if (out.length >= 8) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _get(String url, {String ua = _ua}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, ua);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/json;q=0.9,*/*;q=0.8',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Drama>> _fetchRoute(String path, String label, int page) async {
    final body = await _get('$_base/category/$path?page=$page');
    if (body == null) return const [];
    return _parse(body, label);
  }

  List<Drama> _parse(String body, String label) {
    final data = _routerData(body);
    if (data == null) return const [];
    final list = _findList(data, 'recommendList');
    if (list == null) return const [];
    final out = <Drama>[];
    for (final row in list) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final seriesId = _text(map['series_id']);
      if (seriesId.isEmpty) continue;
      final title = _text(map['series_name']);
      if (title.isEmpty) continue;
      final tags = <String>[];
      final rawTags = map['tags'];
      if (rawTags is List) {
        for (final tag in rawTags) {
          final value = _text(tag);
          if (value.isNotEmpty && !tags.contains(value)) tags.add(value);
        }
      }
      if (!tags.contains(label)) tags.insert(0, label);
      out.add(
        Drama({
          'id': 'hongguo:$seriesId',
          'source': 'hongguo',
          'sourceId': seriesId,
          'title': title,
          'description': _text(map['series_intro']),
          'cover': _text(map['series_cover']),
          'episodes': int.tryParse(_text(map['episode_cnt'])) ?? 0,
          'category': label,
          'tags': tags,
        }),
      );
    }
    return out;
  }

  Map<String, dynamic>? _routerData(String body) {
    final marker = body.indexOf('_ROUTER_DATA');
    if (marker < 0) return null;
    final start = body.indexOf('{', marker);
    if (start < 0) return null;
    final raw = _sliceObject(body, start);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  /// 从 start 处的 { 开始，配平括号截出完整 JSON（跳过字符串内的括号）
  String? _sliceObject(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{' || ch == '[') {
        depth++;
      } else if (ch == '}' || ch == ']') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  List<Object?>? _findList(Object? node, String key, [int depth = 0]) {
    if (depth > 12) return null;
    if (node is Map) {
      final value = node[key];
      if (value is List) return value;
      for (final entry in node.values) {
        final found = _findList(entry, key, depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findList(item, key, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _text(Object? value) {
    if (value == null) return '';
    final text = value.toString().trim();
    if (text == 'null') return '';
    return text;
  }

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(_text(value)) ?? 0;
  }
}

/// 榜单页里的一行：名次 / 热度文案 + 剧本身
class RankEntry {
  const RankEntry({
    required this.rank,
    required this.drama,
    this.heat = '',
    this.score = '',
    this.favorite = '',
    this.like = '',
    this.status = const [],
  });

  final int rank;
  final Drama drama;
  final String heat;
  final String score;
  final String favorite;
  final String like;
  final List<String> status;
}

class RankBoardPage {
  const RankBoardPage(this.items, this.hasMore, this.page, this.updatedText);

  final List<RankEntry> items;
  final bool hasMore;
  final int page;
  final String updatedText;
}

class SearchPage {
  const SearchPage(this.items, this.hasMore, this.total);

  final List<Drama> items;
  final bool hasMore;
  final int total;
}
