// 剧播 TV · 解码设置页（P2，10-foot / 纯遥控器操作）
//
// 只负责三件事：显示这台电视的 SoC 指纹、说明「自动」为什么这么选、
// 让用户用方向键 + OK 覆盖成硬解或软解。选完立刻返回播放器并生效。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_profile.dart';
import 'tv_ui.dart';

/// 返回用户新选的档位；按返回键取消时返回 null。
Future<DecodePreference?> showDecodeSettings(
  BuildContext context, {
  required TvDeviceProfile profile,
  required DecodePreference preference,
}) {
  return Navigator.of(context).push<DecodePreference>(
    MaterialPageRoute<DecodePreference>(
      builder: (_) =>
          DecodeSettingsPage(profile: profile, preference: preference),
    ),
  );
}

class DecodeSettingsPage extends StatefulWidget {
  const DecodeSettingsPage({
    super.key,
    required this.profile,
    required this.preference,
  });

  final TvDeviceProfile profile;
  final DecodePreference preference;

  @override
  State<DecodeSettingsPage> createState() => _DecodeSettingsPageState();
}

class _DecodeSettingsPageState extends State<DecodeSettingsPage> {
  late int _focused;
  final List<FocusNode> _nodes = List<FocusNode>.generate(
    3,
    (_) => FocusNode(),
  );

  @override
  void initState() {
    super.initState();
    _focused = widget.preference.index;
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nodes[_focused].requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return true;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _choose(_focused);
      return true;
    }
    // adb input keyevent 8/9/10 直选，方便无遥控器时取验证据。
    if (key == LogicalKeyboardKey.digit1) {
      _choose(0);
      return true;
    }
    if (key == LogicalKeyboardKey.digit2) {
      _choose(1);
      return true;
    }
    if (key == LogicalKeyboardKey.digit3) {
      _choose(2);
      return true;
    }
    // 返回键交给 Navigator 默认处理（不消费，避免 pop 两次）。
    return false;
  }

  void _move(int delta) {
    final int next = (_focused + delta).clamp(
      0,
      DecodePreference.values.length - 1,
    );
    if (next == _focused) return;
    setState(() => _focused = next);
    _nodes[next].requestFocus();
  }

  void _choose(int index) {
    final DecodePreference value = DecodePreference.values[index];
    debugPrint('[TV-DECODE] settings choose ${value.name}');
    Navigator.of(context).pop(value);
  }

  Widget _info(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Tv.text2),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: Tv.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _option(int index) {
    final DecodePreference value = DecodePreference.values[index];
    final bool focused = _focused == index;
    final bool selected = widget.preference == value;
    return Focus(
      focusNode: _nodes[index],
      onFocusChange: (bool hasFocus) {
        if (hasFocus && _focused != index && mounted) {
          setState(() => _focused = index);
        }
      },
      child: GestureDetector(
        onTap: () => _choose(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: focused ? Tv.surface2 : Tv.surface,
            borderRadius: BorderRadius.circular(Tv.radius),
            border: Border.all(
              color: focused ? Tv.accent : Tv.line,
              width: focused ? 2 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 17,
                color: selected ? Tv.ok : Tv.text3,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      value.label,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Tv.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value.hint,
                      style: const TextStyle(fontSize: 10.5, color: Tv.text2),
                    ),
                  ],
                ),
              ),
              if (focused)
                const Icon(Icons.play_arrow, size: 16, color: Tv.accent),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DecodeDecision auto = DecodePolicy.decide(
      widget.profile,
      DecodePreference.auto,
    );
    final TvDeviceProfile p = widget.profile;
    final String decoders = p.hevcDecoders.isEmpty
        ? '未读到（不影响平台指纹判定）'
        : p.hevcDecoders.join('\n');
    final MediaQueryData mq = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Tv.gutter,
            vertical: Tv.pagePaddingV,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '解码设置',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  color: Tv.text,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '按 SoC 分化解码：已知有色彩缺陷的平台自动走软解，其余走硬解',
                style: TextStyle(fontSize: 11, color: Tv.text2),
              ),
              const SizedBox(height: Tv.sectionGap),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      flex: 6,
                      child: Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: Tv.surface,
                          borderRadius: BorderRadius.circular(Tv.radiusLg),
                          border: Border.all(color: Tv.line),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                '本机识别',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                  color: Tv.accent,
                                ),
                              ),
                              const SizedBox(height: 9),
                              _info('设备', p.summary),
                              _info('品牌', '${p.brand} / ${p.manufacturer}'),
                              _info('平台指纹', p.fingerprint),
                              _info('SoC 归类', auto.family.label),
                              _info('HEVC 解码器', decoders),
                              _info(
                                '显示',
                                '逻辑 ${mq.size.width.round()}x${mq.size.height.round()}'
                                    ' · 物理 ${(mq.size.width * mq.devicePixelRatio).round()}x'
                                    '${(mq.size.height * mq.devicePixelRatio).round()}'
                                    ' · dpr ${mq.devicePixelRatio}'
                                    ' · insets ${mq.padding.left.round()}/'
                                    '${mq.padding.top.round()}/'
                                    '${mq.padding.right.round()}/'
                                    '${mq.padding.bottom.round()}',
                              ),
                              const SizedBox(height: 5),
                              Container(height: 1, color: Tv.line),
                              const SizedBox(height: 9),
                              const Text(
                                '自动档判定',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w800,
                                  color: Tv.accent,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                '${auto.modeLabel} @${auto.quality}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  color: Tv.ok,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                auto.reason,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: Tv.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            '解码档位',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: Tv.accent,
                            ),
                          ),
                          const SizedBox(height: 9),
                          for (
                            int i = 0;
                            i < DecodePreference.values.length;
                            i++
                          )
                            _option(i),
                          const SizedBox(height: 10),
                          Expanded(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(13),
                              decoration: BoxDecoration(
                                color: Tv.surface,
                                borderRadius: BorderRadius.circular(
                                  Tv.radiusLg,
                                ),
                                border: Border.all(color: Tv.line),
                              ),
                              child: const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '遥控器速查 / 显示提示',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: Tv.accent,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    '主页  方向键选剧 · OK 进入 · ↑↓ 切换区域\n'
                                    '详情  选集网格 · OK 播放\n'
                                    '播放  左右 ±10 秒 · 上下 切集 · OK 控制条\n'
                                    '      0 键 切换居中 / 裁切满屏 · 菜单键 解码设置\n'
                                    '      返回键 收起 / 返回\n'
                                    '控制条只留：播放 · 选集 · 解码 · 倍速 · 清晰 · 退出',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      height: 1.7,
                                      color: Tv.text2,
                                    ),
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    '若电视四周仍有黑边：请把电视「图像 → 画面比例」'
                                    '设为 16:9 / 全屏 / 点对点。App 侧已占满 '
                                    '1920x1080 物理输出。',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      height: 1.6,
                                      color: Tv.text3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '↑↓ 移动 · OK / 数字 1–3 选档并立即生效 · 返回键取消',
                            style: TextStyle(fontSize: 10.5, color: Tv.text3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
