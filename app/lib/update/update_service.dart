import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../appmeta.dart';
import 'update_config.dart';

/// 一次「检查更新」的结果。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.remoteVersion,
    this.remoteBuild,
    this.notes,
    this.apkUrl,
    this.apkName,
    this.tagName,
    this.error,
  });

  final UpdateStatus status;

  /// 远端的语义版本（如 0.6.11），仅展示用；真正判断升级看 build。
  final String? remoteVersion;

  /// 远端的 versionCode（pubspec 的 `+N`）。**升级判据**：远端 > 本地才提示。
  final int? remoteBuild;

  final String? notes;
  final String? apkUrl;
  final String? apkName;
  final String? tagName;
  final String? error;

  bool get hasUpdate => status == UpdateStatus.available;
}

enum UpdateStatus { available, upToDate, error }

/// 自动升级服务：GitHub Releases 私有仓库 + token。
///
/// 版本对比看 **versionCode（buildNumber）**，不看语义版本字符串——
/// Android 只认 versionCode 判断能不能覆盖安装。pubspec 写 `0.6.10+17`
/// 时，本地 buildNumber = 17；发版 Release 的 tag / 资产名里带目标 build。
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _timeout = Duration(seconds: 20);

  HttpClient? _client;
  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = _timeout
    ..autoUncompress = true;

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${UpdateConfig.token}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'hgonly-updater',
      };

  /// 检查是否有新版本。[assetKey] 传 phone / tv，用来在多资产 Release 里
  /// 挑中本端该装的 APK；传 null 则取第一个 .apk 资产。
  Future<UpdateCheckResult> checkForUpdate({String? assetKey}) async {
    try {
      final req = await _http.getUrl(Uri.parse(UpdateConfig.latestReleaseUrl));
      _authHeaders.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(_timeout);

      if (res.statusCode == 404) {
        // 仓库还没有任何 Release：不算错误，视为「已是最新」。
        return const UpdateCheckResult(status: UpdateStatus.upToDate);
      }
      if (res.statusCode != 200) {
        return UpdateCheckResult(
          status: UpdateStatus.error,
          error: '拉取版本信息失败（HTTP ${res.statusCode}）',
        );
      }

      final body = jsonDecode(await res.transform(utf8.decoder).join());
      if (body is! Map<String, dynamic>) {
        return const UpdateCheckResult(status: UpdateStatus.error, error: '版本信息格式异常');
      }

      final tag = (body['tag_name'] as String? ?? '').trim();
      final releaseName = (body['name'] as String? ?? '').trim();
      final notes = (body['body'] as String? ?? '').trim();
      final assets = (body['assets'] as List? ?? const []);

      // 远端 build：优先 tag 里的数字（v18 → 18），否则从资产名找 _NN / -NN。
      final remoteBuild = _parseBuild(tag) ?? _parseBuild(releaseName);
      final remoteVersion = _parseSemver(tag) ?? _parseSemver(releaseName);

      // 挑 APK 资产：优先匹配 assetKey，其次第一个 .apk。
      Map<String, dynamic>? apk;
      for (final a in assets) {
        if (a is! Map<String, dynamic>) continue;
        final name = (a['name'] as String? ?? '').toLowerCase();
        if (!name.endsWith('.apk')) continue;
        if (assetKey != null && name.contains(assetKey.toLowerCase())) {
          apk = a;
          break;
        }
      }
      apk ??= assets.cast<Map<String, dynamic>?>().firstWhere(
            (a) => a != null && (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'),
            orElse: () => null,
          );

      if (apk == null) {
        return UpdateCheckResult(
          status: UpdateStatus.error,
          tagName: tag,
          remoteVersion: remoteVersion,
          remoteBuild: remoteBuild,
          error: '该版本未提供 APK 安装包',
        );
      }

      // 没解析到远端 build 就没法可靠对比，退化为「有新版」提示但标注未知。
      final localBuild = int.tryParse(AppMeta.build) ?? 0;
      final newer = remoteBuild == null || remoteBuild > localBuild;

      return UpdateCheckResult(
        status: newer ? UpdateStatus.available : UpdateStatus.upToDate,
        remoteVersion: remoteVersion,
        remoteBuild: remoteBuild,
        notes: notes.isEmpty ? null : notes,
        apkUrl: (apk['url'] as String?), // asset 的 url 走 API，需带 token 下载
        apkName: apk['name'] as String?,
        tagName: tag,
      );
    } on TimeoutException {
      return const UpdateCheckResult(status: UpdateStatus.error, error: '检查更新超时，请稍后再试');
    } catch (e) {
      return UpdateCheckResult(status: UpdateStatus.error, error: '检查更新失败：$e');
    }
  }

  /// 把 APK 流式下载到临时目录，[onProgress] 回调 0.0~1.0。
  /// 返回下载好的本地文件路径；失败抛异常。
  ///
  /// 下载加速：优先尝试 `UpdateConfig.assetProxyPrefixes` 里的每个代理，
  /// 全部失败则回退 GitHub 直连。代理失败的常见原因：
  /// - private 仓库部分代理丢弃 Authorization 头 → 401
  /// - 代理限速 / 偶发 5xx
  /// - 代理域名被 DNS 污染或解析失败
  Future<String> downloadApk(
    String assetApiUrl,
    String fileName, {
    void Function(double progress, int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final dir = await Directory.systemTemp.createTemp('hgonly_update');
    final savePath = '${dir.path}${Platform.pathSeparator}$fileName';

    // 构造候选 URL 列表：每个代理前缀 + 原始 URL（回退）
    final candidates = <String>[
      for (final prefix in UpdateConfig.assetProxyPrefixes) '$prefix$assetApiUrl',
      assetApiUrl, // 最终回退：GitHub 直连
    ];

    Object? lastError;
    for (final url in candidates) {
      try {
        final path = await _downloadTo(
          url,
          savePath,
          dir,
          onProgress: onProgress,
          cancel: cancel,
        );
        return path;
      } catch (e) {
        lastError = e;
        if (cancel?.isCancelled ?? false) rethrow;
        // 下载失败（代理挂/超时/HTTP 错误）：清空文件，试下一个候选
        final f = File(savePath);
        if (await f.exists()) await f.delete().catchError((_) => f);
      }
    }

    // 所有候选都失败：清理临时目录并抛最后一个错误
    await _deleteQuietly(dir);
    throw Exception('下载失败（所有加速通道均不可用）：$lastError');
  }

  /// 实际执行单个 URL 的流式下载，写入 [savePath]。
  Future<String> _downloadTo(
    String url,
    String savePath,
    Directory dir, {
    void Function(double progress, int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final file = File(savePath);
    final req = await _http.getUrl(Uri.parse(url));
    _authHeaders.forEach((k, v) => req.headers.set(k, v));
    // 私有仓库的 asset 必须接受二进制流；代理一般会透传这个头
    req.headers.set('Accept', 'application/octet-stream');
    final res = await req.close().timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}（$url）');
    }
    final total = res.contentLength;
    var received = 0;
    final sink = file.openWrite();

    try {
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) {
          await sink.close();
          throw Exception('已取消');
        }
        received += chunk.length;
        sink.add(chunk); // 背压由 IOSink 内部缓冲处理，进度照常统计
        if (total > 0) onProgress?.call(received / total, received, total);
      }
      await sink.flush();
      await sink.close();
      onProgress?.call(1.0, received, total > 0 ? total : received);
      return savePath;
    } catch (_) {
      await sink.close().catchError((_) {});
      rethrow;
    }
  }

  /// 释放连接池（一般无需手动调）。
  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  /// 静默删除临时目录（清理失败忽略）。
  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 从 `v18` / `build-18` / `xxx_18.apk` 等里抠出尾部的 versionCode 数字。
  int? _parseBuild(String s) {
    final m = RegExp(r'(\d+)\s*$').firstMatch(s.trim());
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 从 `v0.6.11` / `0.6.11+18` 里抠出语义版本，仅展示用。
  String? _parseSemver(String s) {
    final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(s);
    return m?.group(1);
  }
}

/// 取消下载用的简单令牌。
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
