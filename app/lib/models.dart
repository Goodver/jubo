class Drama {
  Drama(this.raw);
  final Map<String, dynamic> raw;

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(json);

  Map<String, dynamic> toJson() => raw;

  String get id => raw['id']?.toString() ?? '';
  String get title => raw['title']?.toString() ?? '未命名';
  String get cover => raw['cover']?.toString() ?? '';
  String get description => raw['description']?.toString() ?? '';
  String get category => raw['category']?.toString() ?? '';
  int get episodeCount => _int(raw['episodes']);
  String get releaseStatus => raw['releaseStatus']?.toString() ?? '';
  List<String> get tags =>
      (raw['tags'] as List? ?? const []).map((e) => e.toString()).toList();
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id']?.toString() ?? '',
      title = raw['title']?.toString() ?? '第$fallback集',
      number = _int(raw['currentEpisode']) > 0
          ? _int(raw['currentEpisode'])
          : fallback;

  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, this.warning);

  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    final dramaRaw = json['drama'];
    return DramaDetail(
      Drama.fromJson(
        dramaRaw is Map ? Map<String, dynamic>.from(dramaRaw) : <String, dynamic>{},
      ),
      [
        for (var i = 0; i < rows.length; i++)
          if (rows[i] is Map)
            Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      json['warning']?.toString() ?? '',
    );
  }

  final Drama drama;
  final List<Episode> episodes;
  final String warning;
}

class CatalogPage {
  CatalogPage(this.items, this.hasMore, this.page, this.warning);

  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        if (row is Map) Drama.fromJson(Map<String, dynamic>.from(row)),
    ],
    json['hasMore'] == true,
    _int(json['page']) > 0 ? _int(json['page']) : 1,
    json['warning']?.toString() ?? '',
  );

  final List<Drama> items;
  final bool hasMore;
  final int page;
  final String warning;
}

class CatalogCategory {
  CatalogCategory(this.id, this.name);

  factory CatalogCategory.fromJson(Map<String, dynamic> json) => CatalogCategory(
    (json['id'] ?? json['value'] ?? json['key'] ?? '').toString(),
    (json['name'] ?? json['title'] ?? json['label'] ?? '').toString(),
  );

  final String id;
  final String name;
}

/// 信息流里的一屏：某一部剧的某一集（对应桌面版 feed 的 {series, episode}）
class FeedEntry {
  const FeedEntry({
    required this.drama,
    required this.episode,
    required this.index,
    required this.total,
  });

  final Drama drama;
  final Episode episode;

  /// 该集在本剧内的下标（0 起）
  final int index;
  final int total;

  int get number => episode.number;
  String get title => drama.title;
}

class PlaybackPlan {
  PlaybackPlan({
    required this.url,
    required this.headers,
    required this.decryptionKey,
    required this.quality,
    required this.session,
    required this.danmakuId,
    required this.local,
    required this.expiresAt,
    required this.routeIndex,
    required this.routeCount,
    required this.qualities,
  });

  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url']?.toString() ?? '',
    headers: {
      for (final entry in (json['headers'] as Map? ?? const {}).entries)
        entry.key.toString(): entry.value.toString(),
    },
    decryptionKey: json['decryptionKey']?.toString() ?? '',
    quality: _int(json['quality']),
    session: json['session']?.toString() ?? '',
    danmakuId: json['danmakuId']?.toString() ?? '',
    local: json['local'] == true,
    expiresAt: _int(json['expiresAt']),
    routeIndex: _int(json['routeIndex']),
    routeCount: _int(json['routeCount']) > 0 ? _int(json['routeCount']) : 1,
    qualities: [
      for (final q in (json['qualities'] as List? ?? const []))
        if (_int(q) > 0) _int(q),
    ]..sort((a, b) => b.compareTo(a)),
  );

  final String url;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final String session;
  final String danmakuId;
  final bool local;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final List<int> qualities;

  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value == null) return 0;
  return int.tryParse(value.toString()) ?? 0;
}

/// 播放用的自定义设备号（红果 App 里的 did / uid），取流兜底用。
///
/// 后面的机型字段来自「读取本机 ID」：带上它们之后，签名用的设备档案
/// （UA、分辨率、DPI、系统版本）才会和这台真机一致。
class PlaybackDevice {
  const PlaybackDevice({
    this.did = '',
    this.uid = '',
    this.configured = false,
    this.brand = '',
    this.model = '',
    this.osVersion = '',
    this.osApi = '',
    this.resolution = '',
    this.dpi = '',
    this.abi = '',
  });

  factory PlaybackDevice.fromJson(Map<String, dynamic> json) => PlaybackDevice(
    did: json['did']?.toString() ?? '',
    uid: json['uid']?.toString() ?? '',
    configured: json['configured'] == true,
    brand: json['brand']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    osVersion: json['osVersion']?.toString() ?? '',
    osApi: json['osApi']?.toString() ?? '',
    resolution: json['resolution']?.toString() ?? '',
    dpi: json['dpi']?.toString() ?? '',
    abi: json['abi']?.toString() ?? '',
  );

  final String did;
  final String uid;
  final bool configured;
  final String brand;
  final String model;
  final String osVersion;
  final String osApi;
  final String resolution;
  final String dpi;
  final String abi;

  /// 是否带着本机机型档案（用户点过「读取本机 ID」）。
  bool get hasProfile => model.isNotEmpty || osVersion.isNotEmpty;

  PlaybackDevice copyWith({String? did, String? uid}) => PlaybackDevice(
    did: did ?? this.did,
    uid: uid ?? this.uid,
    configured: (did ?? this.did).isNotEmpty || (uid ?? this.uid).isNotEmpty,
    brand: brand,
    model: model,
    osVersion: osVersion,
    osApi: osApi,
    resolution: resolution,
    dpi: dpi,
    abi: abi,
  );
}
