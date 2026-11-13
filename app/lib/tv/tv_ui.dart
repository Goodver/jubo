// 剧播 TV · 10-foot UI 基础件（P2，2026-11-07）
//
// 设计系统直接复用手机主分支的 theme.dart（Hg 色板 / 圆角 / 字号节奏），
// 只把「布局与交互」按电视分叉：手机是竖向 PageView + 上滑手势，TV 必须
// 横屏网格 + 遥控器 DPAD。这里提供一套「按索引走焦点」的组件：不依赖
// Flutter 引擎的方向焦点遍历，上下左右直接算下一个索引，OK 触发。
//
// 页面栈里可能同时有多个 TvFocusGrid（分类行 / 海报网格 / 播放控制条）：
//  - active=false 的区域直接让路；
//  - 只有当前路由（ModalRoute.isCurrent）才消费按键，避免上层页面抢键；
//  - 边界方向键交给 onUnhandledKey，由页面把焦点切到另一个区域。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../theme.dart';

typedef TvItemBuilder = Widget Function(
  BuildContext context,
  int index,
  bool focused,
);
typedef TvUnhandledKey = bool Function(LogicalKeyboardKey key, int index);

/// TV 的视觉变量全部指向手机端同一套 [Hg] 设计系统，避免出现「两个 App」
/// 的割裂感；只有焦点态用品牌红加亮，保证 10-foot 距离下依然醒目。
class Tv {
  const Tv._();

  static const Color bg = Hg.bg;
  static const Color surface = Hg.bg1;
  static const Color surface2 = Hg.bg3;
  static const Color line = Hg.line2;
  static const Color accent = Hg.brand2;
  static const Color ok = Hg.ok;
  static const Color warn = Hg.warn;
  static const Color danger = Color(0xFFFF6B6B);
  static const Color text = Hg.text;
  static const Color text2 = Hg.text2;
  static const Color text3 = Hg.text3;
  static const Color logo = Hg.logo;
  static const Color logo2 = Hg.logo2;
  static const Color panel = Hg.panel;

  static const double radius = Hg.radius;
  static const double radiusLg = Hg.radiusLg;

  /// 电视可能有 2–5% 过扫描，但不能像 10-foot 教科书那样留 48dp：
  /// 实测 1920x1080 / density 240（逻辑 1280x720）上，52dp 边距会让
  /// 画面看起来像「窗口模式」。这里只保留一道最小安全线。
  static const double gutter = 26;
  static const double pagePaddingV = 14;

  static const int gridColumns = 7;
  static const double gridStep = 288; // 行步进（含行间距）
  static const double gridGap = 14;
  static const double chipStep = 138; // 横向 chip 步进（含间距）
  static const double chipHeight = 50;

  static const double sectionGap = 10;
  static const double tightGap = 6;
}

/// 全屏背景层（2026-11-08）。
///
/// 之前所有 TV 页面都是 `Scaffold(backgroundColor) > SafeArea > Padding > 内容`，
/// 背景完全靠 Scaffold 兜底：只要系统 insets 非零，或电视把画面按非 100%
/// 缩放，四边就会露出窗口底色，看起来就是「背景没铺满、四边没触边」。
/// 现在背景由 `TvApp.builder` 用 Positioned.fill 铺在整个 Navigator 底下，
/// 页面 Scaffold 保持透明；内容的 SafeArea / gutter 只作用于上层，
/// 两层互不干扰。
///
/// 渐变刻意做得可辨认（左上品牌红、右下品牌蓝的一层微光），这样现场一眼
/// 就能看出背景是否真的顶到了屏幕四边，而不是和纯黑融为一体。
class TvBackdrop extends StatelessWidget {
  const TvBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: Tv.bg),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.95, -1.15),
              radius: 1.55,
              colors: <Color>[Color(0x2AFF3B5C), Color(0x00FF3B5C)],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(1.05, 1.2),
              radius: 1.5,
              colors: <Color>[Color(0x212B5CF0), Color(0x002B5CF0)],
            ),
          ),
        ),
      ],
    );
  }
}

