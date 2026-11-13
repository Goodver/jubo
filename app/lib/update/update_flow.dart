import 'dart:io';

import 'package:flutter/material.dart';

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

  /// 启动时静默检查。发现新版本且还没问过这次会话，才弹一次。
  /// 不阻塞主流程：检查在后台跑，有结果再在 [context] 上弹窗。
  static Future<void> checkOnStartup(BuildContext context, {String? assetKey}) async {
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
    await _downloadAndInstall(context, url, name);
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String url,
    String name,
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
            builder: (_, value, __) => Column(
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
                  builder: (_, text, __) => Text(
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
      if (cancel.isCancelled) return;
      if (context.mounted) await _info(context, '下载失败', e.toString());
      return;
    } finally {
      notifier.dispose();
      statusText.dispose();
    }

    // 关掉进度框。
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await downloading;

    if (apkPath.isEmpty || !context.mounted) return;

    // 拉起系统安装器。失败多半是没给「安装未知应用」权限，引导去开。
    try {
      await ApkInstaller.install(apkPath);
    } catch (_) {
      try {
        await ApkInstaller.openPermissionSettings();
        if (context.mounted) {
          await _info(context, '需要安装权限',
              '请在「安装未知应用」里允许本应用安装，然后回到这里重新点「立即升级」。');
        }
      } catch (_) {
        if (context.mounted) await _info(context, '安装失败', '无法拉起安装器，请手动安装已下载的 APK。');
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

  /// 清理历史下载残留（临时目录，可安全删）。
  static Future<void> cleanup() async {
    try {
      final base = Directory.systemTemp;
      await for (final d in base.list()) {
        if (d is Directory && d.path.contains('hgonly_update')) {
          await d.delete(recursive: true).catchError((_) => d);
        }
      }
    } catch (_) {}
  }
}
