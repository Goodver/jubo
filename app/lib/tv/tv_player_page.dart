// 剧播 TV · 正式播放页（P2）
//
// 单 Player（电视内存只有 2 GiB，不做手机端那种双 stage 预热）；
// 解码档位由 TvSession / DecodePolicy 决定，切换后重开当前集立即生效。
// 遥控器：左右 ±10s、上下切集、0 切换居中/铺满、OK 唤出/操作控制条、
// 菜单键解码设置、返回键收起/退出。控制条只保留遥控器做不到的功能按钮。

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine.dart';
import '../models.dart';
import '../store.dart';
import 'decode_settings.dart';
import 'device_profile.dart';
import 'tv_session.dart';
import 'tv_ui.dart';

/// 控制条上的二级选择面板：倍速 / 清晰度共用一套 DPAD 交互。
enum _PickerKind { rate, quality }

class TvPlayerPage extends StatefulWidget {
  const TvPlayerPage({
    super.key,
    required this.drama,
    required this.episodes,
    required this.initialIndex,
  });

  final Drama drama;
  final List<Episode> episodes;
  final int initialIndex;

  @override
  State<TvPlayerPage> createState() => _TvPlayerPageState();
}

class _TvPlayerPageState extends State<TvPlayerPage> {
  final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  int _index = 0;
  int _generation = 0;
  int _controlIndex = 0;
  bool _loading = true;
  bool _controls = false;
  bool _playing = false;
  String _error = '';
  String _toast = '';
  String _mpvInfo = '';
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  PlaybackPlan? _plan;
  Timer? _toastTimer;
  int _lastSaveAt = 0;
  bool _fillScreen = false;
  double _rate = 1.0;
  int _quality = 0; // 0 = 自动（沿用 DecodeDecision.quality 作上限）
  _PickerKind? _picker;
  int _pickerIndex = 0;

  static const List<double> _rateOptions = <double>[0.75, 1.0, 1.25, 1.5, 2.0];
  static const String _prefRate = 'tv.play.rate';
  static const String _prefQuality = 'tv.play.quality';

  /// 竖版短剧在 16:9 电视上 contain 后两侧各留约 1/3，用剧集封面做一层
  /// 全屏模糊氛围背景铺满。缓存成 final widget，避免 position 每秒刷新时
  /// 反复重建 ImageFiltered 栅格化。
  late final Widget _backdrop = RepaintBoundary(
    child: _AmbientBackdrop(cover: widget.drama.cover),
  );

  // build 1031：删掉「上集 / 下集 / 退10秒 / 进10秒 / 铺满」——遥控器
  // 上下切集、左右 ±10s、数字 0 切换画面比例已经能做，控制条只剩 6 个
  // 遥控器做不到的设置类按钮，一行放得下，不用再横向滚动找「倍速 / 清晰」。
  static const List<({String label, IconData icon})> _buttons =
      <({String label, IconData icon})>[
        (label: '播放', icon: Icons.play_arrow_rounded),
        (label: '选集', icon: Icons.list_rounded),
        (label: '解码', icon: Icons.tune),
        (label: '倍速', icon: Icons.speed_rounded),
        (label: '清晰', icon: Icons.hd_rounded),
        (label: '退出', icon: Icons.arrow_back_rounded),
      ];

  Episode get _episode => widget.episodes[_index];

  int get _effectiveQuality =>
      _quality > 0 ? _quality : TvSession.instance.decision.quality;

  /// 0 = 自动 + 该集实际可用的全部档位（Go 侧 nativePlaybackChoices 收集）。
  List<int> get _qualityOptions {
    final List<int> values = <int>[0, ...?_plan?.qualities];
    // 个别站源不返回 variants，也要把当前实际档位列出来，避免只有「自动」。
    final int actual = _plan?.quality ?? 0;
    if (actual > 0) values.add(actual);
    final Set<int> seen = <int>{};
    return <int>[
      for (final int q in values)
        if (q >= 0 && seen.add(q)) q,
    ];
  }

  List<String> get _pickerOptions => _picker == _PickerKind.rate
      ? <String>[for (final double r in _rateOptions) '${r}x']
      : <String>[for (final int q in _qualityOptions) q == 0 ? '自动' : '${q}P'];

