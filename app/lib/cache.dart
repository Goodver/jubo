import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用数据目录 / 缓存瘦身。
/// 只清「封面 + 目录缓存」，不碰点赞、追剧（那两份在 SharedPreferences 里）。
class AppCache {
  const AppCache._();

  static Directory? _root;

  static Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    _root = dir;
    return dir;
  }

  /// 引擎的封面缓存目录
  static Future<Directory> coverDir() async =>
      Directory('${(await root()).path}/covers-v1');

  /// 可以安全删掉的缓存：封面目录 + 引擎的目录缓存 JSON
  static Future<List<FileSystemEntity>> _targets() async {
    final base = await root();
    final out = <FileSystemEntity>[];
    final covers = Directory('${base.path}/covers-v1');
    if (await covers.exists()) out.add(covers);
    for (final name in const ['catalogs.json', 'sources.json']) {
      final file = File('${base.path}/$name');
      if (await file.exists()) out.add(file);
    }
    return out;
  }

  static Future<int> bytes() async {
    var total = 0;
    for (final entity in await _targets()) {
      try {
        if (entity is File) {
          total += await entity.length();
        } else if (entity is Directory) {
          await for (final row in entity.list(
            recursive: true,
            followLinks: false,
          )) {
            if (row is File) total += await row.length();
          }
        }
      } catch (_) {}
    }
    return total;
  }

  /// 删掉缓存文件，返回释放的字节数。目录本身保留（引擎跑起来还会往里写）
  static Future<int> clear() async {
    final before = await bytes();
    for (final entity in await _targets()) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
    return before;
  }

  static String sizeLabel(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
