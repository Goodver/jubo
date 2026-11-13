// 剧播 TV · P0 解码/档位诊断页（保留为二级入口，P2 正式 UI 上线后不再作入口）
//
// 21:3x 第一轮结论：硬解（auto-safe → mediacodec-copy，pix=nv12）把人物肤色
// 解成纯蓝，软解（hwdec=no，pix=yuv420p）为正常肉色；色彩元数据两者都是
// bt.709/limited/bt.709 → 排除矩阵/范围错配，问题是 Amlogic MediaCodec 回读
// 的 NV12 色度平面顺序被反读（U/V 交换）。libmpv 内不含 swapuv 滤镜，硬解侧
// 无法用滤镜修正（实测 lavfi=[swapuv] 直接无画面）。
//
// 22:xx 创维 192.168.5.56（海思 Hi3751V660 / huanglong / Android 12）复测：
// 硬解颜色正常，软解反而多烧 2.55 倍 CPU。结论收窄为 Amlogic tl1 的
// MediaCodec HAL 平台专属缺陷，不能一刀切让所有 TV 走软解。
//
// 现在默认档位由 DecodePolicy 按 SoC 指纹决定（自动 / 硬解 / 软解三档，
// 菜单键或数字 0 打开设置页），数字键 1–4 仍可临时切档做诊断对照。
//
// 全程自动执行；每步打 [TV-P0] / [TV-DECODE] 前缀日志，便于 adb logcat 取证。
// 正式 UI 在 tv_home_page.dart；本页只从主页「解码诊断」入口进入，用于
// 复现色彩问题、四档 A/B 对照，以及重新验证 FFI → 取流 → 出画五步链路。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../engine.dart';
import '../models.dart';
import 'decode_settings.dart';
import 'device_profile.dart';
import 'tv_session.dart';

class _Mode {
  const _Mode(this.label, this.hwdec, this.quality);
  final String label;
  final String hwdec;
  final int quality; // 0 = 不筛选（默认最高档）
}

class TvProbePage extends StatefulWidget {
  const TvProbePage({super.key});

  @override
  State<TvProbePage> createState() => _TvProbePageState();
}

class _TvProbePageState extends State<TvProbePage> {
  // 1280 档（720x1280）在 1080p 横屏电视上显示宽约 608px，清晰度足够，
  // 软解负载远低于 1920 档。默认取 0（软解@1280）或 2（硬解@1280），
  // 由 DecodePolicy 按 SoC 决定；另外两档只用于诊断对照。
  static const List<_Mode> _modes = <_Mode>[
    _Mode('no @1280 软解', 'no', 1280),
    _Mode('no @1920 软解对照', 'no', 0),
    _Mode('auto-safe @1280 硬解', 'auto-safe', 1280),
    _Mode('auto-safe @960 硬解对照', 'auto-safe', 960),
  ];

  final List<String> _lines = <String>[];
  Player? _player;
  VideoController? _video;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<String>? _errorSub;

  bool _ffi = false;
  bool _https = false;
  bool _cenc = false;
  bool _decoded = false;
  bool _failed = false;
  String _title = '';
  String _qualityText = '';
  String _mpvInfo = '';
  int _resolveMs = -1;
  int _modeIdx = 0;

  TvDeviceProfile _profile = TvDeviceProfile.empty;
  DecodePreference _preference = DecodePreference.auto;
  DecodeDecision? _decision;

  Drama? _drama;
  Episode? _episode;
  bool _switching = false;
  bool _settingsOpen = false;

  void _log(String message) {
    // print 会进 logcat 的 flutter tag；统一前缀方便 `adb logcat -s flutter`
    // ignore: avoid_print
    print('[TV-P0] $message');
    if (!mounted) return;
    setState(() {
      _lines.add(message);
      if (_lines.length > 60) _lines.removeAt(0);
    });
  }

