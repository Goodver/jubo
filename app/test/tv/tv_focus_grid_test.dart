// TV 遥控器焦点索引纯函数回归测试（2026-11-07）。
// 焦点算错在电视上表现为「方向键乱跳 / 按不动」，实机排查成本高，先单测兜住。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hgonly/tv/tv_ui.dart';

int? next(
  LogicalKeyboardKey key,
  int current, {
  int count = 20,
  Axis axis = Axis.vertical,
  int columns = 6,
}) => tvNextIndex(
  key: key,
  current: current,
  count: count,
  axis: axis,
  columns: columns,
);

void main() {
  group('tvNextIndex 纵向海报网格', () {
    test('左右在同一行内 ±1', () {
      expect(next(LogicalKeyboardKey.arrowRight, 7), 8);
      expect(next(LogicalKeyboardKey.arrowLeft, 7), 6);
    });

    test('行首按左、行尾按右不跨行，交给页面切区', () {
      expect(next(LogicalKeyboardKey.arrowLeft, 6), isNull);
      expect(next(LogicalKeyboardKey.arrowRight, 11), isNull);
      expect(next(LogicalKeyboardKey.arrowLeft, 0), isNull);
    });

    test('上下按 columns 换行', () {
      expect(next(LogicalKeyboardKey.arrowDown, 2), 8);
      expect(next(LogicalKeyboardKey.arrowUp, 8), 2);
    });

    test('第一行按上、最后一行按下 → null', () {
      expect(next(LogicalKeyboardKey.arrowUp, 0), isNull);
      expect(next(LogicalKeyboardKey.arrowUp, 5), isNull);
      expect(next(LogicalKeyboardKey.arrowDown, 18), isNull);
      expect(next(LogicalKeyboardKey.arrowDown, 19), isNull);
    });

    test('末行不满时仍能落在该行', () {
      expect(next(LogicalKeyboardKey.arrowDown, 3, count: 10), 9);
    });
  });

  group('tvNextIndex 横向分类/控制条', () {
    test('左右 ±1，边界返回 null', () {
      expect(
        next(LogicalKeyboardKey.arrowRight, 1, axis: Axis.horizontal, count: 4),
        2,
      );
      expect(
        next(LogicalKeyboardKey.arrowLeft, 1, axis: Axis.horizontal, count: 4),
        0,
      );
      expect(
        next(LogicalKeyboardKey.arrowLeft, 0, axis: Axis.horizontal, count: 4),
        isNull,
      );
      expect(
        next(LogicalKeyboardKey.arrowRight, 3, axis: Axis.horizontal, count: 4),
        isNull,
      );
    });

    test('上下键不属于横向行，交回页面切区', () {
      expect(
        next(LogicalKeyboardKey.arrowDown, 1, axis: Axis.horizontal),
        isNull,
      );
      expect(next(LogicalKeyboardKey.arrowUp, 1, axis: Axis.horizontal), isNull);
    });
  });

  test('OK / 菜单键不参与焦点移动', () {
    expect(next(LogicalKeyboardKey.select, 3), isNull);
    expect(next(LogicalKeyboardKey.contextMenu, 3), isNull);
    expect(next(LogicalKeyboardKey.enter, 3), isNull);
  });

  test('空列表任何键都不移动', () {
    expect(next(LogicalKeyboardKey.arrowRight, 0, count: 0), isNull);
  });
}
