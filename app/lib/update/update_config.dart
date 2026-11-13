/// 自动升级的远端配置。
///
/// 版本源 = GitHub 仓库 `Goodver/jubo` 的 **Releases**（已设为 **public**）。
/// 每次发版：在 GitHub 上建一个 Release，tag 用 `v<versionCode>`（例如 `v18`），
/// 并上传对应 ABI 的 APK 资产（文件名含 `phone` / `tv` 便于自动匹配）。
/// 客户端拉取「最新 Release」的清单，按 `versionCode` 对比本地，决定是否提示升级。
///
/// 关于认证：仓库是 public，**无需 token 即可匿名拉取清单和下载 APK**。
/// `token` 留空字符串即可；若哪天仓库改回 private，再填一个只读 Contents 权限的
/// fine-grained PAT 即可恢复认证访问。
class UpdateConfig {
  const UpdateConfig._();

  /// fine-grained PAT（只读 Contents）。仓库为 public 时**留空即可匿名访问**；
  /// 仅当仓库改回 private 时才需要填。public 仓库下无需也不应硬编码 token。
  static const token = '';

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

  /// APK 资产下载的加速代理前缀（国内环境必需）。
  ///
  /// GitHub 直连在国内/TV 网络下可能只有 30~80 KB/s，下 40MB+ 的 APK 要等近 10 分钟。
  /// 用公共加速代理（在原 URL 前加代理域名）可提速到 MB/s 级。
  ///
  /// 下载顺序：
  /// 1. 优先尝试 `assetProxyPrefixes` 里的每个代理 + 原始 URL
  /// 2. 全部失败则回退到 GitHub 直连
  ///
  /// **仓库为 public 时，几乎所有 GitHub 加速代理都可用**（无需 Authorization，
  /// 代理支持好、速度快）；private 仓库只有少数代理支持（需透传 token）。
  ///
  /// 常见可用代理（按可靠性排序，2026-11 实测）：
  /// - `https://gh-proxy.com/`（稳定，public 仓库速度 2~5 MB/s）
  /// - `https://ghfast.top/`（备用）
  /// - `https://github.moeyy.xyz/`（备用）
  ///
  /// 全部代理失效时客户端会自动回退直连（慢但能下）。代理可用性会随时间变化，
  /// 失效时增删这个列表即可。
  static const assetProxyPrefixes = <String>[
    'https://gh-proxy.com/',
    'https://ghfast.top/',
    'https://github.moeyy.xyz/',
  ];
}