/// 校准页 / 独立页的 body：内容套安全区与 gutter，最外层叠校准标记。
/// 背景不在这里画 —— 全局 [TvBackdrop] 由 `TvApp.builder` 铺在整个
/// Navigator 底下，页面本身必须保持透明才能看到它。
///
/// [calibration] 打开后会在最外层叠一圈贴边红线，用于现场区分
/// 「App 没画满」与「电视画面比例/缩放把整个画面缩小了」。
Widget tvPageBody({
  required Widget content,
  EdgeInsets padding = const EdgeInsets.symmetric(
    horizontal: Tv.gutter,
    vertical: Tv.pagePaddingV,
  ),
  bool calibration = false,
}) {
  return SizedBox.expand(
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: SafeArea(
            child: Padding(padding: padding, child: content),
          ),
        ),
        if (calibration)
          const Positioned.fill(
            child: IgnorePointer(child: _TvCalibrationOverlay()),
          ),
      ],
    ),
  );
}

class _TvCalibrationOverlay extends StatelessWidget {
  const _TvCalibrationOverlay();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _TvEdgePainter());
}

/// 贴边红线要画在 1.5px 处，保证 3px 描边完整落在 framebuffer 内，
/// 这样 adb screencap 能直接验证「App 是否画到了第 0 行/列」。
class _TvEdgePainter extends CustomPainter {
  const _TvEdgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint edge = Paint()
      ..color = Tv.accent
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final double w = size.width;
    final double h = size.height;
    canvas.drawRect(Rect.fromLTWH(1.5, 1.5, w - 3, h - 3), edge);

    const double len = 72;
    for (final List<double> c in <List<double>>[
      <double>[2, 2, 1, 1],
      <double>[-2, 2, -1, 1],
      <double>[2, -2, 1, -1],
      <double>[-2, -2, -1, -1],
    ]) {
      final double x = c[0] < 0 ? w + c[0] : c[0];
      final double y = c[1] < 0 ? h + c[1] : c[1];
      canvas.drawLine(Offset(x, y), Offset(x + c[2] * len, y), edge);
      canvas.drawLine(Offset(x, y), Offset(x, y + c[3] * len), edge);
    }

    final Paint grid = Paint()
      ..color = const Color(0x55FF6F85)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(w / 2, 0), Offset(w / 2, h), grid);
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), grid);
    for (double x = w / 8; x < w; x += w / 8) {
      canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
    }
    for (double y = h / 8; y < h; y += h / 8) {
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _TvEdgePainter oldDelegate) => false;
}

class TvKeys {
  const TvKeys._();

