# 版本记录

时间均为 2026-11-01 夜间至 11-02 凌晨，单机开发、实机迭代（Redmi Note 12 Turbo / Android 15 / arm64）。

## 0.6.19 (1042) — 修复升级「只会跳授权页、授权完又重下」

- **修：FileProvider 覆盖不到下载目录，安装器永远拉不起来**（真 bug，根因）
  - APK 下在 `Directory.systemTemp`（Android 上是 cacheDir），而 `file_paths.xml` 只声明了
    `files-path` / `external-files-path`，**漏了 `cache-path`** → `getUriForFile()` 抛
    IllegalArgumentException → 装不上。
  - 下载目录改到 `getApplicationSupportDirectory()/updates/`（= `getFilesDir()`，已被
    `<files-path>` 覆盖）；`file_paths.xml` 同时补 `cache-path` 兜底。
- **修：安装失败一律被当成「没权限」**，于是反复跳设置页、真错误被永久掩盖
  - 原来 `catch (_)` → 直接 `openPermissionSettings()`。现在按原生 error code 分流：
    `no_install_permission` 才引导授权，`install_failed` 如实报错（`InstallException.needsPermission`）。
  - 原生侧把 FileProvider 路径失配单列成明确文案，不再和权限混为一谈。
- **改：先查权限再下载**。原来先下 40MB+ 才检查，没授权等于白下。现在确认升级后
  先 `canRequestPackageInstalls()`，没权限先引导，拒绝授权就直接不下载。
- **改：授权返回后自动继续，不重新下载**
  - 下载目录由 `createTemp` 随机名改为固定目录，按远端资产 `size` 判定是否可复用；
  - 授权后轮询感知（600ms 一次，最多 5 分钟；不用生命周期监听，部分电视切设置页不触发
    paused/resumed），检测到已授权就直接用现成文件拉安装器。
- **改：清理策略**。原来 `cleanup()` 会删掉所有含 `hgonly_update` 的目录（含刚下好待装的包），
  且实际没被调用过。现在只在启动时删超过 3 天的旧包，手机/TV 启动各调一次。

## 0.6.18 (1041) — 取流加固 + 换设备诊断可见化

已发 GitHub Release `v1041`（双资产：`hgonly-phone-1041.apk` / `hgonly-tv-1041.apk`）。

- 新增 `key_seed` 密文 URL 解密（`ohg/internal/protocol/spade_url.go`）。信封 `a8 ?? 01 00`，
  key/iv 由 `sha512(seed)` 与 64 字节常量段二次 sha512 派生，AES-128-CBC 解 `main_url` /
  `backup_url` / dynamic 音频轨。服务端不下发 seed 时路径完全不变；全部解不开显式报
  `ErrSpadeURL`，绝不把密文交给播放器。
- 新增节奏链 + 熔断（`ohg/guard.go`）：相邻取流最小间隔 **500ms**、全局串行；连续 3 次
  空结果熔断 30s 并逐轮翻倍至 5min；半开只放一个探针，`defer release` 防探测位泄漏。
  实测定值：1s 间隔会让连切三集停下那集 1649ms，500ms 时降到 484ms。
- 换设备过程可见化（`ohg/trace.go`）：`traceLog` 实现 `sdk.Logger`（环形留最近 8 行），
  `countStore` 在 `Reset` 成功时计数（不解析日志文案）。`rotations` 一路透传到
  `PlaybackPlan.rotations`，成功路径也能看到（0 = 首台设备直接成功）；失败时错误串带
  「换设备 N 次 + SDK 告警行」。此前这条路完全是黑盒。
- 手机端补日志：`resolve ok ... rotations=`、`open FAILED:`、`warm FAILED:`（预加载失败
  不再被 `catch (_)` 静默吞掉）。
- 修正 `ohg` 包头注释：实测同档案连续取流不会被判空（第 1 集 1270ms、第 2 集 308ms），
  「一台匿名设备只给一次播放模型」不成立。

## 0.6.4 (11) — 修复点击全失效 + 换页闪帧

- 修：除了上下滑屏，轻触暂停、双击点赞、顶栏、底部控件全部点不动
  - 根因是 `_page()` 里把「播放正常 → 返回 SizedBox」写成了提前 `return`，
    手势层 `GestureDetector` 跟着一起消失了。改成手势层常驻、只让封面透明度变化
