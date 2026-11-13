import 'package:flutter/widgets.dart';

/// 全局路由观察者：播放页靠它感知“被别的页面盖住 / 又露出来”，
/// 从而在进片库、搜索、榜单时自动停播，回到播放页再起播（避免多路声音叠在一起）。
final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();
