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
- token 在 `lib/update/update_config.dart`（fine-grained，只有 jubo 的 Contents 读权限）。
  泄露的最坏后果是别人能下安装包，动不了源码；担心时回 GitHub revoke 换新，改那一个常量即可。
- Android 8+ 首次安装会引导用户开「安装未知应用」授权，已通过 `REQUEST_INSTALL_PACKAGES` + FileProvider 处理。

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