  static bool activate(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space;

  static bool back(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.backspace;

  static bool menu(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.contextMenu;

  static bool down(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowDown;

  static bool up(LogicalKeyboardKey key) => key == LogicalKeyboardKey.arrowUp;

  static bool left(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft;

  static bool right(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowRight;
}

/// 当前路由才处理按键。页面 push 动画期间旧路由会短暂 isCurrent=false，
/// 正好避免上下两层同时响应同一次遥控按键。
bool tvIsCurrent(BuildContext context) =>
    ModalRoute.of(context)?.isCurrent ?? true;

/// 纯函数：算出方向键的下一个焦点索引。返回 null = 到边界或不是方向键，
/// 交给页面的 onUnhandledKey 去切区域 / 加载更多。抽出来是为了能单测，
/// 遥控器焦点算错在电视上很难排查。
int? tvNextIndex({
  required LogicalKeyboardKey key,
  required int current,
  required int count,
  required Axis axis,
  required int columns,
}) {
  if (count <= 0) return null;
  final int cols = math.max(1, columns);
  if (axis == Axis.horizontal) {
    if (TvKeys.left(key)) return current > 0 ? current - 1 : null;
    if (TvKeys.right(key)) return current + 1 < count ? current + 1 : null;
    return null;
  }
  if (TvKeys.up(key)) return current < cols ? null : current - cols;
  if (TvKeys.down(key)) {
    final int next = current + cols;
    return next < count ? next : null;
  }
  if (TvKeys.left(key)) return current % cols == 0 ? null : current - 1;
  if (TvKeys.right(key)) {
    return current % cols == cols - 1 ? null : current + 1;
  }
  return null;
}

/// 统一的焦点外框：轻微放大 + 品牌红描边 + 底色。
/// 2026-11-07 反馈：原 1.05 放大 + 3px 蓝框在 1920x1080 上过于笨重，
/// 收到 1.03 / 2px，并改用手机端同款品牌红。
Widget tvFrame({
  required bool focused,
  required Widget child,
  double radius = Hg.radius,
  Color? base,
  EdgeInsets padding = const EdgeInsets.all(6),
  double scale = 1.03,
}) {
  return AnimatedScale(
    scale: focused ? scale : 1.0,
    duration: const Duration(milliseconds: 130),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      decoration: BoxDecoration(
        color: focused ? Tv.surface2 : (base ?? Tv.surface),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused ? Tv.accent : Tv.line,
          width: focused ? 2 : 1,
        ),
      ),
      padding: padding,
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

/// 横向 chip / 播放控制条按钮。
class TvChip extends StatelessWidget {
  const TvChip({
    super.key,
    required this.label,
    required this.focused,
    this.icon,
    this.subtitle = '',
    this.selected = false,
    this.color,
  });

  final String label;
  final bool focused;
  final IconData? icon;
  final String subtitle;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? (selected ? Tv.ok : Tv.text);
    return tvFrame(
      focused: focused,
      scale: 1.03,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 17, color: tint),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: tint,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Tv.text3),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 竖版海报卡：封面 + 标题 + 集数/角标。cacheWidth 限住内存（电视只有 2 GiB）。
class TvPosterCard extends StatelessWidget {
  const TvPosterCard({
    super.key,
    required this.drama,
    required this.focused,
    this.badge = '',
  });

  final Drama drama;
  final bool focused;
  final String badge;

  @override
  Widget build(BuildContext context) {
    return tvFrame(
      focused: focused,
      padding: const EdgeInsets.all(5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (drama.cover.isNotEmpty)
                    Image.network(
                      drama.cover,
                      fit: BoxFit.cover,
                      cacheWidth: 240,
                      errorBuilder: (_, _, _) => const _CoverFallback(),
                    )
                  else
                    const _CoverFallback(),
                  if (badge.isNotEmpty)
                    Positioned(
                      left: 5,
                      top: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC0E0E12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Tv.ok,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            drama.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Tv.text,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            <String>[
              if (drama.category.isNotEmpty) drama.category,
              if (drama.episodeCount > 0) '共${drama.episodeCount}集',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Tv.text3),
          ),
        ],
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Hg.bg3,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_outlined, size: 30, color: Tv.text3),
    );
  }
}

/// 通用页头：标题 + 副标题 + 右侧状态。
class TvTopBar extends StatelessWidget {
  const TvTopBar({
    super.key,
    required this.title,
    this.subtitle = '',
    this.trailing = const <Widget>[],
  });

  final String title;
  final String subtitle;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: <Color>[Tv.logo2, Tv.logo]),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Text(
            '剧',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
                color: Tv.text,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(fontSize: 10.5, color: Tv.text2),
              ),
          ],
        ),
        const Spacer(),
        ...trailing,
      ],
    );
  }
}

class TvStateView extends StatelessWidget {
  const TvStateView({
    super.key,
    required this.message,
    this.busy = false,
    this.onRetry,
  });

