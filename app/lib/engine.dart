import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'models.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _rawRequest(String body) {
  final lib = DynamicLibrary.open('libhgnative.so');
  final request = lib.lookupFunction<_NativeRequest, _DartRequest>('HgRequest');
  final free = lib.lookupFunction<_NativeFree, _DartFree>('HgFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) throw const AppFailure('引擎没有返回结果');
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) free(output);
  }
}

class AppFailure implements Exception {
  const AppFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class Engine {
  Engine._();
  static final Engine instance = Engine._();
  static int _sequence = 0;

  Future<void> initialize(String directory) =>
      _call({'action': 'initialize', 'directory': directory});

  Future<CatalogPage> catalog({int page = 1, String category = ''}) async {
    final data = await _call({
      'action': 'catalog',
      'source': 'hongguo',
      'page': page,
      'category': category,
    });
    return CatalogPage.fromJson(data);
  }

  /// 推荐流（对应桌面版 RecommendTab）
  Future<CatalogPage> recommendations({
    String genre = '',
    bool more = false,
    bool force = false,
  }) async {
    final data = await _call({
      'action': 'recommendations',
      'source': 'hongguo',
      'category': genre,
      'command': more ? 'more' : '',
      'force': force,
      'page': 1,
    });
    return CatalogPage.fromJson(data);
  }

  /// 引擎侧关键词搜索：Go 的 catalog action 传 query 时会走红果搜索。
  /// 主页搜索首选 WebCatalog（真分页、带联想），这里作为网页源失败时的兜底。
  Future<CatalogPage> search(String query) async {
    final data = await _call({
      'action': 'catalog',
      'source': 'hongguo',
      'query': query,
      'page': 1,
      'category': '',
    });
    return CatalogPage.fromJson(data);
  }

  /// 搜索联想词（Go 的 suggestions action）。
  Future<List<String>> suggestions(String query) async {
    final data = await _call({'action': 'suggestions', 'query': query});
    return <String>[
      for (final dynamic e in data['items'] as List? ?? const <dynamic>[])
        e.toString(),
    ];
  }

  Future<List<CatalogCategory>> categories() async {
    final data = await _call({'action': 'categories', 'source': 'hongguo'});
    final rows = data['items'] as List? ?? const [];
    return [
      for (final row in rows)
        if (row is Map)
          CatalogCategory.fromJson(Map<String, dynamic>.from(row)),
    ];
  }

  Future<DramaDetail> detail(Drama drama) async {
    final data = await _call({'action': 'detail', 'drama': drama.toJson()});
    return DramaDetail.fromJson(data);
  }

  /// 所有 resolve 串行执行：引擎是全局单飞，新 sequence 会取消在途请求，
  /// 并发发出只会互相取消。stillValid 作废的票据不再「撞号重试」。
  static Future<void> _resolveTail = Future<void>.value();

  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool Function()? stillValid,
  }) {
    final next = _resolveTail.then(
      (_) => _resolveOnce(drama, episode, quality, stillValid: stillValid),
    );
    _resolveTail = next.then<void>((_) {}).catchError((_) {});
    return next;
  }

  Future<PlaybackPlan> _resolveOnce(
    Drama drama,
    Episode episode,
    int quality, {
    bool Function()? stillValid,
  }) async {
    Future<PlaybackPlan> once() async {
      final data = await _call({
        'action': 'resolve',
        'drama': drama.toJson(),
        'chapter': episode.raw,
        'index': episode.number,
        'quality': quality,
        'sequence': _nextSequence(),
      });
      return PlaybackPlan.fromJson(data);
    }

    try {
      return await once();
    } on AppFailure catch (error) {
      // 引擎按 sequence 判重：号码不大于上一次就当成本次请求已被取消。
      // 只有票据仍然有效时才换更大的号重试一次，否则把取消直接抛给调用方。
      if (!isCanceled(error.message)) rethrow;
      if (stillValid != null && !stillValid()) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (stillValid != null && !stillValid()) rethrow;
      return once();
    }
  }

  /// 下一次请求序号：单调递增，且跨 App 重建也不会退回小数字。
  ///
  /// 引擎（Go 侧）会记住某个 session 上次用到的 sequence，小于等于就直接返回
  /// context canceled。Dart 侧如果只用 1、2、3 这样的计数器，Flutter 引擎被系统
  /// 回收后重建时计数器会从 0 重新开始，之后每次解析都会失败，必须杀进程才能恢复。
  static int _nextSequence() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _sequence = now > _sequence ? now : _sequence + 1;
    return _sequence;
  }

  static bool isCanceled(String message) {
    final text = message.toLowerCase();
    return text.contains('context canceled') ||
        text.contains('context cancelled') ||
        message.contains('已取消');
  }

  Future<void> release(String session) async {
    if (session.isEmpty) return;
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }

  /// 读取当前的播放自定义设备号。
  Future<PlaybackDevice> playbackDevice() async {
    final data = await _call({'action': 'playbackDevice'});
    return PlaybackDevice.fromJson(data);
  }

  /// 保存自定义设备号；传空字符串表示清除。
  ///
  /// profile 是「读取本机 ID」拿到的机型档案，跟着一起存下来，
  /// 让签名用的设备档案和这台真机保持一致。
  Future<PlaybackDevice> savePlaybackDevice({
    String did = '',
    String uid = '',
    PlaybackDevice profile = const PlaybackDevice(),
  }) async {
    final data = await _call({
      'action': 'savePlaybackDevice',
      'playbackDevice': {
        'did': did.trim(),
        'uid': uid.trim(),
        'brand': profile.brand,
        'model': profile.model,
        'osVersion': profile.osVersion,
        'osApi': profile.osApi,
        'resolution': profile.resolution,
        'dpi': profile.dpi,
        'abi': profile.abi,
      },
    });
    return PlaybackDevice.fromJson(data);
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    final body = jsonEncode(input);
    final encoded = await Isolate.run(() => _rawRequest(body)).timeout(
      const Duration(seconds: 40),
      onTimeout: () => throw const AppFailure('站源响应超时'),
    );
    final response = jsonDecode(encoded);
    if (response is! Map) throw const AppFailure('引擎返回格式异常');
    if (response['ok'] != true) {
      throw AppFailure(response['error']?.toString() ?? '读取失败');
    }
    final data = response['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    // release / cancelPlayback 本来就返回非 Map，放行；取数据的动作必须给 Map
    const dataActions = <String>{
      'catalog',
      'recommendations',
      'categories',
      'detail',
      'resolve',
      'fallback',
      'playbackDevice',
      'savePlaybackDevice',
      'metadata',
    };
    if (dataActions.contains(input['action'])) {
      throw const AppFailure('引擎返回格式异常');
    }
    return <String, dynamic>{};
  }
}
