import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 一部剧的观看记录（对应桌面版 SaveProgress / watchedEpisode）
class WatchMark {
  const WatchMark({
    required this.episode,
    required this.ms,
    this.title = '',
    this.cover = '',
    this.at = 0,
    this.drama,
  });

  final int episode;
  final int ms;
  final String title;
  final String cover;
  final int at;
  final Map<String, dynamic>? drama;

  Map<String, dynamic> toJson() => {
    'ep': episode,
    'ms': ms,
    'title': title,
    'cover': cover,
    'at': at,
    if (drama != null) 'drama': drama,
  };

  static WatchMark fromJson(Map<String, dynamic> json) => WatchMark(
    episode: _int(json['ep']),
    ms: _int(json['ms']),
    title: json['title']?.toString() ?? '',
    cover: json['cover']?.toString() ?? '',
    at: _int(json['at']),
    drama: json['drama'] is Map
        ? Map<String, dynamic>.from(json['drama'] as Map)
        : null,
  );
}

/// 点赞 / 追剧里存的一条剧：够画一张卡片，也够直接开播
class SavedDrama {
  const SavedDrama({
    required this.id,
    required this.title,
    this.cover = '',
    this.category = '',
    this.episodes = 0,
    this.at = 0,
    this.raw,
  });

  factory SavedDrama.of(Drama drama) => SavedDrama(
    id: drama.id,
    title: drama.title,
    cover: drama.cover,
    category: drama.category,
    episodes: drama.episodeCount,
    at: DateTime.now().millisecondsSinceEpoch,
    raw: drama.toJson(),
  );

  final String id;
  final String title;
  final String cover;
  final String category;
  final int episodes;
  final int at;

  /// 原始剧集 JSON（引擎按这个字段解析播放）
  final Map<String, dynamic>? raw;

  Drama? get drama =>
      raw == null ? null : Drama.fromJson(Map<String, dynamic>.from(raw!));

  bool get hasDetail => raw != null;

  String get caption => [
    if (category.isNotEmpty) category,
    if (episodes > 0) '共$episodes集',
  ].join(' · ');

  /// 老数据（只存了 id）补上剧集信息
  SavedDrama merge(Drama drama) => SavedDrama(
    id: id,
    title: drama.title.isEmpty ? title : drama.title,
    cover: drama.cover.isEmpty ? cover : drama.cover,
    category: drama.category.isEmpty ? category : drama.category,
    episodes: drama.episodeCount > 0 ? drama.episodeCount : episodes,
    at: at,
    raw: drama.toJson(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'category': category,
    'episodes': episodes,
    'at': at,
    if (raw != null) 'raw': raw,
  };

  static SavedDrama? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return SavedDrama(
      id: id,
      title: value['title']?.toString() ?? '',
      cover: value['cover']?.toString() ?? '',
      category: value['category']?.toString() ?? '',
      episodes: _int(value['episodes']),
      at: _int(value['at']),
      raw: value['raw'] is Map
          ? Map<String, dynamic>.from(value['raw'] as Map)
          : null,
    );
  }
}

class Store {
  Store._();
  static final Store instance = Store._();

  static const _kMarks = 'hg.marks.v2';
  static const _kWatched = 'hg.watched.v2';

  /// 观看记录最多保留多少部（超出后按最久未看淘汰）
  static const markLimit = 200;

  // 旧格式：只存 id 的字符串列表（保留用于迁移）
  static const _kLikesLegacy = 'hg.likes.v2';
  static const _kFavsLegacy = 'hg.favs.v2';

  // 新格式：带剧集快照的 JSON 列表
  static const _kLikes = 'hg.likes.v3';
  static const _kFavs = 'hg.favs.v3';

  SharedPreferences? _prefs;
  Map<String, WatchMark> _marks = {};
  Map<String, Set<int>> _watched = {};