  bool _isPickerCurrent(int index) {
    if (_picker == _PickerKind.rate) {
      return index < _rateOptions.length && _rateOptions[index] == _rate;
    }
    final List<int> values = _qualityOptions;
    return index < values.length && values[index] == _quality;
  }

  String _controlLabel(int index) {
    switch (index) {
      case 0:
        return _playing ? '暂停' : '播放';
      case 3:
        return _rate == 1 ? '倍速' : '${_rate}x';
      case 4:
        return _quality == 0 ? '清晰' : '${_quality}P';
      default:
        return _buttons[index].label;
    }
  }

  /// 竖版短剧在横屏电视上的两种取舍：居中完整画面 ↔ cover 铺满裁切。
  /// 控制条不再放按钮，改由遥控器数字 0 / 画面比例键切换。
  void _toggleFillScreen() {
    _fillScreen = !_fillScreen;
    _toast = _fillScreen ? '画面铺满（上下会裁切）' : '居中完整画面';
    _showToast();
  }

  void _log(String message) {
    // ignore: avoid_print
    print('[TV-UI] $message');
  }

  void _decodeLog(String message) {
    // ignore: avoid_print
    print('[TV-DECODE] $message');
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.episodes.length - 1).toInt();
    HardwareKeyboard.instance.addHandler(_onKey);
    _attachStreams();
    unawaited(_boot());
  }

  /// 倍速 / 清晰度是跨集、跨次启动保留的播放偏好，先读再开第一集。
  Future<void> _boot() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final double rate = prefs.getDouble(_prefRate) ?? 1.0;
      final int quality = prefs.getInt(_prefQuality) ?? 0;
      if (mounted) {
        _rate = _rateOptions.contains(rate) ? rate : 1.0;
        _quality = quality >= 0 ? quality : 0;
      }
    } catch (_) {}
    await _open(_index, resume: true);
  }

  Future<void> _savePrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefRate, _rate);
      await prefs.setInt(_prefQuality, _quality);
    } catch (_) {}
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _toastTimer?.cancel();
    for (final StreamSubscription<dynamic> sub in _subs) {
      unawaited(sub.cancel());
    }
    unawaited(_saveMark());
    _player.dispose();
    super.dispose();
  }

  void _attachStreams() {
    _subs.add(
      _player.stream.playing.listen((bool value) {
        if (mounted) setState(() => _playing = value);
      }),
    );
    _subs.add(
      _player.stream.position.listen((Duration value) {
        if (!mounted) return;
        _pos = value;
        if (mounted) setState(() {});
        _maybeSave();
      }),
    );
    _subs.add(
      _player.stream.duration.listen((Duration value) {
        if (mounted) setState(() => _dur = value);
      }),
    );
    _subs.add(
      _player.stream.completed.listen((bool done) {
        if (done && mounted) unawaited(_switchEpisode(_index + 1));
      }),
    );
    _subs.add(
      _player.stream.error.listen((String message) {
        if (message.isEmpty || !mounted) return;
        _log('mpv error: $message');
        setState(() {
          _error = message;
          _loading = false;
          _controls = false;
        });
      }),
    );
  }

  void _maybeSave() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveAt < 10000) return;
    _lastSaveAt = now;
    unawaited(_saveMark());
  }

  Future<void> _saveMark() async {
    if (_pos.inMilliseconds <= 0) return;
    try {
      await Store.instance.saveMark(
        widget.drama.id,
        episode: _episode.number,
        ms: _pos.inMilliseconds,
        title: widget.drama.title,
        cover: widget.drama.cover,
        drama: widget.drama.toJson(),
      );
    } catch (_) {}
  }

  Future<void> _configure(PlaybackPlan plan) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final DecodeDecision decision = TvSession.instance.decision;
    await platform.setProperty(
      'demuxer-lavf-o',
      <String>[
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (plan.decryptionKey.isNotEmpty)
          'decryption_key=${plan.decryptionKey}',
      ].join(','),
    );
    await platform.setProperty('network-timeout', '20');
    // 2 GiB 内存电视：缓冲与预读按手机侧减半
    await platform.setProperty('cache-secs', '10');
    await platform.setProperty('demuxer-readahead-secs', '12');
    await platform.setProperty('vf', '');
    await platform.setProperty('hwdec', decision.hwdec);
    _decodeLog(
      'player hwdec=${decision.hwdec} '
      'pref=${decision.preference.name} '
      'family=${decision.family.name} quality=${decision.quality}',
    );
  }

  Future<void> _open(
    int index, {
    bool resume = false,
    Duration? startAt,
  }) async {
    if (index < 0 || index >= widget.episodes.length) return;
    final int ticket = ++_generation;
    final Stopwatch sw = Stopwatch()..start();
    final Episode episode = widget.episodes[index];
    _log('open ${widget.drama.title} 第${episode.number}集 ticket=$ticket');
    setState(() {
      _index = index;
      _loading = true;
      _error = '';
      _controls = false;
      _pos = Duration.zero;
      _dur = Duration.zero;
    });
    try {
      final PlaybackPlan plan = await Engine.instance.resolve(
        widget.drama,
        episode,
        quality: _effectiveQuality,
        stillValid: () => mounted && ticket == _generation,
      );
      if (!mounted || ticket != _generation) return;
      if (plan.url.isEmpty) throw StateError('播放地址为空');
      await _configure(plan);
      Duration start = startAt ?? Duration.zero;
      if (resume && startAt == null) {
        final WatchMark? mark = Store.instance.mark(widget.drama.id);
        if (mark != null && mark.episode == episode.number) {
          start = Duration(milliseconds: mark.ms);
        }
      }
      await _player.open(
        Media(plan.url, httpHeaders: plan.headers, start: start),
        play: true,
      );
      // mpv 换新文件后倍速要重新下发，否则切集自动回到 1.0x。
      await _player.setRate(_rate);
      if (!mounted || ticket != _generation) return;
      setState(() {
        _plan = plan;
        _loading = false;
      });
      _log(
        'resolve ok ${sw.elapsedMilliseconds}ms quality=${plan.quality} '
        'keyLen=${plan.decryptionKey.length} start=${start.inSeconds}s',
      );
      unawaited(Store.instance.markWatched(widget.drama.id, episode.number));
      unawaited(_probe());
    } catch (error) {
      if (!mounted || ticket != _generation) return;
      _log('open FAILED: $error');
      setState(() {
        _error = error.toString();
        _loading = false;
        _controls = false;
      });
    }
  }

  /// 读回 mpv 实际生效的解码器，确认策略与运行时一致。
  Future<void> _probe() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final platform = _player.platform;
    if (platform is! NativePlayer || !mounted) return;
    const List<String> keys = <String>[
      'hwdec-current',
      'video-format',
      'video-params/pixelformat',
      'video-params/w',
      'video-params/h',
    ];
    final Map<String, String> values = <String, String>{};
    for (final String key in keys) {
      try {
        values[key] = await platform.getProperty(key);
      } catch (_) {
        values[key] = '?';
      }
    }
    _mpvInfo =
        'hwdec=${values['hwdec-current']} '
        'fmt=${values['video-format']} '
        'pix=${values['video-params/pixelformat']} '
        '${values['video-params/w']}x${values['video-params/h']}';
    _decodeLog('active $_mpvInfo');
    if (mounted) setState(() {});
  }

  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= widget.episodes.length) {
      _toast = index < 0 ? '已经是第一集' : '已经是最后一集';
      _toastTimer?.cancel();
      _toastTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _toast = '');
      });
      setState(() {});
      return;
    }
    await _saveMark();
    await _open(index);
    _toast = '第${_episode.number}集';
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = '');
    });
    if (mounted) setState(() {});
  }

  void _seek(Duration delta) {
    Duration target = _pos + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_dur > Duration.zero && target > _dur) target = _dur;
    unawaited(_player.seek(target));
    _toast = '${_fmt(target)} / ${_fmt(_dur)}';
    _showToast();
  }

  void _showToast() {
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = '');
    });
    if (mounted) setState(() {});
  }

  Future<void> _openDecodeSettings() async {
    final DecodePreference? picked = await showDecodeSettings(
      context,
      profile: TvSession.instance.profile,
      preference: TvSession.instance.preference,
    );
    if (picked == null || !mounted) return;
    await TvSession.instance.setPreference(picked);
    _controls = false;
    await _open(_index);
  }

  void _activateControl(int index) {
    // 记住上次选中的按钮，再次按 OK 唤出控制条时直接落回原处。
    _controlIndex = index;
    switch (index) {
      case 0:
        if (_playing) {
          unawaited(_player.pause());
        } else {
          unawaited(_player.play());
        }
        break;
      case 1: // 选集：回到详情页的分集网格
        unawaited(_saveMark());
        if (mounted) Navigator.of(context).pop();
        return;
      case 2:
        unawaited(_openDecodeSettings());
        return;
      case 3:
        _openPicker(_PickerKind.rate);
        return;
      case 4:
        _openPicker(_PickerKind.quality);
        return;
      case 5: // 退出
        unawaited(_saveMark());
        if (mounted) Navigator.of(context).pop();
        return;
    }
    if (mounted) setState(() => _controls = false);
  }

  void _openPicker(_PickerKind kind) {
    final int count = kind == _PickerKind.rate
        ? _rateOptions.length
        : _qualityOptions.length;
    int initial = 0;
    for (int i = 0; i < count; i++) {
      final bool current = kind == _PickerKind.rate
          ? _rateOptions[i] == _rate
          : _qualityOptions[i] == _quality;
      if (current) {
        initial = i;
        break;
      }
    }
    setState(() {
      _picker = kind;
      _pickerIndex = initial;
      _controls = true;
    });
  }

  Future<void> _applyPicker(int index) async {
    final _PickerKind? kind = _picker;
    if (kind == null) return;
    if (kind == _PickerKind.rate) {
      if (index < 0 || index >= _rateOptions.length) return;
      _rate = _rateOptions[index];
      await _player.setRate(_rate);
      unawaited(_savePrefs());
      if (mounted) {
        setState(() {
          _picker = null;
          _controls = false;
        });
      }
      _toast = _rate == 1 ? '倍速 正常' : '倍速 ${_rate}x';
      _showToast();
      return;
    }
    final List<int> values = _qualityOptions;
    if (index < 0 || index >= values.length) return;
    final int picked = values[index];
    if (picked == _quality) {
      if (mounted) setState(() => _picker = null);
      return;
    }
    final Duration keep = _pos;
    _quality = picked;
    unawaited(_savePrefs());
    if (mounted) {
      setState(() {
        _picker = null;
        _controls = false;
      });
    }
    _toast = picked == 0 ? '清晰度 自动' : '清晰度 ${picked}P';
    _showToast();
    // 换档要重新取流；带上当前进度，不让用户从头看。
    await _open(_index, startAt: keep);
  }

  bool _onKey(KeyEvent event) {
    if (!tvIsCurrent(context) || event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (_error.isNotEmpty) {
      if (TvKeys.activate(key)) {
        unawaited(_open(_index));
        return true;
      }
      return false;
    }
    if (TvKeys.menu(key)) {
      unawaited(_openDecodeSettings());
      return true;
    }
    // 二级面板打开时只留它自己的 TvFocusGrid 处理按键；非 Android 的
    // ESC / Backspace 不走 PopScope，这里手动收起。
    if (_picker != null) {
      if (TvKeys.back(key) && key != LogicalKeyboardKey.goBack) {
        setState(() => _picker = null);
        return true;
      }
      return false;
    }
    // 「铺满 / 居中」按钮已删，功能保留在遥控器数字 0（或画面比例键）上。
    // 控制条显示时也要能切，所以放在 _controls 分支之前并显式消费。
    if (key == LogicalKeyboardKey.digit0 ||
        key == LogicalKeyboardKey.numpad0 ||
        key == LogicalKeyboardKey.zoomToggle) {
      _toggleFillScreen();
      return true;
    }
    // 返回键完全交给 PopScope：HardwareKeyboard 返回 true 也挡不住 Android
    // 的 navigation pop，两套机制同时收起控制条反而可能「一次返回直接退出」。
    if (TvKeys.back(key)) return false;
    if (_controls) {
      // 控制条自己的 TvFocusGrid 处理方向键与 OK；上键额外收起控制条
      if (TvKeys.up(key)) {
        setState(() => _controls = false);
        return true;
      }
      // 左右键由控制条 TvFocusGrid 移动按钮焦点，页面必须显式消费。
      // HardwareKeyboard 的 _dispatchKeyEvent 会把事件派给**所有** handler
      // （handled |= handler(event)），FocusManager 也在其中；一旦控制条里
      // 有可聚焦控件（原来的 Slider），同一按键就会顺带调整进度条 → seek。
      // 现在进度条已改成不可聚焦的展示条 + ExcludeFocus，这里再兜一层。
      if (TvKeys.left(key) || TvKeys.right(key)) return true;
      return false;
    }
    if (TvKeys.activate(key)) {
      setState(() => _controls = true);
      return true;
    }
    if (TvKeys.left(key)) {
      _seek(const Duration(seconds: -10));
      return true;
    }
    if (TvKeys.right(key)) {
      _seek(const Duration(seconds: 10));
      return true;
    }
    if (TvKeys.up(key)) {
      unawaited(_switchEpisode(_index - 1));
      return true;
    }
    if (TvKeys.down(key)) {
      unawaited(_switchEpisode(_index + 1));
      return true;
    }
    return false;
  }

  String _fmt(Duration value) {
    final int total = value.inSeconds;
    final String mm = (total ~/ 60).toString().padLeft(2, '0');
    final String ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// 倍速 / 清晰度共用的二级面板。与控制条按钮行互斥渲染，
  /// 同一时刻只有一个 TvFocusGrid 处于活动状态，不会抢按键。
  Widget _buildPicker() {
    final List<String> options = _pickerOptions;
    final bool rate = _picker == _PickerKind.rate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          rate ? '倍速播放 · 左右选择 / OK 确定 / 返回键取消' : '清晰度 · 左右选择 / OK 确定 / 返回键取消',
          style: const TextStyle(fontSize: 11, color: Tv.text2),
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: Tv.chipHeight,
          child: TvFocusGrid(
            key: ValueKey<String>('player-picker-${rate ? 'rate' : 'quality'}'),
            axis: Axis.horizontal,
            itemCount: options.length,
            itemExtent: 104,
            gap: 8,
            crossExtent: Tv.chipHeight,
            active: true,
            initialIndex: _pickerIndex,
            onSelect: (int index) => unawaited(_applyPicker(index)),
            onUnhandledKey: (LogicalKeyboardKey key, int index) {
              if (TvKeys.up(key)) {
                setState(() => _picker = null);
                return true;
              }
              return false;
            },
            itemBuilder: (_, int index, bool focused) => TvChip(
              label: options[index],
              icon: rate ? Icons.speed_rounded : Icons.hd_rounded,
              focused: focused,
              selected: _isPickerCurrent(index),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final DecodeDecision decision = TvSession.instance.decision;
    final PlaybackPlan? plan = _plan;
    final String qualityLabel = _quality == 0 ? '自动' : '${_quality}P';
    // Android 返回键走 SystemChannels.navigation，不受 HardwareKeyboard
    // handler 的返回值影响；必须用 PopScope 才能做到「先收起控制条」。
    return PopScope<Object?>(
      canPop: !_controls && _picker == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || !mounted) return;
        if (_picker != null) {
          setState(() => _picker = null);
          return;
        }
        if (_controls) setState(() => _controls = false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 竖版短剧（720x1280）在 1920x1080 上 contain 只占中间约 1/3，
            // 两侧留大黑边。用剧集封面做全屏模糊氛围背景铺满，视频层透明。
            _backdrop,
            Video(
              controller: _video,
              controls: NoVideoControls,
              fit: _fillScreen ? BoxFit.cover : BoxFit.contain,
              fill: Colors.transparent,
            ),
            // 顶部信息条
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _controls || _loading ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Tv.gutter,
                    vertical: Tv.pagePaddingV,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0xDD0E0E12), Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${widget.drama.title} · 第${_episode.number}集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: Tv.text,
                          ),
                        ),
                      ),
                      Text(
                        '${decision.modeLabel} · $qualityLabel'
                        '${plan == null ? '' : ' · 实${plan.quality}P'}'
                        '${_rate == 1 ? '' : ' · ${_rate}x'}',
                        style: const TextStyle(fontSize: 11, color: Tv.text2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 中央状态
            if (_loading)
              const Center(
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
            if (_error.isNotEmpty)
              Center(
                child: Container(
                  width: 440,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xEE15151B),
                    borderRadius: BorderRadius.circular(Tv.radiusLg),
                    border: Border.all(color: Tv.danger),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        '播放失败',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Tv.danger,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _error,
                        maxLines: 3,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11.5, color: Tv.text2),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'OK 重试 · 返回键回到选集',
                        style: TextStyle(fontSize: 10.5, color: Tv.text3),
                      ),
                    ],
                  ),
                ),
              ),
            // 短暂提示（seek / 切集）
            if (_toast.isNotEmpty)
              Positioned(
                top: 74,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCC0E0E12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      _toast,
                      style: const TextStyle(fontSize: 14, color: Tv.text),
                    ),
                  ),
                ),
              ),
            // 底部控制条
            if (_controls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                // 控制条整体不进 Flutter 焦点树：TvFocusGrid 走
                // HardwareKeyboard 手工索引，不需要、也不允许系统焦点。
                child: ExcludeFocus(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(
                      Tv.gutter,
                      24,
                      Tv.gutter,
                      Tv.pagePaddingV,
                    ),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: <Color>[Color(0xEE0E0E12), Colors.transparent],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              _fmt(_pos),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Tv.text2,
                              ),
                            ),
                            // 2026-11-08 BUGFIX：原来这里是可聚焦的 Slider。
                            // HardwareKeyboard 会把按键派给 **所有** handler，
                            // FocusManager 再把左右键交给 Slider 的 Shortcuts →
                            // onChanged → seek，于是「左右选按钮」同时拖走进度。
                            // 遥控器本来就拖不动进度条（左右是 ±10s），改成纯展示条。
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: _dur.inMilliseconds > 0
                                      ? (_pos.inMilliseconds /
                                                _dur.inMilliseconds)
                                            .clamp(0.0, 1.0)
                                      : 0,
                                  minHeight: 4,
                                  backgroundColor: const Color(0x44FFFFFF),
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Tv.accent,
                                      ),
                                ),
                              ),
                            ),
                            Text(
                              _fmt(_dur),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Tv.text2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Tv.tightGap),
                        if (_picker == null)
                          TvFocusGrid(
                            key: const ValueKey<String>('player-controls'),
                            axis: Axis.horizontal,
                            itemCount: _buttons.length,
                            // 6 个按钮 × 140 + 5 × 8 = 880dp，1280dp 内一行放满，
                            // 不再需要横向滚动，TvChip 也不必压到 118dp。
                            itemExtent: 140,
                            gap: 8,
                            crossExtent: Tv.chipHeight,
                            active: true,
                            initialIndex: _controlIndex,
                            onSelect: _activateControl,
                            // toast（0 键切铺满、选档提示）会触发 setState 并
                            // 重建控制条子树；把方向键移动后的焦点实时回写，
                            // 重建时 initialIndex 才能落回原处而不是跳回第 0 个。
                            onFocusChange: (int index) => _controlIndex = index,
                            onUnhandledKey:
                                (LogicalKeyboardKey key, int index) {
                                  if (TvKeys.up(key)) {
                                    setState(() => _controls = false);
                                    return true;
                                  }
                                  return false;
                                },
                            itemBuilder: (_, int index, bool focused) => TvChip(
                              label: _controlLabel(index),
                              icon: _buttons[index].icon,
                              focused: focused,
                            ),
                          )
                        else
                          _buildPicker(),
                        const SizedBox(height: 5),
                        Text(
                          _picker == null
                              ? '左右 选按钮 · 上 收起 · OK 确定 · 0 铺满/居中 · 菜单 解码 · 返回 收起'
                              : '左右 选档位 · OK 确定 · 上/返回键 取消',
                          style: const TextStyle(fontSize: 10, color: Tv.text3),
                        ),
                        if (_mpvInfo.isNotEmpty)
                          Text(
                            _mpvInfo,
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: Tv.text3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!_controls && !_loading && _error.isEmpty)
              const Positioned(
                bottom: 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    '左右 ±10秒 · 上下 切集 · 0 铺满/居中 · 菜单 解码 · OK 控制条',
                    style: TextStyle(fontSize: 10, color: Color(0x66FFFFFF)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 全屏氛围背景：把剧集封面放大、模糊、压暗后铺满 16:9 屏幕。
/// 只处理一张静态图，不参与视频帧渲染；外层套 RepaintBoundary，
/// 播放器每秒刷新 position 时不会反复栅格化。
class _AmbientBackdrop extends StatelessWidget {
  const _AmbientBackdrop({required this.cover});

  final String cover;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (cover.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
            child: Image.network(
              cover,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) => const SizedBox.expand(),
            ),
          ),
        const ColoredBox(color: Color(0xB3000000)),
      ],
    );
  }
}
