import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../appmeta.dart';
import '../theme.dart';
import 'apk_installer.dart';
import 'update_service.dart';

/// 自动升级的用户流程封装：检查 → 弹窗 → 带进度下载 → 拉起安装。
///
/// 手机和 TV 共用同一套逻辑，只让 [userInterfaceTarget] 决定弹窗文案宽度等细节；
/// 弹窗本身是普通 Material Dialog，TV 上靠方向键在「立即升级 / 稍后」之间移动焦点即可。
class UpdateFlow {
  UpdateFlow._();

  /// 记录「这台设备的系统没有安装权限入口」，避免每次开机都弹一个装不成的升级框。
  static const _kNoInstallUi = 'update.no_install_ui';

  static Future<bool> _knownNoInstallUi() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kNoInstallUi) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _markNoInstallUi() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kNoInstallUi, true);
    } catch (_) {}
  }

  /// 启动时静默检查。发现新版本且还没问过这次会话，才弹一次。
  /// 不阻塞主流程：检查在后台跑，有结果再在 [context] 上弹窗。
  static Future<void> checkOnStartup(BuildContext context, {String? assetKey}) async {
    // 已知本机装不了（电视 ROM 阉割了安装权限入口）且当前确实没有权限时，
    // 不再自动打扰——弹了也只能点「稍后」。手动「检查更新」不受影响。
    if (!await ApkInstaller.hasInstallPermission() && await _knownNoInstallUi()) return;

    final res = await UpdateService.instance.checkForUpdate(assetKey: assetKey);
    if (!res.hasUpdate) return;
    if (!context.mounted) return;
    await showUpdateDialog(context, res, assetKey: assetKey);
  }

  /// 手动「检查更新」入口：总是给反馈（已最新 / 有新版 / 失败原因）。
  static Future<void> checkManually(BuildContext context, {String? assetKey}) async {
    final res = await UpdateService.instance.checkForUpdate(assetKey: assetKey);
    if (!context.mounted) return;

    if (res.status == UpdateStatus.error) {
      await _info(context, '检查更新失败', res.error ?? '未知错误');
      return;
    }
    if (!res.hasUpdate) {
      await _info(context, '已是最新版本', '当前 ${AppMeta.versionLabel}，没有可用更新。');
      return;
    }
    await showUpdateDialog(context, res, assetKey: assetKey);
  }

  /// 有新版本时的确认弹窗 + 下载进度 + 安装。
  static Future<void> showUpdateDialog(
    BuildContext context,
    UpdateCheckResult res, {
    String? assetKey,
  }) async {
    final url = res.apkUrl;
    final name = res.apkName;
    if (url == null || name == null) {
      await _info(context, '无法升级', '该版本未提供可下载的安装包。');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Hg.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Hg.radius)),
        title: Text('发现新版本 ${res.remoteVersion ?? res.tagName ?? ''}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前 ${AppMeta.versionLabel}'
              '${res.remoteBuild != null ? ' → 新版本 (${res.remoteBuild})' : ''}',
              style: const TextStyle(color: Hg.text2, fontSize: 13),
            ),
            if ((res.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(
                    res.notes!.length > 600 ? '${res.notes!.substring(0, 600)}…' : res.notes!,
                    style: const TextStyle(color: Hg.text3, fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Hg.brand),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('立即升级'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await _downloadAndInstall(context, url, name, res.apkSize);
  }

  /// 升级主流程，顺序是刻意安排的：
  ///   1. **先查安装权限**（几乎零开销）——没权限就别下几十 MB；
  ///   2. 再下载（目录固定，可按大小复用已下好的包）；
  ///   3. 最后拉起安装器，失败按原因分流，不再把所有错误都当成「要授权」。
  static Future<void> _downloadAndInstall(
    BuildContext context,
    String url,
    String name,
    int? expectedSize,
  ) async {
    // —— 1. 权限预检 ——
    if (!await ApkInstaller.hasInstallPermission()) {
      if (!context.mounted) return;
      final granted = await _askAndWaitPermission(context);
      if (!granted || !context.mounted) return;
    }
    if (!context.mounted) return;

    // —— 2. 下载 ——
    final apkPath = await _download(context, url, name, expectedSize);
    if (apkPath == null || !context.mounted) return;

    // —— 3. 安装 ——
    await _installWithFallback(context, apkPath);
  }

  /// 引导用户去开「安装未知应用」，并等他从设置页回来。
  ///
  /// 用轮询而不是生命周期监听：部分电视切换到系统设置页不会触发
  /// paused → resumed，靠 `AppLifecycleState` 会一直等不到。
  static Future<bool> _askAndWaitPermission(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Hg.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Hg.radius)),
        title: const Text('需要安装权限'),
        content: const Text(
          '系统要求先允许本应用「安装未知应用」，否则无法自动安装新版本。\n\n'
          '点「去授权」打开开关后直接返回即可，应用会自动继续，不用重新下载。',
          style: TextStyle(color: Hg.text2, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不升级'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Hg.brand),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return false;

    bool opened;
    try {
      opened = await ApkInstaller.openPermissionSettings();
    } catch (e) {
      if (context.mounted) {
        await _info(context, '无法打开设置',
            '请手动到「系统设置 → 应用 → 特殊权限 → 安装未知应用」里允许本应用，然后重试。');
      }
      return false;
    }

    // 系统没有这个设置入口：ROM 限制，装不了就说清楚，别让用户反复点。
    if (!opened) {
      await _markNoInstallUi();
      if (context.mounted) {
        await _info(
          context,
          '本机不支持应用内安装',
          '这台设备的系统没有开放「安装未知应用」的设置入口，无法在应用内自动安装新版本。\n\n'
          '可以改用电脑执行 adb 安装，或把安装包复制到 U 盘、用电视自带的文件管理器安装。',
        );
      }
      return false;
    }

    // 最多等 5 分钟。用户在设置页授权后返回，这里就能感知到。
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (await ApkInstaller.hasInstallPermission()) return true;
    }
    if (context.mounted) {
      await _info(context, '尚未授权', '没有检测到「安装未知应用」权限，本次升级已取消。授权后可以再点一次「检查更新」。');
    }
    return false;
  }

  /// 带进度框下载 APK。返回本地路径；失败或取消返回 null。
  static Future<String?> _download(
    BuildContext context,
    String url,
    String name,
    int? expectedSize,
  ) async {
    final cancel = CancelToken();

    // 进度对话框。下载在后台跑，更新状态用 ValueNotifier 驱动。
    final notifier = ValueNotifier<double>(0);
    final statusText = ValueNotifier<String>('准备下载…');

    final downloading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: Hg.bg2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Hg.radius)),
          title: const Text('正在下载更新'),
          content: ValueListenableBuilder<double>(
            valueListenable: notifier,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: value <= 0 ? null : value,
                  backgroundColor: Hg.bg4,
                  color: Hg.brand,
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: statusText,
                  builder: (_, text, _) => Text(
                    text,
                    style: const TextStyle(color: Hg.text3, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancel.cancel();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    String apkPath = '';
    try {
      apkPath = await UpdateService.instance.downloadApk(
        url,
        name,
        expectedSize: expectedSize,
        cancel: cancel,
        onProgress: (p, received, total) {
          notifier.value = p;
          final mb = (received / (1024 * 1024)).toStringAsFixed(1);
          final totalMb = total > 0 ? ' / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB' : '';
          statusText.value = '$mb MB$totalMb（${(p * 100).toStringAsFixed(0)}%）';
        },
      );
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (cancel.isCancelled) return null;
      if (context.mounted) await _info(context, '下载失败', e.toString());
      return null;
    } finally {
      notifier.dispose();
      statusText.dispose();
    }

    // 关掉进度框。
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await downloading;

    if (apkPath.isEmpty) return null;
    return apkPath;
  }

  /// 拉起安装器；失败时按原因分流。
  ///
  /// 关键点：**只有 `needsPermission` 才去引导授权**。之前是 `catch (_)` 一把抓，
  /// 把 FileProvider 路径不匹配之类的真 bug 也当成「没授权」，于是反复把用户
  /// 送到设置页，授权回来重下重试，永远装不上。
  static Future<void> _installWithFallback(BuildContext context, String apkPath) async {
    try {
      await ApkInstaller.install(apkPath);
      return; // 系统安装器已接管，后续 UI 不必再做
    } on InstallException catch (e) {
      if (e.needsPermission) {
        // 少见：下载期间权限被撤销/被系统回收。再引导一次，回来直接用现成文件重试。
        if (!context.mounted) return;
        final granted = await _askAndWaitPermission(context);
        if (!granted || !context.mounted) return;
        try {
          await ApkInstaller.install(apkPath);
        } on InstallException catch (retryError) {
          if (context.mounted) {
            await _info(context, '安装失败', '${retryError.message}\n\n安装包已下载：$apkPath');
          }
        }
        return;
      }
      if (context.mounted) {
        await _info(context, '安装失败', '${e.message}\n\n安装包已下载：$apkPath');
      }
    }
  }

  static Future<void> _info(BuildContext context, String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Hg.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Hg.radius)),
        title: Text(title),
        content: Text(body, style: const TextStyle(color: Hg.text2, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 清理下载目录里的旧安装包（只删过期文件，不会误删待安装的包）。
  static Future<void> cleanup() async {
    await UpdateService.instance.cleanupStale();
  }
}