  final String message;
  final bool busy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (busy)
            const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            const Icon(Icons.info_outline, size: 32, color: Tv.text3),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Tv.text2),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: const Text('重试（OK）', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 按索引走焦点的网格 / 横向行。
///
/// axis=vertical：columns 列，左右 ±1（不跨行），上下 ±columns；
/// axis=horizontal：单行，左右 ±1；上下交给 onUnhandledKey。
/// 第一行按上 / 末行按下 / 行首按左 / 行尾按右都交给 onUnhandledKey，
/// 页面可据此在「分类行 ↔ 海报网格」「播放按钮 ↔ 分集网格」之间切区。
class TvFocusGrid extends StatefulWidget {
  const TvFocusGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onSelect,
    this.axis = Axis.vertical,
    this.columns = Tv.gridColumns,
    this.itemExtent = Tv.gridStep,
    this.gap = Tv.gridGap,
    this.crossExtent = Tv.chipHeight,
    this.padding = EdgeInsets.zero,
    this.active = true,
    this.initialIndex = 0,
    this.onUnhandledKey,
    this.onNearEnd,
    this.onFocusChange,
  });

  final int itemCount;
  final TvItemBuilder itemBuilder;
  final void Function(int index) onSelect;
  final Axis axis;
  final int columns;
  final double itemExtent;
  final double gap;
  final double crossExtent;
  final EdgeInsets padding;
  final bool active;
  final int initialIndex;
  final TvUnhandledKey? onUnhandledKey;
  final VoidCallback? onNearEnd;

  /// 焦点索引变化时通知页面。页面要按「菜单键删除当前项」时用它记住位置，
  /// 不必自己维护一套焦点状态。
  final ValueChanged<int>? onFocusChange;

  @override
  State<TvFocusGrid> createState() => _TvFocusGridState();
}

class _TvFocusGridState extends State<TvFocusGrid> {
  final ScrollController _scroll = ScrollController();
  late int _focused = _clamp(widget.initialIndex);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisible(jump: true);
      widget.onFocusChange?.call(_focused);
    });
  }

  @override
  void didUpdateWidget(covariant TvFocusGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int next = _clamp(_focused);
    if (next != _focused) {
      _focused = next;
      widget.onFocusChange?.call(next);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scroll.dispose();
    super.dispose();
  }

  int _clamp(int index) =>
      index.clamp(0, math.max(0, widget.itemCount - 1)).toInt();

  bool _unhandled(LogicalKeyboardKey key) =>
      widget.onUnhandledKey?.call(key, _focused) ?? false;

  bool _onKey(KeyEvent event) {
    if (!widget.active ||
        !tvIsCurrent(context) ||
        event is! KeyDownEvent ||
        widget.itemCount == 0) {
      return false;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (TvKeys.activate(key)) {
      widget.onSelect(_focused);
      return true;
    }

    final int? next = tvNextIndex(
      key: key,
      current: _focused,
      count: widget.itemCount,
      axis: widget.axis,
      columns: widget.columns,
    );
    if (next == null) return _unhandled(key);
    _move(next);
    return true;
  }

  void _move(int index) {
    if (index == _focused) return;
    setState(() => _focused = index);
    widget.onFocusChange?.call(index);
    _ensureVisible();
    if (widget.onNearEnd != null &&
        index >= math.max(0, widget.itemCount - widget.columns * 2)) {
      widget.onNearEnd!();
    }
  }

  void _ensureVisible({bool jump = false}) {
    if (!_scroll.hasClients) return;
    final int line = widget.axis == Axis.vertical
        ? _focused ~/ math.max(1, widget.columns)
        : _focused;
    final double max = math.max(0.0, _scroll.position.maxScrollExtent);
    final double target = (line * widget.itemExtent).clamp(0.0, max).toDouble();
    if ((_scroll.offset - target).abs() < 1) return;
    if (jump) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _item(BuildContext context, int index) {
    return GestureDetector(
      onTap: () => widget.onSelect(index),
      // 非活动区域不画焦点描边，否则两个区域会同时出现「蓝框」，
      // 遥控器用户分不清当前到底在哪一层。
      child: widget.itemBuilder(
        context,
        index,
        widget.active && _focused == index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();
    if (widget.axis == Axis.horizontal) {
      return SizedBox(
        height: widget.crossExtent,
        child: ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          itemExtent: widget.itemExtent,
          itemCount: widget.itemCount,
          itemBuilder: (BuildContext context, int index) => Padding(
            padding: EdgeInsets.only(right: widget.gap),
            child: _item(context, index),
          ),
        ),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: widget.padding,
      itemCount: widget.itemCount,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: math.max(1, widget.columns),
        mainAxisExtent: math.max(60.0, widget.itemExtent - widget.gap),
        crossAxisSpacing: widget.gap,
        mainAxisSpacing: widget.gap,
      ),
      itemBuilder: _item,
    );
  }
}