- 修：滑到下一屏时闪 1～2 帧
  - 三路 `Video` 改为常驻（不再随 `warmed` 增删），`ImageFiltered` / `Opacity` 也不再按
    `mix` 分支创建，滚动全程子树结构不变，纹理不会重新挂载
  - 页面封面层改用 `AnimatedOpacity` 150ms 淡出，避免「封面 → 透明」硬切
- 实测：逐帧录屏（screenrecord 拆帧）确认过渡连续，无黑帧白帧

## 0.6.3 (10) — 滑屏虚化过渡，去掉上一屏残影

- 新增 `_scrollPos`（滚动位置 notifier），画面层与每页封面各自订阅，滚动不重建整棵树
- 上滑/翻页时当前画面按 `mix` 虚化（`ImageFiltered`，sigma 上限 26）+ 放大 6% + 淡出，
  露出同剧模糊封面；停稳后反向收回，形成柔和的虚化过渡
- 从下方进入的下一页按距离从模糊渐变到清晰（sigma 上限 16）
- 修：滑走的那一屏仍能看见清晰的旧画面（画面层固定、页是透明的），
  以及换剧瞬间 90ms 交叉淡化留下的上一部剧残影

## 0.6.2 (9) — 视频预加载，消除切集/换剧卡顿

- 新增三路播放器预加载：一路在播，两路分别预热「本剧下一集」和「下一部剧第一集」
- 切换只切画面纹理，不再 `resolve` + `release` + `open`，过渡段无等待
- 两路纹理常驻、90ms 交叉淡入，避免新画面接上前的黑场
- 修复：预加载重入被挡住导致滑动换剧始终走慢路（补 `_preloadPending`）
- 切后台释放预加载，回前台重新备；播放出错时也让出预加载连接

## 0.6.1 (8) — 修复播放全挂

- 修：播放页只显示 `context canceled`，重试、换一部都无效，必须杀进程
  - 根因是引擎按 `sequence` 判重，Flutter 引擎重建后 Dart 计数器归零
  - 改为单调时间戳序号 + 撞号自动重试一次
- 错误文案中文化，不再把英文异常直接抛给用户

## 0.6.0 (7) — 改名「剧播」

- 全局品牌词「红果」→「剧播」（应用名、清单 label、占位字、代码注释）
- 「果」字方块 → 蓝底白「剧」；桌面图标重做为蓝色渐变自适应图标
  （`app/tool/make_icon.py` 生成五套 mipmap + anydpi-v26）
- 观看记录上限设为 200 部（超出淘汰最久未看）
- 删冗余文案：我的页「· 点开即播」、观看记录「· 点开续播」、关于页「· 上滑换剧」

## 0.5.1 (6) — 观看记录页

- 新增观看记录列表：封面、剧名、第几集/共几集/看到几分几秒/多久前
- 点开续播、长按删单条、一键清空
- 移除排查用的临时日志

## 0.5.0 (5) — 收藏与设置

- 点赞、追剧独立分页，长按剧照删除；分享改为只复制剧名
- 我的页、设置页、许可页、关于页
- 清空缓存只清播放记录与封面缓存，不动点赞/追剧

## 0.4.x — 交互补齐

- 轻触暂停/播放、双击点赞、上下滑换剧、横屏播放、切后台暂停
- 进片库时暂停，返回按进度续播（全局 RouteObserver + `Media(start:)`）
- 分类排行榜（热播总榜 + 真人/漫剧/AI 分榜）
- 片库搜索（历史、大家都在看、分页）

## 0.3.x — 随机播放流

- 从「一部剧从第 1 集播到大结局」改为**一页一部剧**：上滑换剧
- 本集播完接同剧下一集，剧终才换剧
- 随机池混合真人剧、漫剧、AI 剧，避开最近看过的 40 部
- 漫剧/AI 剧改用网页版分类页补目录（App 接口这两类返回空）

## 0.2.0 — 片库与选集

- 三列片库、分类筛选、下拉加载
- 选集浮层、播放控制层（4 秒自动隐藏）

## 0.1.0 — 首个可播版本

- Flutter + media_kit + Go FFI 跑通：启动 → 拉目录 → 直接播第 1 集
- HEVC 硬解 + CENC 解密（`decryption_key` 经 mpv 生效）
