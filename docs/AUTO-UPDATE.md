# 自动升级 · 发版说明

App 内置「检查更新」：启动后静默检查一次（有新版才弹窗），设置页 / TV 顶栏也有手动入口。

## 版本源

GitHub 私有仓库 `Goodver/jubo` 的 **Releases**。客户端拉 `releases/latest`，
按 **versionCode**（pubspec 版本号 `x.y.z+N` 里的 `N`）对比本地，远端更大才提示升级。

## 发版步骤

1. 改 `app/pubspec.yaml` 的版本，例如 `version: 0.6.11+18`（`+18` 就是 versionCode，**必须递增**）。
2. 打两个 flavor 的包：
   ```bash
   cd app
   flutter build apk --release --flavor phone --target-platform android-arm64
   flutter build apk --release --flavor tv --target-platform android-arm -t lib/tv/main_tv.dart
   ```
   产物在 `build/app/outputs/flutter-apk/`：`app-phone-release.apk` / `app-tv-release.apk`。
3. 在 GitHub 建 Release：**tag 用 `v<versionCode>`**（如 `v18`），标题随意。
4. 上传两个 APK 资产，**文件名分别含 `phone` / `tv`**（客户端按端挑资产；缺省取第一个 .apk）。
5. Release 正文写更新说明，会显示在升级弹窗里。

## 关键约定

- **升级判据是 versionCode（`+N`）**，不是语义版本字符串。忘改 `+N` 客户端不会提示升级。
- `lib/update/update_config.dart` 的 `token` **必须留空**：仓库已是 public，匿名即可拉清单和下载。
  只有在仓库改回 private 时才需要填一个只读 Contents 的 PAT。烤进已 revoke 的 token 会导致
  清单请求 401 → 检查更新静默失败不弹窗（v1037 踩过）。
- Android 8+ 首次安装会引导用户开「安装未知应用」授权，已通过 `REQUEST_INSTALL_PACKAGES` + FileProvider 处理。

## 升级流程的顺序（build 1042 起重排）

```
确认升级 → ① 查 canRequestPackageInstalls() →（无权限）引导授权 + 轮询等待
        → ② 下载（固定目录，按资产 size 复用已下好的包）
        → ③ ACTION_VIEW 拉起安装器
```

三条铁律，破坏任何一条都会退化成「反复把人送去授权页、永远装不上」：

1. **权限必须在下载之前查**。原来是先下 40MB+ 再发现装不了，白费流量。
2. **下载目录必须被 FileProvider 声明覆盖**。见下节。
3. **安装失败要按 code 分流**：只有 `no_install_permission` 才引导授权；
   `install_failed`（FileProvider 路径、APK 损坏、ActivityNotFound）要如实报错。
   以前是 `catch (_)` 一把抓，把所有失败都当权限问题 → 无脑跳设置页，
   真 bug 被永久掩盖。判断入口是 `InstallException.needsPermission`。

## ⚠️ FileProvider 覆盖不到下载目录 = 装不上（而且像「没权限」）

`FileProvider.getUriForFile()` 只认 `res/xml/file_paths.xml` 里声明过的根，**不匹配就抛
`IllegalArgumentException("Failed to find configured root that contains ...")`**。
表现是「点升级→跳权限页→授权→回来→再跳权限页」，装多少个来回都装不上。

历史坑：APK 曾下在 `Directory.systemTemp`（Android 上是 cacheDir），而 `file_paths.xml`
只声明了 `files-path` / `external-files-path`，**唯独漏了 `cache-path`** → 必然抛异常。

现在：下载目录改为 `getApplicationSupportDirectory()`（= `getFilesDir()`）下的 `updates/`，
被 `<files-path path=".">` 覆盖；`file_paths.xml` 同时保留 `cache-path` 兜底。
**改下载目录时，务必同步改 `file_paths.xml`。**

## ⚠️ TV 打包必带 `-t`（血泪坑）

**TV flavor 的 Gradle 只管包名 / ABI / Manifest，不绑定 Dart 入口。** `flutter build` 默认入口是
`lib/main.dart`（手机版竖版沉浸流 feed，靠触摸上滑）。**打 TV 包漏了 `-t lib/tv/main_tv.dart`
就会打出一个「装在电视上、跑的却是手机 UI」的包**——竖版 feed 不响应遥控，表现为「遥控全失灵」，
而且截图一看是竖排点赞/追剧/分享 + 「上滑换一剧」，不是横屏海报网格。遥控硬件和事件链路都是好的，
纯粹是入口错了。**TV 包必须带 `-t lib/tv/main_tv.dart`**，打完核对首页是横屏网格再发。

## ⚠️ TV 启动必须 `AppMeta.load()`

升级检查按 versionCode 比对，本地版本从 `AppMeta.build` 读。`AppMeta` 默认兜底是 `0.6.4 (11)`，
**TV 的 `TvBootPage._boot()` 若漏了 `await AppMeta.load()`，本地版本恒为 11**，
远端任何 ≥12 的 Release 都会假阳性弹「发现新版本」，已装最新版也一直弹。手机版 BootPage 已调，
TV 版此前漏了，已补（`main_tv.dart`）。