  /// 插入顺序即展示顺序：最新点的排最前
  Map<String, SavedDrama> _likes = {};
  Map<String, SavedDrama> _favs = {};

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _marks = _decodeMarks(_prefs!.getString(_kMarks));
    final rawWatched = _prefs!.getString(_kWatched);
    if (rawWatched != null && rawWatched.isNotEmpty) {
      try {
        final map = jsonDecode(rawWatched);
        if (map is Map) {
          _watched = {
            for (final entry in map.entries)
              entry.key.toString(): {
                for (final v in (entry.value as List? ?? const [])) _int(v),
              },
          };
        }
      } catch (_) {}
    }
    _likes = await _loadSaved(_kLikes, _kLikesLegacy);
    _favs = await _loadSaved(_kFavs, _kFavsLegacy);
    _backfillSnapshots();
    _trimMarks();
  }

  // --------------------------------------------------- 推荐流乱序会话

  static const _kFeedRecent = 'hg.feed.recent.v1';
  static const _kFeedStart = 'hg.feed.start.v1';

  /// 跨会话记住最近刷到过的剧：不然每次打开 APP 又被同一批热榜剧打头。
  List<String> feedRecent() {
    final rows = _prefs?.getStringList(_kFeedRecent);
    if (rows == null || rows.isEmpty) return <String>[];
    return <String>[for (final id in rows) if (id.isNotEmpty) id];
  }

  Future<void> saveFeedRecent(List<String> ids) async {
    await _prefs?.setStringList(_kFeedRecent, List<String>.from(ids));
  }

  /// 上次会话的随机起点页，用来保证这次起点不撞上次。
  int feedStartPage() => _prefs?.getInt(_kFeedStart) ?? 0;

  Future<void> saveFeedStartPage(int page) async {
    await _prefs?.setInt(_kFeedStart, page);
  }

  // ------------------------------------------------------------- 观看记录

  static Map<String, WatchMark> _decodeMarks(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return {};
      return {
        for (final entry in map.entries)
          if (entry.value is Map)
            entry.key.toString(): WatchMark.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } catch (_) {
      return {};
    }
  }

  WatchMark? mark(String seriesId) => _marks[seriesId];

  /// 最近观看的剧（用于启动续播）
  WatchMark? get latest {
    WatchMark? best;
    for (final mark in _marks.values) {
      if (best == null || mark.at > best.at) best = mark;
    }
    return best;
  }

  int get watchCount => _marks.length;

  /// 观看记录，最近的排在前面
  List<({String id, WatchMark mark})> get markList {
    final rows = _marks.entries
        .map((e) => (id: e.key, mark: e.value))
        .toList();
    rows.sort((a, b) => b.mark.at.compareTo(a.mark.at));
    return rows;
  }

  Future<void> removeMark(String seriesId) async {
    if (_marks.remove(seriesId) == null) return;
    _watched.remove(seriesId);
    await _flushMarks();
  }

  /// 超过上限时丢掉最久没看的那些（点赞、追剧里的条目不受影响）
  void _trimMarks() {
    if (_marks.length <= markLimit) return;
    final rows = _marks.entries.toList()
      ..sort((a, b) => b.value.at.compareTo(a.value.at));
    _marks = {for (final row in rows.take(markLimit)) row.key: row.value};
  }

  Future<void> _flushMarks() async {
    await _prefs?.setString(
      _kMarks,
      jsonEncode({for (final e in _marks.entries) e.key: e.value.toJson()}),
    );
  }

  Future<void> saveMark(
    String seriesId, {
    required int episode,
    required int ms,
    String title = '',
    String cover = '',
    Map<String, dynamic>? drama,
  }) async {
    _marks[seriesId] = WatchMark(
      episode: episode,
      ms: ms,
      title: title,
      cover: cover,
      at: DateTime.now().millisecondsSinceEpoch,
      drama: drama,
    );
    // 顺手给早期只存了 id 的点赞 / 追剧补上封面
    if (drama != null) {
      final parsed = Drama.fromJson(Map<String, dynamic>.from(drama));
      for (final map in [_likes, _favs]) {
        final saved = map[seriesId];
        if (saved != null && !saved.hasDetail) {
          map[seriesId] = saved.merge(parsed);
        }
      }
    }
    _trimMarks();
    await _flushMarks();
  }

  Set<int> watched(String seriesId) => _watched[seriesId] ?? const {};

  Future<void> markWatched(String seriesId, int episode) async {
    final set = _watched.putIfAbsent(seriesId, () => <int>{});
    if (!set.add(episode)) return;
    if (set.length > 400) {
      final sorted = set.toList()..sort();
      set
        ..clear()
        ..addAll(sorted.sublist(sorted.length - 300));
    }
    await _prefs?.setString(
      _kWatched,
      jsonEncode({for (final e in _watched.entries) e.key: e.value.toList()}),
    );
  }

  /// 清空「播放记录」：观看进度 + 已看集数标记。
  /// 点赞、追剧不在这里动（设置里的清空缓存也走这个方法）。
  Future<void> clearPlayback() async {
    _marks.clear();
    _watched.clear();
    await _prefs?.remove(_kMarks);
    await _prefs?.remove(_kWatched);
  }

  // ------------------------------------------------------------- 点赞/追剧

  Future<Map<String, SavedDrama>> _loadSaved(
    String key,
    String legacyKey,
  ) async {
    final prefs = _prefs;
    if (prefs == null) return {};
    if (prefs.containsKey(key)) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return {};
      try {
        final list = jsonDecode(raw);
        if (list is! List) return {};
        final out = <String, SavedDrama>{};
        for (final row in list) {
          final item = SavedDrama.fromJson(row);
          if (item != null) out[item.id] = item;
        }
        return out;
      } catch (_) {
        return {};
      }
    }
    // 首次升级：把老的 id 列表搬过来，并补上观看记录里的封面
    final legacy = prefs.getStringList(legacyKey) ?? const <String>[];
    if (legacy.isEmpty) return {};
    final out = <String, SavedDrama>{};
    for (final id in legacy.reversed) {
      final mark = _marks[id];
      out[id] = SavedDrama(
        id: id,
        title: mark?.title ?? '',
        cover: mark?.cover ?? '',
        at: mark?.at ?? 0,
      );
    }
    await prefs.setString(
      key,
      jsonEncode([for (final item in out.values) item.toJson()]),
    );
    await prefs.remove(legacyKey);
    return out;
  }

  void _backfillSnapshots() {
    for (final map in [_likes, _favs]) {
      for (final entry in map.entries.toList()) {
        final saved = entry.value;
        if (saved.hasDetail) continue;
        final mark = _marks[saved.id];
        if (mark == null) continue;
        if (mark.drama != null) {
          map[saved.id] = saved.merge(
            Drama.fromJson(Map<String, dynamic>.from(mark.drama!)),
          );
        } else if (mark.title.isNotEmpty && saved.title.isEmpty) {
          map[saved.id] = SavedDrama(
            id: saved.id,
            title: mark.title,
            cover: mark.cover,
            at: saved.at,
          );
        }
      }
    }
  }

  List<SavedDrama> get likeList => _likes.values.toList();
  List<SavedDrama> get favList => _favs.values.toList();
  int get likeCount => _likes.length;
  int get favCount => _favs.length;

  bool isLiked(String seriesId) => _likes.containsKey(seriesId);
  bool isFav(String seriesId) => _favs.containsKey(seriesId);

  Future<void> toggleLike(Drama drama) async {
    if (_likes.remove(drama.id) == null) {
      _putFront(_likes, SavedDrama.of(drama));
    }
    await _save(_kLikes, _likes);
  }

  Future<void> toggleFav(Drama drama) async {
    if (_favs.remove(drama.id) == null) {
      _putFront(_favs, SavedDrama.of(drama));
    }
    await _save(_kFavs, _favs);
  }

  Future<void> removeLike(String seriesId) async {
    if (_likes.remove(seriesId) == null) return;
    await _save(_kLikes, _likes);
  }

  Future<void> removeFav(String seriesId) async {
    if (_favs.remove(seriesId) == null) return;
    await _save(_kFavs, _favs);
  }

  /// 清空点赞 / 追剧（长按逐条删除之外的一次性操作，暂未挂到界面上）
  Future<void> clearLikes() async {
    _likes.clear();
    await _save(_kLikes, _likes);
  }

  Future<void> clearFavs() async {
    _favs.clear();
    await _save(_kFavs, _favs);
  }

  void _putFront(Map<String, SavedDrama> map, SavedDrama item) {
    final rows = map.entries.toList();
    map
      ..clear()
      ..[item.id] = item;
    for (final row in rows) {
      if (row.key == item.id) continue;
      map[row.key] = row.value;
    }
  }

  Future<void> _save(String key, Map<String, SavedDrama> map) async {
    await _prefs?.setString(
      key,
      jsonEncode([for (final item in map.values) item.toJson()]),
    );
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value == null) return 0;
  return int.tryParse(value.toString()) ?? 0;
}
