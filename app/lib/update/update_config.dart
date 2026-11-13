/// 自动升级的远端配置。
///
/// 版本源 = GitHub 私有仓库 `Goodver/jubo` 的 **Releases**。
/// 每次发版：在 GitHub 上建一个 Release，tag 用 `v<versionCode>`（例如 `v18`），
/// 并上传对应 ABI 的 APK 资产（文件名含 `phone` / `tv` 便于自动匹配）。
/// 客户端拉取「最新 Release」的清单，按 `versionCode` 对比本地，决定是否提示升级。
///
/// 关于 token：仓库是 private，拉 Release 清单和 APK 资产都要带 Authorization。
/// 这个 fine-grained token **只给了 jubo 这一个仓库的 Contents 读权限**，
/// 泄露的最坏后果是别人能下载你的安装包，动不了源码、动不了其它仓库。
/// 若哪天担心泄露，回 GitHub 把它 revoke 换新的即可（改这一个常量）。
class UpdateConfig {
  const UpdateConfig._();

  /// 私有仓库的 fine-grained PAT（只读 jubo 的 Contents）。
  static const token = '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';

  /// 归属仓库（owner/repo）。
  static const repo = 'Goodver/jubo';

  /// API 基址。
  static const apiBase = 'https://api.github.com';

  /// 拉「最新 Release」（不含 prerelease / draft）。
  static String get latestReleaseUrl => '$apiBase/repos/$repo/releases/latest';

  /// 预期的 APK 资产名里的 ABI/端标识，用于在多个资产里挑中本机该装的那个。
  /// phone flavor → 找文件名含 phone 的；tv flavor → 找含 tv 的。
  static const phoneAssetKey = 'phone';
  static const tvAssetKey = 'tv';
}
