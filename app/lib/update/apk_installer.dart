import 'dart:io';

import 'package:flutter/services.dart';

/// 拉起系统安装器失败的原因。
///
/// 这层分类是必须的：原生侧「没授权」和「FileProvider 路径不匹配」都表现为
/// 拉不起安装器，但前者要去设置页、后者是代码 bug。混在一起就会变成
/// 「永远在要权限，却怎么都装不上」。
class InstallException implements Exception {
  const InstallException(this.code, this.message);

  /// 原生 error code：`no_install_permission` / `install_failed` / `bad_args`。
  final String code;
  final String message;

  /// 只有这一种情况值得引导用户去开「安装未知应用」。
  bool get needsPermission => code == 'no_install_permission';

  @override
  String toString() => message;
}

/// 拉起系统安装器 / 打开「未知来源」授权页的原生通道。
class ApkInstaller {
  ApkInstaller._();
  static const _channel = MethodChannel('hgonly/update');

  /// 是否已获「安装未知应用」权限（Android 8 以下恒为 true）。
  ///
  /// 用途是在**下载之前**先问一次，避免下完几十 MB 才发现装不了。
  /// 查询本身失败时返回 true —— 宁可放行让安装器报真实错误，也不要卡住升级。
  static Future<bool> hasInstallPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasInstallPermission') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 用 FileProvider 把 APK 交给系统安装器。成功返回 true；失败抛 [InstallException]。
  static Future<bool> install(String apkPath) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': apkPath}) ?? false;
    } on PlatformException catch (e) {
      throw InstallException(e.code, e.message ?? '拉起安装器失败');
    } on MissingPluginException {
      throw const InstallException('install_failed', '原生安装通道不可用');
    }
  }

  /// 打开系统「安装未知应用」授权页。
  ///
  /// 返回 **false** 表示这台设备的系统压根没有这个设置入口——国内电视/定制 ROM
  /// 常见（实测创维 Android 12、海尔都没有，连应用详情页里也没特殊权限）。
  /// 这不是权限没给，也不是代码问题，而是 ROM 限制，必须如实告诉用户，
  /// 否则只会反复弹「无法打开设置」让人以为是 bug。
  static Future<bool> openPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'no_settings_ui') return false;
      rethrow;
    } on MissingPluginException {
      return false;
    }
  }
}
