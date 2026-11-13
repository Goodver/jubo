import 'dart:io';

import 'package:flutter/services.dart';

/// 拉起系统安装器 / 打开「未知来源」授权页的原生通道。
class ApkInstaller {
  ApkInstaller._();
  static const _channel = MethodChannel('hgonly/update');

  /// 用 FileProvider 把 APK 交给系统安装器。成功返回 true；失败抛 PlatformException。
  static Future<bool> install(String apkPath) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': apkPath}) ?? false;
    } on PlatformException {
      // 最常见：用户还没给「安装未知应用」授权。交给 UI 层引导去开。
      rethrow;
    }
  }

  /// 打开系统「安装未知应用」授权页（Android 8+）。
  static Future<void> openPermissionSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openInstallPermissionSettings');
  }
}
