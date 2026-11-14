import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'engine.dart';
import 'library_page.dart';
import 'mine_page.dart';
import 'models.dart';
import 'nav.dart';
import 'store.dart';
import 'theme.dart';
import 'webcat.dart';

/// 单页信息流：
/// 一屏一部剧，每次会话换一套全新的乱序轮播（随机起点页 + 多页混洗）；
/// 上滑换下一部剧（避开最近看过的，跨会话也记），不滑则由本集顺着延续到下一集；
/// 右侧竖排操作栏、左下剧名/集数/简介、底部控制条、模糊封面铺底。
class FeedPage extends StatefulWidget {
  const FeedPage({super.key, this.initialDrama});

  final Drama? initialDrama;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

/// 一页 = 一部剧；页内换集不翻页，翻页 = 换剧。
class _Slot {
  _Slot(this.drama);

  final Drama drama;
  DramaDetail? detail;
  int epPos = 0;
}

/// 乱序轮播参数：每次会话在 [1, _kFeedStartPages] 里随机挑起点页，
/// 连续取 _kFeedSeedPageCount 页混在一起洗牌，起点还避开上一次会话。
const int _kFeedStartPages = 12;
const int _kFeedSeedPageCount = 2;

/// 一路播放器：自带画面纹理、当前解析结果，以及用完要还给引擎的 session。
class _Stage {
  _Stage();

  final Player player = Player();
  late final VideoController video = VideoController(player);

  /// 已经装好的内容，形如 `剧id#集号#清晰度`，用来判断能不能直接切过去
  String key = '';
  String session = '';
  PlaybackPlan? plan;
  bool warmed = false;
}

/// 预加载目标：下一集，或者下一部剧的第一集
class _Preload {
  const _Preload(this.drama, this.episode, this.key, this.start);