  /// 解码策略单独一个 tag，实机取证时 `adb logcat -s flutter | grep TV-DECODE`。
  void _decodeLog(String message) {
    // ignore: avoid_print
    print('[TV-DECODE] $message');
    _log('DECODE $message');
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    unawaited(_run());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    unawaited(_positionSub?.cancel());
    unawaited(_errorSub?.cancel());
    _player?.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    // 设置页有自己的 DPAD handler；主页此时必须让路，否则数字键会被两边同时消费。
    if (_settingsOpen || event is! KeyDownEvent || _switching) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.digit0) {
      unawaited(_openSettings());
      return true;
    }
    int idx = -1;
    if (key == LogicalKeyboardKey.digit1) idx = 0;
    if (key == LogicalKeyboardKey.digit2) idx = 1;
    if (key == LogicalKeyboardKey.digit3) idx = 2;
    if (key == LogicalKeyboardKey.digit4) idx = 3;
    if (idx < 0) return false;
    unawaited(_switchMode(idx));
    return true;
  }

  int _defaultModeIdx() => (_decision?.isHardware ?? false) ? 2 : 0;

  /// 打开解码设置；选完立即按新策略重开播放，便于现场对比颜色与流畅度。
  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      final DecodePreference? picked = await showDecodeSettings(
        context,
        profile: _profile,
        preference: _preference,
      );
      if (picked == null || picked == _preference) return;
      await TvSession.instance.setPreference(picked);
      _preference = TvSession.instance.preference;
      final DecodeDecision decision = TvSession.instance.decision;
      _decision = decision;
      _decodeLog(
        'override=${picked.name} hwdec=${decision.hwdec} '
        'family=${decision.family.name} reason=${decision.reason}',
      );
      await _switchMode(_defaultModeIdx());
    } finally {
      _settingsOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _run() async {
    _log('==== TV P0 解码/档位诊断 start ====');
    _log(
      'platform=${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    _log('deviceTime=${DateTime.now().toIso8601String()}');
    try {
      // 平台指纹与解码档位由 TV boot 统一初始化，这里只读会话，避免重复
      // initialize 把 Go 侧设备档案重置掉。
      _profile = TvSession.instance.profile;
      _preference = TvSession.instance.preference;
      final DecodeDecision decision = TvSession.instance.decision;
      _decision = decision;
      _decodeLog('device=${_profile.summary}');
      _decodeLog('fingerprint=${_profile.fingerprint}');
      _decodeLog('hevcDecoders=[${_profile.hevcDecoders.join(', ')}]');
      _decodeLog(
        'pref=${_preference.name} family=${decision.family.name} '
        'hwdec=${decision.hwdec} quality=${decision.quality}',
      );
      _decodeLog('reason=${decision.reason}');

      _ffi = true;
      _log(
        'STEP 1/5 engine ready (initialized at TV boot, 32bit libhgnative.so)',
      );

      final page = await Engine.instance.catalog(page: 1);
      _log('STEP 2/5 catalog OK items=${page.items.length}');
      if (page.items.isEmpty) throw StateError('目录为空');
      _drama = page.items.first;
      _title = _drama!.title;

      final DramaDetail detail = await Engine.instance.detail(_drama!);
      _log('STEP 3/5 detail OK chapters=${detail.episodes.length}');
      if (detail.episodes.isEmpty) throw StateError('分集为空');
      _episode = detail.episodes.first;
      _log('drama=$_title episode=${_episode!.title}');

      final Player player = Player();
      _player = player;
      _video = VideoController(player);
      _positionSub = player.stream.position.listen((Duration pos) {
        if (!_decoded && pos.inMilliseconds > 500) {
          _decoded = true;
          _log('STEP 5/5 PLAYBACK OK position=${pos.inSeconds}s 画面已解码推进');
          if (mounted) setState(() {});
        }
      });
      _errorSub = player.stream.error.listen((String error) {
        _log('mpv error: $error');
      });

      await _openMode(_defaultModeIdx());
      _log(
        'DIAG 策略生效=${_modes[_modeIdx].label}；'
        '菜单键/数字 0 打开解码设置，1–4 可临时切档作对照（重启后回到策略档）',
      );
      if (mounted) setState(() {});
    } catch (error, stack) {
      _failed = true;
      _log('FAILED: $error');
      _log('stack: ${stack.toString().split('\n').take(3).join(' | ')}');
      if (mounted) setState(() {});
    }
  }

  Future<void> _configure(PlaybackPlan plan, _Mode mode) async {
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
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
    // 2 GiB 内存 / 约 800 MB 可用：缓冲与预读比手机侧减半
    await platform.setProperty('cache-secs', '10');
    await platform.setProperty('demuxer-readahead-secs', '12');
    await platform.setProperty('vf', '');
    await platform.setProperty('hwdec', mode.hwdec);
    _log('CONFIG ${mode.label} hwdec=${mode.hwdec} quality=${mode.quality}');
  }

  Future<void> _openMode(int idx) async {
    _modeIdx = idx;
    final _Mode mode = _modes[idx];
    final Stopwatch sw = Stopwatch()..start();
    final PlaybackPlan plan = await Engine.instance.resolve(
      _drama!,
      _episode!,
      quality: mode.quality,
    );
    sw.stop();
    _resolveMs = sw.elapsedMilliseconds;
    _https = true;
    _cenc = plan.decryptionKey.isNotEmpty;
    _qualityText = plan.qualities.isEmpty ? 'single' : plan.qualities.join('/');
    _log(
      'STEP 4/5 resolve OK ${_resolveMs}ms quality=${plan.quality} '
      'keyLen=${plan.decryptionKey.length} qualities=$_qualityText',
    );
    if (plan.url.isEmpty) throw StateError('播放地址为空');
    await _configure(plan, mode);
    await _player!.open(Media(plan.url, httpHeaders: plan.headers), play: true);
    _decoded = false;
    _log('OPEN ok ${mode.label} playing=${_player!.state.playing}');
    unawaited(_probeProperties(mode));
  }

  /// 读回解码器/色彩/分辨率/掉帧，用来判断颜色与流畅度
  Future<void> _probeProperties(_Mode mode) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final platform = _player?.platform;
    if (platform is! NativePlayer) return;
    const List<String> keys = <String>[
      'hwdec-current',
      'video-format',
      'video-params/pixelformat',
      'video-params/colormatrix',
      'video-params/w',
      'video-params/h',
      'container-fps',
      'dropped-frame-count',
    ];
    final Map<String, String> v = <String, String>{};
    for (final String key in keys) {
      try {
        v[key] = await platform.getProperty(key);
      } catch (_) {
        v[key] = '?';
      }
    }
    _mpvInfo =
        'hwdec=${v['hwdec-current']} fmt=${v['video-format']} '
        'pix=${v['video-params/pixelformat']} matrix=${v['video-params/colormatrix']} '
        '${v['video-params/w']}x${v['video-params/h']}';
    _log(
      'MPV [${mode.label}] $_mpvInfo fps=${v['container-fps']} '
      'dropped=${v['dropped-frame-count']}',
    );
    _decodeLog(
      'active[${mode.label}] $_mpvInfo '
      'dropped=${v['dropped-frame-count']}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _switchMode(int idx) async {
    if (_switching || _drama == null || _episode == null) return;
    _switching = true;
    _log('DIAG SWITCH -> ${_modes[idx].label}');
    try {
      await _openMode(idx);
      _log('DIAG REOPEN ok ${_modes[idx].label}');
    } catch (error) {
      _log('DIAG SWITCH FAILED: $error');
    } finally {
      _switching = false;
      if (mounted) setState(() {});
    }
  }

  Widget _badge(String label, bool ok) {
    final Color color = ok ? const Color(0xFF4ADE80) : const Color(0xFFFF6B6B);
    return Container(
      margin: const EdgeInsets.only(right: 10, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${ok ? "✓" : "·"} $label',
        style: TextStyle(
          fontSize: 16,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final VideoController? video = _video;
    final List<String> shown = _lines.length > 16
        ? _lines.sublist(_lines.length - 16)
        : _lines;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (video != null)
            Video(
              controller: video,
              controls: NoVideoControls,
              fit: BoxFit.contain,
              fill: Colors.black,
            )
          else
            const Center(
              child: SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 560,
              margin: const EdgeInsets.all(28),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xE0080B14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x44FFFFFF)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '剧播 TV · 按 SoC 自动选解',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _profile.summary,
                    style: TextStyle(fontSize: 15, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    children: <Widget>[
                      _badge('FFI 32位', _ffi),
                      _badge('HTTPS/CA', _https),
                      _badge('CENC key', _cenc),
                      _badge('出画', _decoded),
                    ],
                  ),
                  if (_title.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '$_title · 第${_episode?.number ?? 1}集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        color: Color(0xFFB9C7EE),
                      ),
                    ),
                    Text(
                      'resolve ${_resolveMs}ms · 清晰度 $_qualityText',
                      style: TextStyle(fontSize: 14, color: Colors.grey[400]),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B2740),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'MODE ${_modeIdx + 1}/4  ${_modes[_modeIdx].label}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF8FD0FF),
                          ),
                        ),
                        if (_decision != null) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            'DECODE ${_preference.label} → ${_decision!.modeLabel}'
                            ' · ${_decision!.family.label}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF9FB4D8),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_mpvInfo.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      _mpvInfo,
                      maxLines: 2,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9FB4D8),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    '菜单键 / 数字 0：解码设置（自动 / 硬解 / 软解）',
                    style: TextStyle(fontSize: 13, color: Color(0xFF8FD0FF)),
                  ),
                  const SizedBox(height: 10),
                  Container(height: 1, color: const Color(0x33FFFFFF)),
                  const SizedBox(height: 8),
                  for (final String line in shown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: _failed && line.startsWith('FAILED')
                              ? const Color(0xFFFF6B6B)
                              : const Color(0xFFCFD8EE),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
