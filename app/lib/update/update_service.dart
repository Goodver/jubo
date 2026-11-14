import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../appmeta.dart';
import 'package:path_provider/path_provider.dart';

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
    this.apkSize,
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

  /// 资产字节数（GitHub 清单里的 `size`）。用于判断已下载的包能否直接复用，
  /// 免掉「授权回来又重下一遍」。
  final int? apkSize;

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

  /// 请求头：token 非空时带 Authorization（私有仓库）；public 仓库 token 留空即可匿名访问。
  Map<String, String> get _authHeaders {
    final h = <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'hgonly-updater',
    };
    final token = UpdateConfig.token.trim();
    if (token.isNotEmpty) h['Authorization'] = 'Bearer $token';
    return h;
  }

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
        apkSize: (apk['size'] as num?)?.toInt(),
        tagName: tag,
      );
    } on TimeoutException {
      return const UpdateCheckResult(status: UpdateStatus.error, error: '检查更新超时，请稍后再试');
    } catch (e) {
      return UpdateCheckResult(status: UpdateStatus.error, error: '检查更新失败：$e');
    }
  }

  /// APK 下载目录名（位于应用私有 files 目录下）。
  ///
  /// 落点必须落在 Android 侧 `res/xml/file_paths.xml` 声明过的根里，否则
  /// `FileProvider.getUriForFile()` 会抛 IllegalArgumentException，症状是
  /// 「怎么也拉不起安装器」。这里用 `getApplicationSupportDirectory()`
  /// （= `getFilesDir()`，已被 `<files-path path=".">` 覆盖）而不是
  /// `Directory.systemTemp`，是因为后者依赖引擎设置的 TMPDIR，位置不保证。
  static const updateDirName = 'updates';

  /// 下载目录（必要时创建）。
  static Future<Directory> _updateDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$updateDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 把 APK 流式下载到固定的私有目录，[onProgress] 回调 0.0~1.0。
  /// 返回下载好的本地文件路径；失败抛异常。
  ///
  /// 目录固定（不再用 `createTemp` 生成随机名）是为了让 [expectedSize] 能命中复用：
  /// 用户「下载完 → 发现没授权 → 去设置页 → 回来」时直接拿现成文件，不重下几十 MB。
  ///
  /// 下载加速：优先尝试 `UpdateConfig.assetProxyPrefixes` 里的每个代理，
  /// 全部失败则回退 GitHub 直连。代理失败的常见原因：
  /// - private 仓库部分代理丢弃 Authorization 头 → 401
  /// - 代理限速 / 偶发 5xx
  /// - 代理域名被 DNS 污染或解析失败
  Future<String> downloadApk(
    String assetApiUrl,
    String fileName, {
    int? expectedSize,
    void Function(double progress, int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final dir = await _updateDir();
    final savePath = '${dir.path}${Platform.pathSeparator}$fileName';

    // 复用已完整下载的包（大小与远端资产一致才算数，避免拿到截断文件）。
    final existing = File(savePath);
    if (expectedSize != null &&
        expectedSize > 0 &&
        await existing.exists() &&
        await existing.length() == expectedSize) {
      if (cancel?.isCancelled ?? false) throw Exception('已取消');
      onProgress?.call(1.0, expectedSize, expectedSize);
      return savePath;
    }
    // 大小不符（截断/旧版本残留）：先删掉再下。
    if (await existing.exists()) await existing.delete().catchError((_) => existing);

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

  /// 清理下载目录里的旧安装包。
  ///
  /// 只删「超过 [maxAge] 没动过」的文件，**绝不整目录清空**：否则用户刚下好、
  /// 正等授权后安装的包会被下一次启动顺手删掉，又变成重新下载。
  /// 默认留 3 天，足够覆盖跨天的升级流程，也不至于让 40MB+ 的包长期占缓存。
  Future<void> cleanupStale({Duration maxAge = const Duration(days: 3)}) async {
    try {
      final dir = await _updateDir();
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) await entity.delete();
        } catch (_) {
          // 单个文件删不掉不影响其它，忽略
        }
      }
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
