import 'package:package_info_plus/package_info_plus.dart';

/// 应用自身的元信息（名称、版本、作者）。版本从安装包里读，读不到就用常量兜底。
class AppMeta {
  const AppMeta._();

  static const appName = '剧播';
  static const slug = 'hgonly';
  static const author = 'Goodver';
  static const packageName = 'com.hgonly.hongguo';

  static String version = '0.6.4';
  static String build = '11';

  static String get versionLabel =>
      build.isEmpty ? version : '$version ($build)';

  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) version = info.version;
      build = info.buildNumber;
    } catch (_) {}
  }
}