  final Drama drama;
  final Episode episode;
  final String key;
  final Duration? start;
}

class _FeedPageState extends State<FeedPage>
    with WidgetsBindingObserver, RouteAware {
  /// 三路播放器：一路在播，另两路分别把“下一集”“下一部剧的第一集”提前备好。
  /// 切集或滑屏时只是把画面挪过去，不用现解析、不用等缓冲，过渡段就没有那一下卡顿。
  final _stages = <_Stage>[_Stage(), _Stage(), _Stage()];
  int _stageIdx = 0;
  _Stage get _stage => _stages[_stageIdx];
  Player get _player => _stage.player;
  final _preloadingKeys = <String>{};
  bool _preloading = false;
  bool _preloadPending = false;
  final _subs = <StreamSubscription<dynamic>>[];

  PageController? _pages;

  /// 当前滚动位置（以“页”为单位的绝对页码，1.35 表示停在 1 号页往下 35%）。
  /// 画面虚化、换页过渡都读它，避免为了滚动时每帧重建整棵树。
  final _scrollPos = ValueNotifier<double>(0);

  final _slots = <_Slot>[];
  final _details = <String, DramaDetail>{};
  final _detailTasks = <String, Future<DramaDetail>>{};

  /// 随机池：全量片库（真人剧 + 漫剧 + AI 剧）
  final _pool = <Drama>[];
  final _all = <Drama>[];
  final _known = <String>{};
  final _recent = <String>[];
  // 用系统熵做种子：每次冷启动都是一条新的随机序列，不再有固定套路
  final _rng = math.Random.secure();

  int _catalogPage = 0;
  bool _poolLoading = false;
  bool _poolDone = false;
  bool _webDone = false;
  bool _engineDone = false;
  bool _exhausted = false;
  bool _appending = false;

  int _index = 0;
  int _generation = 0;
  bool _booting = false;

  bool _ready = false;
  bool _videoReady = false;
  bool _ui = true;
  bool _panel = false;
  bool _fullscreen = false;
  bool _suspended = false;
  bool _dragging = false;
  double _dragRatio = 0;
  double _rate = 1;
  int _quality = 0;
  List<int> _qualities = const [];

  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  int _vw = 0;
  int _vh = 0;
  bool _hint = true;

  String _status = '';
  String _error = '';
  String _toast = '';
  Timer? _hideTimer;
  Timer? _toastTimer;
  Timer? _saveTimer;
  Timer? _hintTimer;
  int _savedSecond = -1;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final stage in _stages) {
      _bind(stage);
    }
    _boot();
  }

  /// 两路播放器都要监听，但只有当前在播的那一路会被采纳，
  /// 免得预加载那路的进度、完成事件干扰界面。
  void _bind(_Stage stage) {
    final p = stage.player;
    bool live() => mounted && identical(stage, _stage);

    _subs.add(
      p.stream.playing.listen((v) {
        if (live()) setState(() => _playing = v);
      }),
    );
    _subs.add(
      p.stream.position.listen((v) {
        if (!live()) return;
        final changed = v.inSeconds != _pos.inSeconds;
        setState(() => _pos = v);
        if (changed) _maybeSave();
      }),
    );
    _subs.add(
      p.stream.duration.listen((v) {
        if (live() && v.inSeconds != _dur.inSeconds) setState(() => _dur = v);
      }),
    );
    _subs.add(
      p.stream.completed.listen((done) {
        if (done && live()) _onCompleted();
      }),
    );
    _subs.add(
      p.stream.width.listen((v) {
        if (live() && v != null && v > 0 && v != _vw) setState(() => _vw = v);
      }),
    );
    _subs.add(
      p.stream.height.listen((v) {
        if (live() && v != null && v > 0 && v != _vh) setState(() => _vh = v);
      }),
    );
    _subs.add(
      p.stream.error.listen((message) {
        if (!live() || message.isEmpty) return;
        // 出错时把预加载那路让出来，别跟当前这一路抢连接
        _dropPreload();
        setState(() {
          _status = '';
          _error = _humanError(message);
        });
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) routeObserver.subscribe(this, route);
  }

  /// 被别的页面盖住（片库 / 搜索 / 榜单 / 另一部剧）：暂停，别在后台出声
  @override
  void didPushNext() => _suspend();

  /// 盖住的页面退出：接着刚才的位置继续
  @override
  void didPopNext() => _resume();

  void _suspend() {
    if (_suspended) return;
    _suspended = true;
    _hideTimer?.cancel();
    _clearToast();
    _saveNow();
    _player.pause();
  }

  void _resume() {
    if (!_suspended) return;
    _suspended = false;
    if (!mounted) return;
    if (_videoReady) {
      _player.play();
      _scheduleHide();
      // 放着不动的时候预载的地址可能已经过期，回来重新备一份
      unawaited(_preloadAhead(force: true));
    } else {
      unawaited(_playCurrent());
    }
  }

  /// 作废正在跑的预加载（不动物理资源，只让它的结果不被采纳）
  void _cancelPreload() => _preloadingKeys.clear();

  /// 丢掉所有备用路的预加载（释放引擎会话、别占着网络和内存）
  void _dropPreload() {
    _cancelPreload();
    for (var i = 0; i < _stages.length; i++) {
      if (i == _stageIdx) continue;
      final stage = _stages[i];
      if (stage.key.isEmpty && stage.session.isEmpty) continue;
      stage.warmed = false;
      stage.key = '';
      stage.plan = null;
      if (stage.session.isNotEmpty) {
        unawaited(Engine.instance.release(stage.session));
        stage.session = '';
      }
      unawaited(stage.player.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    if (_fullscreen) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    for (final sub in _subs) {
      sub.cancel();
    }
    _hideTimer?.cancel();
    _toastTimer?.cancel();
    _saveTimer?.cancel();
    _hintTimer?.cancel();
    _saveNow();
    for (final stage in _stages) {
      Engine.instance.release(stage.session);
      stage.player.dispose();
    }
    _pages?.removeListener(_onScroll);
    _pages?.dispose();
    _scrollPos.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
      _saveNow();
      _player.pause();
      _hideTimer?.cancel();
      // 切到后台就别再占着解码和网络了
      _dropPreload();
      if (mounted && !_ui) setState(() => _ui = true);
    } else if (state == AppLifecycleState.inactive) {
      // 下拉通知栏、来电浮层之类：先暂停，别在后台响
      _player.pause();
    } else if (state == AppLifecycleState.resumed) {
      // 回前台：补上切后台时放掉的那一段，并重建被清掉的预加载
      if (!_suspended && _videoReady) {
        _player.play();
        _scheduleHide();
        unawaited(_preloadAhead(force: true));
      }
      final pausedAt = _pausedAt;
      _pausedAt = null;
      final away = pausedAt == null
          ? Duration.zero
          : DateTime.now().difference(pausedAt);
      if (away >= const Duration(minutes: 20) && _pool.isNotEmpty) {
        // 隔了很久再"打开"APP：后面待播的剧也重新洗一遍，不接上次那条序列
        _pool.shuffle(_rng);
      }
    }
  }

  // ---------------------------------------------------------------- 随机片库

  /// 开一个新会话：换随机起点页、避开上次的起点、重新载入跨会话去重表。
  /// 这是"每次打开 APP 都是没有规律的取剧"的入口。
  void _beginFeedSession() {
    final previous = Store.instance.feedStartPage();
    var start = 1 + _rng.nextInt(_kFeedStartPages);
    if (start == previous) start = 1 + (start % _kFeedStartPages);
    unawaited(Store.instance.saveFeedStartPage(start));
    WebCatalog.instance.startFeedSession(start);
    _recent
      ..clear()
      ..addAll(Store.instance.feedRecent());
  }

  /// 冷启动把「随机起点页 + 下一页」混在一起洗牌入池。
  /// 原来只洗热榜第 1 页，导致每次打开都是同一批剧换个排列。
  Future<void> _seedPool() async {
    try {
      final rows = await WebCatalog.instance
          .seedPages(_kFeedSeedPageCount)
          .timeout(const Duration(seconds: 10));
      final fresh = <Drama>[];
      for (final drama in rows) {
        if (drama.id.isEmpty || !_known.add(drama.id)) continue;
        _all.add(drama);
        fresh.add(drama);
      }
      if (fresh.isEmpty) return;
      fresh.shuffle(_rng);
      _pool.addAll(fresh);
    } catch (_) {
      // 网页源不可用就交给 _refillPool 走原来的单页兜底，不阻塞首播
    }
  }

  Future<void> _boot() async {
    if (_booting) return;
    _booting = true;
    try {
      _beginFeedSession();
      if (widget.initialDrama != null) {
        // 从片库点进来：这部优先，按上次进度续播；后续上滑的池子后台再随机化
        unawaited(_seedPool());
        final slot = _Slot(widget.initialDrama!);
        _remember(slot.drama.id);
        final detail = await _detailOf(slot.drama);
        slot.detail = detail;
        slot.epPos = _resumeIndex(slot.drama.id, detail.episodes);
        _slots.add(slot);
      } else {
        await _seedPool();
        final slot = await _firstRandomSlot();
        if (slot == null) throw const AppFailure('暂时没有可播放的内容');
        _slots.add(slot);
      }
      if (!mounted) return;
      if (_slots.isEmpty) throw const AppFailure('这部剧暂时没有可播放的分集');
      _pages?.removeListener(_onScroll);
      _pages?.dispose();
      _pages = PageController();
      _pages!.addListener(_onScroll);
      setState(() {
        _ready = true;
        _status = '';
      });
      await _playCurrent();
      unawaited(_ensureAhead());
      _hintTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _hint = false);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = '';
        _error = _humanError(error.toString());
      });
    } finally {
      _booting = false;
    }
  }

  /// 首屏：随机挑一部确实有分集的剧
  Future<_Slot?> _firstRandomSlot() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final drama = await _pickDrama();
      if (drama == null) return null;
      final slot = _Slot(drama);
      try {
        final detail = await _detailOf(drama);
        if (detail.episodes.isEmpty) continue;
        slot.detail = detail;
        return slot;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 取一部随机剧：池子空了就补页，补完还没拉完就重新洗牌
  Future<Drama?> _pickDrama() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (_pool.isEmpty) {
        if (!_poolDone) {
          await _refillPool();
        } else {
          _reshuffle();
          if (_pool.isEmpty) return null;
        }
      }
      final skipped = <Drama>[];
      while (_pool.isNotEmpty) {
        final drama = _pool.removeLast();
        if (drama.id.isEmpty) continue;
        if (_recent.contains(drama.id)) {
          skipped.add(drama);
          continue;
        }
        _remember(drama.id);
        return drama;
      }
      if (skipped.isNotEmpty) {
        // 片库偏小或跨会话去重表太长时放宽一次，别让轮播直接断掉
        final chosen = skipped.removeAt(_rng.nextInt(skipped.length));
        _pool.addAll(skipped);
        _remember(chosen.id);
        return chosen;
      }
    }
    return null;
  }

  void _remember(String id) {
    if (id.isEmpty) return;
    _recent.remove(id);
    _recent.add(id);
    if (_recent.length > 40) _recent.removeAt(0);
    // 跨会话落盘：下次打开 APP 不会又从上次刷过的那几部开始
    unawaited(Store.instance.saveFeedRecent(_recent));
  }

  void _reshuffle() {
    if (_all.isEmpty) return;
    _pool
      ..clear()
      ..addAll(_all)
      ..shuffle(_rng);
  }

  /// 补池子：优先网页分类页（含漫剧 / AI 剧），拿不到再退回引擎目录（真人剧）
  Future<void> _refillPool() async {
    if (_poolLoading) return;
    _poolLoading = true;
    try {
      var fresh = await _pullWeb();
      if (fresh.isEmpty) fresh = await _pullEngine();
      if (fresh.isEmpty && !_webDone) fresh = await _pullWeb();
      fresh.shuffle(_rng);
      _pool.addAll(fresh);
      if (fresh.isEmpty && _webDone && _engineDone) _poolDone = true;
    } catch (_) {
      _poolDone = true;
    } finally {
      _poolLoading = false;
    }
  }

  Future<List<Drama>> _pullWeb() async {
    if (_webDone) return const [];
    final rows = await WebCatalog.instance.nextPage();
    if (rows.isEmpty) {
      _webDone = true;
      return const [];
    }
    final fresh = <Drama>[];
    for (final drama in rows) {
      if (drama.id.isEmpty || !_known.add(drama.id)) continue;
      _all.add(drama);
      fresh.add(drama);
    }
    return fresh;
  }

  Future<List<Drama>> _pullEngine() async {
    if (_engineDone) return const [];
    try {
      final page = await Engine.instance.catalog(page: _catalogPage + 1);
      _catalogPage = page.page > 0 ? page.page : _catalogPage + 1;
      if (!page.hasMore || page.items.isEmpty) _engineDone = true;
      final fresh = <Drama>[];
      for (final drama in page.items) {
        if (drama.id.isEmpty || !_known.add(drama.id)) continue;
        _all.add(drama);
        fresh.add(drama);
      }
      return fresh;
    } catch (_) {
      _engineDone = true;
      return const [];
    }
  }

  /// 在当前页后面补一部新剧，保证用户能一直滑
  Future<void> _ensureAhead() async {
    if (_appending) return;
    _appending = true;
    try {
      while (mounted && !_exhausted && _slots.length < _index + 3) {
        if (!await _appendSlot()) break;
      }
    } finally {
      _appending = false;
    }
  }

  Future<bool> _appendSlot() async {
    final drama = await _pickDrama();
    if (drama == null) {
      _exhausted = true;
      return false;
    }
    final slot = _Slot(drama);
    if (!mounted) return false;
    setState(() => _slots.add(slot));
    unawaited(_warmDetail(slot));
    // 新补的正好是“下一部剧”，顺手把它的第一集先备好
    if (_slots.length == _index + 2) unawaited(_preloadAhead());
    return true;
  }

  /// 先把封面顶上，详情后台补
  Future<void> _warmDetail(_Slot slot) async {
    if (slot.detail != null) return;
    try {
      final detail = await _detailOf(slot.drama);
      slot.detail = detail;
      if (mounted && _index < _slots.length && _slots[_index] == slot) {
        setState(() {});
      }
    } catch (_) {}
  }

  Future<DramaDetail> _detailOf(Drama drama) {
    final cached = _details[drama.id];
    if (cached != null) return Future.value(cached);
    final running = _detailTasks[drama.id];
    if (running != null) return running;
    final task = _loadDetail(drama);
    _detailTasks[drama.id] = task;
    task.whenComplete(() {
      if (identical(_detailTasks[drama.id], task)) {
        _detailTasks.remove(drama.id);
      }
    });
    return task;
  }

  Future<DramaDetail> _loadDetail(Drama drama) async {
    final detail = await Engine.instance.detail(drama);
    final resolved = detail.episodes.isEmpty
        ? detail
        : DramaDetail(
            detail.drama.id.isEmpty ? drama : detail.drama,
            detail.episodes,
            detail.warning,
          );
    _details[drama.id] = resolved;
    return resolved;
  }

  int _resumeIndex(String seriesId, List<Episode> episodes) {
    final mark = Store.instance.mark(seriesId);
    if (mark == null || mark.episode <= 0) return 0;
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].number == mark.episode) return i;
    }
    return 0;
  }

  // ------------------------------------------------------------------ 播放

  FeedEntry get _current {
    final slot = _slots[_index];
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    if (episodes.isEmpty) {
      return FeedEntry(
        drama: slot.drama,
        episode: Episode(const <String, dynamic>{}, 1),
        index: 0,
        total: slot.drama.episodeCount,
      );
    }
    final pos = slot.epPos.clamp(0, episodes.length - 1).toInt();
    return FeedEntry(
      drama: slot.drama,
      episode: episodes[pos],
      index: pos,
      total: episodes.length,
    );
  }

  String _keyOf(String dramaId, int episode) => '$dramaId#$episode#$_quality';

  /// 这一集该从哪儿起播：只有上次看到一半、且集号对得上才续播
  Duration? _startFor(String dramaId, Episode episode) {
    final mark = Store.instance.mark(dramaId);
    if (mark != null && mark.episode == episode.number && mark.ms > 4000) {
      return Duration(milliseconds: mark.ms);
    }
    return null;
  }

  /// 某页此刻该播哪一集、从哪起播。预加载和真正起播都走这里，两边算出来必须一致。
  ({Episode episode, Duration? start})? _entryOf(
    _Slot slot, {
    Duration? resumeAt,
    bool useMark = true,
  }) {
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    if (episodes.isEmpty) return null;
    final pos = slot.epPos.clamp(0, episodes.length - 1).toInt();
    final episode = episodes[pos];
    var start = resumeAt;
    if (start == null && useMark) start = _startFor(slot.drama.id, episode);
    return (episode: episode, start: start);
  }

  /// 备用路里是否已经备好了这一集
  _Stage? _readyStage(_Slot slot, Duration? resumeAt) {
    if (resumeAt != null) return null; // 带指定起播点的都不算常规切换
    final entry = _entryOf(slot);
    if (entry == null) return null;
    return _stageHolding(_keyOf(slot.drama.id, entry.episode.number));
  }

  /// 找一条已经备好指定内容的备用路
  _Stage? _stageHolding(String key) {
    for (var i = 0; i < _stages.length; i++) {
      if (i == _stageIdx) continue;
      final stage = _stages[i];
      if (stage.warmed && stage.key == key) return stage;
    }
    return null;
  }

  Future<void> _playCurrent({Duration? resumeAt}) async {
    if (_slots.isEmpty || _index >= _slots.length) return;
    final slot = _slots[_index];
    final ticket = ++_generation;

    // 快路：备用播放器早就把这一集解析好、缓冲好了，直接换画面
    final ready = _readyStage(slot, resumeAt);
    if (ready != null) {
      _activate(ready, ticket);
      return;
    }

    _cancelPreload(); // 要换内容了，作废掉还在跑的预加载
    debugPrint('[feed] slow start ep=${slot.epPos + 1}');
    setState(() {
      _videoReady = false;
      _status = '正在解析…';
      _error = '';
      _pos = Duration.zero;
      _dur = Duration.zero;
      _qualities = const [];
    });
    try {
      final detail = slot.detail ?? await _detailOf(slot.drama);
      if (!mounted || ticket != _generation) return;
      slot.detail = detail;
      final episodes = detail.episodes;
      if (episodes.isEmpty) throw const AppFailure('这部剧暂时没有可播放的分集');
      if (slot.epPos >= episodes.length) slot.epPos = episodes.length - 1;
      if (slot.epPos < 0) slot.epPos = 0;
      final entry = _entryOf(slot, resumeAt: resumeAt);
      if (entry == null) throw const AppFailure('这部剧暂时没有可播放的分集');
      setState(() {});

      final plan = await Engine.instance.resolve(
        slot.drama,
        entry.episode,
        quality: _quality,
        stillValid: () => mounted && ticket == _generation,
      );
      if (!mounted || ticket != _generation) {
        await Engine.instance.release(plan.session);
        return;
      }
      if (plan.url.isEmpty) {
        await Engine.instance.release(plan.session);
        throw const AppFailure('这一集暂时没有播放地址');
      }
      debugPrint(
        '[feed] resolve ok ep=${entry.episode.number} quality=${plan.quality} '
        'keyLen=${plan.decryptionKey.length} rotations=${plan.rotations}',
      );

      setState(() => _status = '正在起播…');
      await _mount(
        _stage,
        plan,
        key: _keyOf(slot.drama.id, entry.episode.number),
        start: entry.start,
        play: true,
      );
      if (!mounted || ticket != _generation) return;
      // 画面已经在播，先落实状态；后面的倍速 / 补 seek 失败不能把画面藏掉
      setState(() {
        _status = '';
        _videoReady = true;
        _qualities = plan.qualities;
      });
      _revealUi();
      unawaited(_applyPlaybackTweaks(entry.start, ticket));
      unawaited(Store.instance.markWatched(slot.drama.id, entry.episode.number));
      unawaited(_ensureAhead());
      unawaited(_preloadAhead());
    } catch (error) {
      if (!mounted || ticket != _generation) return;
      // 取流失败的诊断（含换设备次数）由 Go 侧附在错误里，必须落进 logcat
      debugPrint('[feed] open FAILED: $error');
      setState(() {
        _status = '';
        _error = _humanError(error.toString());
      });
    }
  }

  /// 倍速与补 seek 属于锦上添花：单独跑，抛错也不能影响已起播的画面
  Future<void> _applyPlaybackTweaks(Duration? start, int ticket) async {
    try {
      await _player.setRate(_rate);
      if (!mounted || ticket != _generation) return;
      if (start != null) {
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (!mounted || ticket != _generation) return;
        if (_pos < start - const Duration(seconds: 3)) {
          await _player.seek(start);
        }
      }
    } catch (_) {
      // 忽略：视频已经在播，不能因为这些次要设置失败而隐藏画面
    }
  }

  /// 把一份解析结果装到指定那一路播放器上
  Future<void> _mount(
    _Stage stage,
    PlaybackPlan plan, {
    required String key,
    Duration? start,
    required bool play,
  }) async {
    if (stage.session.isNotEmpty && stage.session != plan.session) {
      unawaited(Engine.instance.release(stage.session));
    }
    stage.session = plan.session;
    stage.plan = plan;
    stage.key = key;
    stage.warmed = false;

    final platform = stage.player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
        'demuxer-lavf-o',
        [
          'seg_max_retry=3',
          'strict=experimental',
          'allowed_extensions=ALL',
          'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
          if (plan.decryptionKey.isNotEmpty) 'decryption_key=${plan.decryptionKey}',
        ].join(','),
      );
      await platform.setProperty('network-timeout', '20');
      // 预读拉长一些，切过去时前面已经攒下一段现成的缓冲
      await platform.setProperty('cache-secs', '20');
      await platform.setProperty('demuxer-readahead-secs', '24');
    }
    await stage.player.open(
      Media(plan.url, httpHeaders: plan.headers, start: start),
      play: play,
    );
    stage.warmed = true;
  }

  /// 切到已经备好的那一路：只换画面，不重新打开媒体
  void _activate(_Stage next, int ticket) {
    if (!mounted || ticket != _generation) return;
    final prev = _stage;
    if (!identical(prev, next)) prev.player.pause();
    final state = next.player.state;
    setState(() {
      _stageIdx = _stages.indexOf(next);
      _videoReady = true;
      _status = '';
      _error = '';
      _playing = true;
      _savedSecond = -1;
      _pos = state.position;
      _dur = state.duration;
      _vw = state.width ?? 0;
      _vh = state.height ?? 0;
      if (next.plan != null) _qualities = next.plan!.qualities;
    });
    unawaited(next.player.setRate(_rate));
    unawaited(next.player.play());
    _scheduleHide();
    final entry = _entryOf(_slots[_index]);
    if (entry != null) {
      unawaited(
        Store.instance.markWatched(_slots[_index].drama.id, entry.episode.number),
      );
    }
    unawaited(_ensureAhead());
    unawaited(_preloadAhead());
    debugPrint(
      '[feed] fast switch ep=${_slots[_index].epPos + 1} pos=${state.position.inMilliseconds}ms',
    );
  }

  /// 提前备好两样东西：本剧下一集、下一部剧的第一集。
  /// 前者应付“播完接下一集”，后者应付“上滑换剧”，两条路都不用现解析。
  Future<void> _preloadAhead({bool force = false}) async {
    if (!mounted || _suspended) return;
    // 正在备的时候又被叫一次（比如刚好补进一部新剧），记下来，等这轮完了再补一轮
    if (_preloading) {
      _preloadPending = true;
      return;
    }
    _preloading = true;
    try {
      final targets = await _targets();
      if (!mounted || targets.isEmpty) return;
      if (force) _dropPreload();
      final want = {for (final t in targets) t.key};
      debugPrint(
        '[feed] preload want=${targets.map((t) => t.key).join(',')} active=$_stageIdx',
      );
      for (final target in targets) {
        if (!mounted) return;
        if (_stageHolding(target.key) != null) continue;
        if (_preloadingKeys.contains(target.key)) continue;
        final stage = _freeStage(want);
        if (stage == null) continue;
        await _warm(stage, target);
      }
    } finally {
      _preloading = false;
      if (_preloadPending) {
        _preloadPending = false;
        unawaited(_preloadAhead());
      }
    }
  }

  /// 挑一条可以拿来预加载的路：优先空着的，其次装着我们不再需要的内容的
  _Stage? _freeStage(Set<String> keep) {
    for (var i = 0; i < _stages.length; i++) {
      if (i == _stageIdx) continue;
      if (!_stages[i].warmed) return _stages[i];
    }
    for (var i = 0; i < _stages.length; i++) {
      if (i == _stageIdx) continue;
      if (!keep.contains(_stages[i].key)) return _stages[i];
    }
    return null;
  }

  /// 把某个目标解析出来并装到指定那条路上（暂停态，纯粹为了先把缓冲填上）
  Future<void> _warm(_Stage stage, _Preload target) async {
    _preloadingKeys.add(target.key);
    final generation = _generation;
    try {
      final plan = await Engine.instance.resolve(
        target.drama,
        target.episode,
        quality: _quality,
        stillValid: () =>
            mounted &&
            generation == _generation &&
            _preloadingKeys.contains(target.key),
      );
      final stillWanted = _preloadingKeys.contains(target.key);
      if (!mounted || generation != _generation || !stillWanted) {
        unawaited(Engine.instance.release(plan.session));
        return;
      }
      if (plan.url.isEmpty) {
        unawaited(Engine.instance.release(plan.session));
        return;
      }
      await _mount(stage, plan, key: target.key, start: target.start, play: false);
      debugPrint(
        '[feed] warm ${target.key} -> stage${_stages.indexOf(stage)} '
        'rotations=${plan.rotations}',
      );
    } catch (error) {
      // 预加载失败不要紧，真正要播的时候还会再解析一次。
      // 但错误必须留下：设备档案失效通常先在预加载里暴露。
      debugPrint('[feed] warm FAILED ${target.key}: $error');
    } finally {
      _preloadingKeys.remove(target.key);
    }
  }

  /// 当前该预加载的目标，最多两个
  Future<List<_Preload>> _targets() async {
    final out = <_Preload>[];
    final slot = _slots[_index];
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    if (episodes.isNotEmpty && slot.epPos + 1 < episodes.length) {
      final ep = episodes[slot.epPos + 1];
      out.add(
        _Preload(
          slot.drama,
          ep,
          _keyOf(slot.drama.id, ep.number),
          _startFor(slot.drama.id, ep),
        ),
      );
    }
    if (_index + 1 < _slots.length) {
      final next = _slots[_index + 1];
      try {
        final detail = next.detail ?? await _detailOf(next.drama);
        if (detail.episodes.isNotEmpty) {
          next.detail = detail;
          final pos = next.epPos.clamp(0, detail.episodes.length - 1).toInt();
          final ep = detail.episodes[pos];
          out.add(
            _Preload(
              next.drama,
              ep,
              _keyOf(next.drama.id, ep.number),
              _startFor(next.drama.id, ep),
            ),
          );
        }
      } catch (_) {}
    }
    return out;
  }

  /// 本集播完：先顺着本剧往下，播到剧终才换下一部
  void _onCompleted() {
    if (!mounted) return;
    final slot = _slots[_index];
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    _saveNow();
    if (episodes.isNotEmpty && slot.epPos + 1 < episodes.length) {
      slot.epPos += 1;
      setState(() {});
      unawaited(_playCurrent());
      return;
    }
    _advanceSlot();
  }

  /// 翻到下一部剧
  void _advanceSlot() {
    if (!mounted) return;
    if (_index + 1 < _slots.length) {
      _pages?.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    _showToast('正在找下一部…', spinner: true);
    _ensureAhead().then((_) {
      if (!mounted) return;
      _clearToast();
      if (_index + 1 < _slots.length) {
        _pages?.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      } else {
        _showToast('暂时没有更多内容了');
      }
    });
  }

  void _onPageChanged(int index) {
    if (index == _index || index < 0 || index >= _slots.length) return;
    _saveNow();
    setState(() {
      _index = index;
      _panel = false;
      _hint = false;
      _ui = true; // 换剧时重新亮出剧集信息与进度条
    });
    _scheduleHide(); // 从换剧这一刻重新计 4 秒
    unawaited(_playCurrent());
    unawaited(_ensureAhead());
  }

  /// 只把滚动位置写进 notifier：虚化层和每页封面各自订阅，不为了滚动重建整棵树
  void _onScroll() {
    final p = _pages;
    if (p == null || !p.hasClients || p.positions.length != 1) return;
    final pos = p.page ?? _index.toDouble();
    if ((pos - _scrollPos.value).abs() > 0.0008) _scrollPos.value = pos;
  }

  void _seekTo(Duration target) {
    if (_dur == Duration.zero) return;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _dur ? _dur : target);
    _player.seek(clamped);
    setState(() => _pos = clamped);
  }

  // -------------------------------------------------------------- 进度记录

  void _maybeSave() {
    if (_pos.inSeconds == _savedSecond) return;
    if (_pos.inSeconds % 5 != 0) return;
    _savedSecond = _pos.inSeconds;
    _saveNow();
  }

  void _saveNow() {
    if (!_ready || _slots.isEmpty) return;
    if (_index < 0 || _index >= _slots.length) return;
    if (_pos.inMilliseconds < 3000) return;
    // 已播到结尾就不用记了，免得下次进这部剧直接跳片尾
    if (_dur.inMilliseconds > 0 &&
        _pos.inMilliseconds >= _dur.inMilliseconds - 5000) {
      return;
    }
    final entry = _current;
    unawaited(
      Store.instance.saveMark(
        entry.drama.id,
        episode: entry.episode.number,
        ms: _pos.inMilliseconds,
        title: entry.drama.title,
        cover: entry.drama.cover,
        drama: entry.drama.toJson(),
      ),
    );
  }

  // ------------------------------------------------------------- 交互/提示

  /// 轻触画面：暂停 / 播放（双击才是点赞）
  void _onSurfaceTap() {
    if (_panel) {
      setState(() => _panel = false);
      _scheduleHide();
      return;
    }
    if (_status.isNotEmpty || _error.isNotEmpty || !_videoReady) return;
    _togglePlay();
  }

  void _togglePlay() {
    if (_playing) {
      _player.pause();
      _hideTimer?.cancel();
      if (!_ui) setState(() => _ui = true);
    } else {
      _player.play();
      if (!_ui) setState(() => _ui = true);
      _scheduleHide();
    }
  }

  /// 横屏播放（主要给 16:9 的横版短剧）
  Future<void> _toggleFullscreen() async {
    final target = !_fullscreen;
    setState(() {
      _fullscreen = target;
      _panel = false;
    });
    if (target) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_panel) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_panel && !_dragging) setState(() => _ui = false);
    });
  }

  /// 内容切换完成后重新显示控制层：_scheduleHide 只重启计时，不会把 _ui 置回 true
  void _revealUi() {
    if (!mounted) return;
    _hideTimer?.cancel();
    if (!_ui) setState(() => _ui = true);
    _scheduleHide();
  }

  void _holdUi() {
    _hideTimer?.cancel();
    if (!_ui) setState(() => _ui = true);
  }

  void _showToast(String text, {bool spinner = false}) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    if (!spinner) {
      _toastTimer = Timer(const Duration(milliseconds: 2200), _clearToast);
    }
  }

  void _clearToast() {
    _toastTimer?.cancel();
    if (mounted && _toast.isNotEmpty) setState(() => _toast = '');
  }

  Future<void> _toggleLike() async {
    final entry = _current;
    await Store.instance.toggleLike(entry.drama);
    if (!mounted) return;
    final on = Store.instance.isLiked(entry.drama.id);
    setState(() {});
    _showToast(on ? '已点赞，可在「我的」查看' : '已取消点赞');
  }

  /// 双击只点赞，不取消（避免误触反复切换）
  Future<void> _likeOnce() async {
    final entry = _current;
    if (Store.instance.isLiked(entry.drama.id)) return;
    await Store.instance.toggleLike(entry.drama);
    if (!mounted) return;
    setState(() {});
    _showToast('已点赞，可在「我的」查看');
  }

  Future<void> _toggleFav() async {
    final entry = _current;
    await Store.instance.toggleFav(entry.drama);
    if (!mounted) return;
    final on = Store.instance.isFav(entry.drama.id);
    setState(() {});
    _showToast(on ? '已追剧，可在「我的」查看' : '已取消追剧');
  }

  /// 分享（转发）：只复制剧名
  Future<void> _share() async {
    final title = _current.drama.title;
    await Clipboard.setData(ClipboardData(text: title));
    if (mounted) _showToast('已复制剧名：$title');
  }

  Future<void> _openLibrary() async {
    _holdUi();
    // 横屏下进片库会很难看，先转回来
    if (_fullscreen) await _toggleFullscreen();
    if (!mounted) return;
    await Navigator.of(context).push(libraryRoute());
    if (mounted) _scheduleHide();
  }

  Future<void> _openMine() async {
    _holdUi();
    if (_fullscreen) await _toggleFullscreen();
    if (!mounted) return;
    await Navigator.of(context).push(mineRoute());
    if (!mounted) return;
    setState(() {});
    _scheduleHide();
  }

  Future<void> _pickRate() async {
    _holdUi();
    final value = await _chooseSheet<double>(
      title: '倍速',
      current: _rate,
      options: const [0.75, 1.0, 1.25, 1.5, 2.0],
      label: (v) => v == 1 ? '1.0x 正常' : '${v}x',
    );
    if (value == null || !mounted) return;
    setState(() => _rate = value);
    await _player.setRate(value);
  }

  Future<void> _pickQuality() async {
    if (_qualities.isEmpty) {
      _showToast('清晰度信息准备中，稍后再试');
      return;
    }
    _holdUi();
    final value = await _chooseSheet<int>(
      title: '清晰度',
      current: _quality,
      options: [0, ..._qualities],
      label: (v) => v == 0 ? '自动' : '${v}P',
    );
    if (value == null || !mounted || value == _quality) return;
    setState(() => _quality = value);
    _dropPreload(); // 清晰度变了，之前备好的那份用不上了
    final keep = _pos;
    await _playCurrent(resumeAt: keep > const Duration(seconds: 2) ? keep : null);
  }

  Future<T?> _chooseSheet<T>({
    required String title,
    required T current,
    required List<T> options,
    required String Function(T) label,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Hg.bg1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Hg.radiusLg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Hg.text,
                    ),
                  ),
                ],
              ),
            ),
            for (final option in options)
              ListTile(
                dense: true,
                title: Text(
                  label(option),
                  style: TextStyle(
                    fontSize: 14,
                    color: option == current ? Hg.brand2 : Hg.text,
                    fontWeight: option == current
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                trailing: option == current
                    ? const Icon(Icons.check, size: 18, color: Hg.brand2)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _togglePanel() {
    _holdUi();
    setState(() => _panel = !_panel);
    if (!_panel) _scheduleHide();
  }

  void _jumpToEpisode(int episodeNumber) {
    final slot = _slots[_index];
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].number == episodeNumber) {
        slot.epPos = i;
        setState(() => _panel = false);
        unawaited(_playCurrent());
        _revealUi();
        return;
      }
    }
  }

  String _humanError(String raw) {
    var text = raw.replaceFirst('Exception: ', '').trim();
    if (text.startsWith('AppFailure: ')) text = text.substring(12);
    if (text.isEmpty) return '播放出了点问题';
    if (Engine.isCanceled(text)) return '播放地址没取到，点重试再来一次';
    if (text.contains('超时')) return '网络有点慢，重试一下';
    return text;
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final safeTop = media.padding.top;
    final safeBottom = media.padding.bottom;
    final controlHeight = 44.0;
    final bottomBase = controlHeight + safeBottom + 8;

    if (!_ready) return _bootView();

    if (_slots.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _fatal(_error.isEmpty ? '暂时没有可播放的内容' : _error)),
      );
    }

    final current = _current;

    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(child: _videoLayer(current)),
            Positioned.fill(
              child: PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                itemCount: _slots.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => _page(_slots[i], i),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ui ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x8A000000),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x8A000000),
                      ],
                      stops: [0, 0.18, 0.62, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_status.isNotEmpty) Positioned.fill(child: _loadingLayer()),
          if (_error.isNotEmpty) Positioned.fill(child: _errorLayer(current)),
          if (_videoReady && !_playing && _status.isEmpty && _error.isEmpty)
            Center(
              child: GestureDetector(
                onTap: () {
                  _player.play();
                  _scheduleHide();
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 66,
                  height: 66,
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 42,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (_hint && !_fullscreen && _status.isEmpty && _error.isEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomBase + 60,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x9E000000),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '上滑换一部 · 不滑接着看',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_toast.isNotEmpty) _toastLayer(),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedOpacity(
              opacity: _ui ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_ui,
                child: _fullscreen
                    ? _wideBar(current, safeTop)
                    : _topBar(current, safeTop),
              ),
            ),
          ),
          if (!_fullscreen)
            Positioned(
              right: 10,
              bottom: bottomBase + 6,
              child: AnimatedOpacity(
                opacity: _ui ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(ignoring: !_ui, child: _rail(current)),
              ),
            ),
          if (!_fullscreen)
            Positioned(
              left: 14,
              right: 74,
              bottom: bottomBase + 10,
              child: AnimatedOpacity(
                opacity: _ui ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(ignoring: !_ui, child: _info(current)),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedOpacity(
              opacity: _ui ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_ui,
                child: _controls(current, safeBottom),
              ),
            ),
          ),
          if (_panel) _episodePanel(current, bottomBase, safeTop),
        ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 画面

  Widget _videoLayer(FeedEntry entry) {
    final aspect = (_vw > 0 && _vh > 0) ? _vw / _vh : 0.0;
    // 三路画面都挂在树上、只切透明度：切集时纹理已经在渲染了，
    // 不会出现“新画面还没接上、先黑一下”的空档。
    Widget stageView(int i) => Video(
      key: ValueKey('stage$i'),
      controller: _stages[i].video,
      controls: NoVideoControls,
      fit: BoxFit.contain,
      fill: Colors.transparent,
    );
    final Widget video = Stack(
      fit: StackFit.expand,
      children: [
        // 三路都常驻（没内容的那路透明度为 0，不参与绘制）：
        // 结构固定，切路时不会因为增删 widget 重新挂载纹理而闪帧。
        for (var i = 0; i < _stages.length; i++)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: i == _stageIdx ? 1 : 0,
              duration: const Duration(milliseconds: 90),
              child: stageView(i),
            ),
          ),
      ],
    );

    // 铺底的模糊封面不随滚动变化，先建好，免得滚动时每帧重建一遍
    final backdrop = _blurredCover(entry.drama.cover);
    return ValueListenableBuilder<double>(
      valueListenable: _scrollPos,
      builder: (context, pos, _) {
        final mix = _transitionMix(pos);
        // 滤镜节点一直挂着，只用 sigma 表达强弱。
        // 之前是 mix>0 才插入 ImageFiltered，滑停的那一帧子树结构突变，
        // 纹理要重新合成，就会闪一两帧。
        final content = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 26 * mix, sigmaY: 26 * mix),
          child: video,
        );
        final framed = aspect > 0
            ? Center(child: AspectRatio(aspectRatio: aspect, child: content))
            : content;
        return Stack(
          fit: StackFit.expand,
          children: [
            backdrop,
            // 画面按视频比例放置，留白处露出模糊封面（桌面版 .backdrop 的做法）。
            // 翻页时把它“推远 + 虚化 + 淡出”，露出底下同剧的模糊封面；
            // 停稳后再反向收回来，换屏过程就是一次柔和的虚化过渡。
            Opacity(
              opacity: _videoReady ? (1 - 0.94 * mix).clamp(0.06, 1.0) : 0,
              child: Transform.scale(scale: 1 + 0.06 * mix, child: framed),
            ),
          ],
        );
      },
    );
  }

  /// 0 = 正停在某一页上；1 = 滑到两页中间（换屏的那一瞬）
  double _transitionMix(double pos) {
    final frac = (pos - pos.roundToDouble()).abs();
    return Curves.easeInOut.transform((frac * 2).clamp(0.0, 1.0));
  }

  Widget _page(_Slot slot, int i) {
    final active = i == _index;
    final showPoster = !active || !_videoReady;
    final backdrop = _blurredCover(slot.drama.cover);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onSurfaceTap,
      onDoubleTap: _likeOnce,
      // 手势层必须一直在：播放正常时这一页是透明的，
      // 屏幕上的轻触暂停、双击点赞全靠它接着（写成提前 return 会让点击全失效）
      child: ValueListenableBuilder<double>(
        valueListenable: _scrollPos,
        builder: (context, pos, _) {
          // 这一页离屏幕中心有多远：0 = 正对着，1 = 整页之外
          final far = (pos - i).abs().clamp(0.0, 1.0);
          final raw = slot.drama.cover.isEmpty
              ? const ColoredBox(color: Colors.black)
              : Image.network(
                  slot.drama.cover,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                );
          // 刚滑进来时是糊的，越到位越清晰，衔接下面那层模糊封面
          final poster = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: 16 * far,
              sigmaY: 16 * far,
            ),
            child: Transform.scale(scale: 1 + 0.06 * far, child: raw),
          );
          // 结构保持不变，只用透明度淡入淡出：
          // 换到本页时封面渐渐退掉，露出下面的画面，不会硬切闪一下
          return AnimatedOpacity(
            opacity: showPoster ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: Stack(
              fit: StackFit.expand,
              children: [
                backdrop,
                poster,
                Center(
                  child: Text(
                    slot.drama.cover.isEmpty ? '剧播' : '',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Colors.white70,
                      letterSpacing: 4,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _blurredCover(String cover) {
    if (cover.isEmpty) return const ColoredBox(color: Colors.black);
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform.scale(
              scale: 1.15,
              child: Image.network(
                cover,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
              ),
            ),
            const ColoredBox(color: Color(0x66000000)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 顶部

  Widget _topBar(FeedEntry entry, double safeTop) {
    final canPop = Navigator.of(context).canPop();
    return Container(
      padding: EdgeInsets.fromLTRB(6, safeTop + 6, 6, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xC7000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          if (canPop)
            _topIcon(
              Icons.keyboard_arrow_down,
              () => Navigator.of(context).maybePop(),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '第${entry.number}集 · 共${entry.total}集',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xCCFFFFFF),
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
                  ),
                ),
              ],
            ),
          ),
          _topIcon(Icons.person_outline_rounded, _openMine),
          _topIcon(Icons.grid_view_rounded, _openLibrary),
        ],
      ),
    );
  }

  /// 横屏时的顶栏：退出全屏 + 剧名集数
  Widget _wideBar(FeedEntry entry, double safeTop) {
    return Container(
      padding: EdgeInsets.fromLTRB(6, math.max(safeTop, 6), 6, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xA6000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          _topIcon(Icons.fullscreen_exit_rounded, _toggleFullscreen),
          Expanded(
            child: Text(
              '${entry.drama.title} · 第${entry.number}集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
              ),
            ),
          ),
          _topIcon(Icons.person_outline_rounded, _openMine),
          _topIcon(Icons.grid_view_rounded, _openLibrary),
        ],
      ),
    );
  }

  Widget _topIcon(IconData icon, VoidCallback onTap) {    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, size: 22, color: Colors.white),
      ),
    );
  }

  // ------------------------------------------------------------- 右侧栏

  Widget _rail(FeedEntry entry) {
    final liked = Store.instance.isLiked(entry.drama.id);
    final fav = Store.instance.isFav(entry.drama.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _railItem(
          glyph: liked ? '♥' : '♡',
          label: '点赞',
          active: liked,
          activeColor: Hg.likeOn,
          onTap: _toggleLike,
        ),
        _railItem(
          glyph: fav ? '★' : '☆',
          label: '追剧',
          active: fav,
          activeColor: Hg.favOn,
          onTap: _toggleFav,
        ),
        _railItem(glyph: '', label: '分享', onTap: _share, icon: Icons.ios_share),
      ],
    );
  }

  Widget _railItem({
    required String glyph,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? activeColor,
    IconData? icon,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(
                icon,
                size: 26,
                color: Colors.white,
                shadows: const [Shadow(color: Color(0x80000000), blurRadius: 6)],
              )
            else
              Text(
                glyph,
                style: TextStyle(
                  fontSize: 30,
                  height: 1,
                  color: active ? (activeColor ?? Colors.white) : Colors.white,
                  shadows: const [
                    Shadow(color: Color(0x80000000), blurRadius: 6),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: [Shadow(color: Color(0x80000000), blurRadius: 6)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 底部信息

  Widget _info(FeedEntry entry) {
    final tags = <String>[];
    void addTag(String value) {
      final text = value.trim();
      if (text.isEmpty || tags.contains(text) || tags.length >= 3) return;
      tags.add(text);
    }

    addTag(entry.drama.category);
    for (final tag in entry.drama.tags) {
      addTag(tag);
    }
    final intro = entry.drama.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '@${entry.drama.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
          ),
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x29FFFFFF),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xE6FFFFFF),
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 5),
        Text(
          '第${entry.number}集',
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xE6FFFFFF),
            shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
          ),
        ),
        if (intro.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            intro,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: Color(0xD9FFFFFF),
              shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------- 控制条

  Widget _controls(FeedEntry entry, double safeBottom) {
    final ratio = _dragging
        ? _dragRatio
        : (_dur.inMilliseconds == 0
              ? 0.0
              : (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0));
    final shown = _dragging
        ? Duration(milliseconds: (_dragRatio * _dur.inMilliseconds).round())
        : _pos;
    return Container(
      padding: EdgeInsets.fromLTRB(14, 6, 14, safeBottom + 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _progressBar(ratio),
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  _player.playOrPause();
                  _scheduleHide();
                },
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 30,
                  height: 26,
                  child: Icon(
                    _playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                '${_fmt(shown)} / ${_fmt(_dur)}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xB3FFFFFF),
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              _barButton(_rate == 1 ? '倍速' : '${_rate}x', _pickRate),
              _barButton(_quality == 0 ? '清晰度' : '${_quality}P', _pickQuality),
              _barButton('选集', _togglePanel, active: _panel),
              _iconBarButton(
                _fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                _toggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconBarButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 32,
        height: 28,
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: const Color(0xE6FFFFFF)),
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: active ? const Color(0x26FFFFFF) : Colors.transparent,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: active ? Hg.brand2 : const Color(0xE6FFFFFF),
          ),
        ),
      ),
    );
  }

  Widget _progressBar(double ratio) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void update(double dx) {
          final value = (dx / width).clamp(0.0, 1.0);
          setState(() => _dragRatio = value);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final value = (details.localPosition.dx / width).clamp(0.0, 1.0);
            setState(() => _dragRatio = value);
            _seekTo(Duration(milliseconds: (value * _dur.inMilliseconds).round()));
          },
          onHorizontalDragStart: (details) {
            _holdUi();
            setState(() {
              _dragging = true;
              _dragRatio = ratio;
            });
            update(details.localPosition.dx);
          },
          onHorizontalDragUpdate: (details) => update(details.localPosition.dx),
          onHorizontalDragEnd: (_) {
            final value = _dragRatio;
            setState(() => _dragging = false);
            _seekTo(Duration(milliseconds: (value * _dur.inMilliseconds).round()));
            _scheduleHide();
          },
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            height: 20,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: const Color(0x3DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: Hg.brand,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(ratio * 2 - 1, 0),
                  child: Container(
                    width: _dragging ? 12 : 8,
                    height: _dragging ? 12 : 8,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 4)],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------- 选集浮层

  Widget _episodePanel(FeedEntry entry, double bottomBase, double safeTop) {
    final slot = _slots[_index];
    final episodes = slot.detail?.episodes ?? const <Episode>[];
    final watched = Store.instance.watched(entry.drama.id);
    return Positioned(
      left: 14,
      right: 74,
      bottom: bottomBase + 12,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.46,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Hg.panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Hg.line2),
            boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 28)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Row(
                  children: [
                    Text(
                      '选集 · 共${episodes.length}集',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Hg.text,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _togglePanel,
                      behavior: HitTestBehavior.opaque,
                      child: const SizedBox(
                        width: 32,
                        height: 26,
                        child: Icon(Icons.close, size: 16, color: Hg.text2),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: episodes.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.fromLTRB(14, 4, 14, 18),
                        child: Text(
                          '正在读取分集…',
                          style: TextStyle(fontSize: 12.5, color: Hg.text3),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 5,
                              childAspectRatio: 1.32,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: episodes.length,
                        itemBuilder: (context, i) {
                          final episode = episodes[i];
                          final current = episode.number == entry.number;
                          final seen = watched.contains(episode.number);
                          return GestureDetector(
                            onTap: () => _jumpToEpisode(episode.number),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: current ? Hg.brandDim : Hg.bg3,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: current ? Hg.brand : Hg.line2,
                                ),
                              ),
                              child: Text(
                                '${episode.number}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: current
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: current
                                      ? Hg.brand2
                                      : (seen ? Hg.text3 : Hg.text2),
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
      ),
    );
  }

  // ------------------------------------------------------------- 状态层

  Widget _loadingLayer() {
    return IgnorePointer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _status,
            style: const TextStyle(fontSize: 12.5, color: Color(0xCCFFFFFF)),
          ),
        ],
      ),
    );
  }

  Widget _errorLayer(FeedEntry entry) {
    return ColoredBox(
      color: const Color(0xD9000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.drama.cover.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    entry.drama.cover,
                    width: 108,
                    height: 144,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                _error,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Color(0xCCFFFFFF),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _pill('重试', primary: true, onTap: () => _playCurrent()),
                  const SizedBox(width: 10),
                  _pill('换一部', onTap: _advanceSlot),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, {bool primary = false, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: primary ? Hg.brand : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: primary ? Hg.brand : Hg.line2),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _toastLayer() {
    return Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.of(context).size.height * 0.34,
      child: IgnorePointer(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xA8000000),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _toast,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fatal(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 34, color: Hg.text2),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, height: 1.5, color: Hg.text2),
            ),
            const SizedBox(height: 18),
            _pill(
              '重试',
              primary: true,
              onTap: () {
                final pages = _pages;
                if (pages != null) {
                  pages.removeListener(_onScroll);
                  pages.dispose();
                  _pages = null;
                }
                ++_generation; // 作废所有在途 resolve / 预加载
                setState(() {
                  _error = '';
                  _index = 0;
                  _stageIdx = 0;
                  _videoReady = false;
                  _suspended = false;
                  _slots.clear();
                  _details.clear();
                  _pool.clear();
                  _all.clear();
                  _known.clear();
                  _recent.clear();
                  _catalogPage = 0;
                  _poolDone = false;
                  _webDone = false;
                  _engineDone = false;
                  _exhausted = false;
                  _appending = false;
                });
                WebCatalog.instance.reset();
                _boot();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _bootView() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Hg.logo2, Hg.logo],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: const Text(
                '剧',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 18),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0x66FFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return value.inHours > 0
        ? '${value.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }
}
