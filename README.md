# 剧播（hgonly）

单站源短剧信息流 App：打开即播，上滑换剧，一屏一部剧。基于 Flutter + Go FFI 引擎，
**不改动「短聚」工程的任何文件**，只通过 `go.mod replace` 只读引用它已有的站源引擎。

- 平台：Android（arm64-v8a，minSdk 24）
- 技术栈：Flutter 3.47 + media_kit（libmpv）+ Go（C ABI）
- 应用名：剧播　包名：`com.hgonly.hongguo`（历史原因沿用，未改为 jubo）
- 当前版本：**0.6.1 (8)**，成品见 `releases/hgonly-0.6.1.apk`

## 功能

**播放**
- 点开随机挑一部剧，从第 1 集开始，不按上次进度续（续播只发生在从记录/片库进入时）
- 随机池混合真人剧、漫剧、AI 剧三类，避开最近看过的 40 部
- 一屏一部剧：**上滑换下一部剧**，不是下一集
- 不滑屏时，本集播完自动接同剧下一集，播到大结局才换剧
- 轻触暂停/播放，双击点赞，横屏按钮切 16:9 播放
- 切后台自动暂停，从片库/我的返回时按进度续播
- 模糊封面铺底（封面比例不合时）+ CENC 加密 HEVC 由 mpv 解密播放
- **三路播放器预加载**：一路在播，另两路分别把「下一集」和「下一部剧的第一集」
  提前解析并缓冲好（暂停态），切集/滑屏只切画面纹理，不重新打开流，
  消除过渡卡顿。见下方「预加载机制」

**内容**
- 片库：三列网格，全部/真人剧/漫剧/AI 剧分类，下拉刷新、触底加载
- 排行榜：热播总榜 + 真人/漫剧/AI 剧分榜，名次徽章、热度、评分、集数、标签
- 搜索：历史记录、大家都在看、三列结果、触底分页

**收藏与记录**
- 点赞、追剧各自独立分页，长按剧照删除，点卡片直接续播
- 观看记录：一部剧一条，显示封面/剧名/第几集/共几集/看到几分几秒/多久前，
  点开续播、长按删除、可一键清空；上限 200 部（超出淘汰最久未看）
- 分享：只复制剧名到剪贴板

**设置**
- 许可（第三方组件清单 + 完整开源许可）、清空缓存、关于
- 清空缓存 = 播放记录 + 封面缓存，**不动点赞和追剧**

## 目录

```
hgonly/
├── app/                      # Flutter 应用
│   ├── lib/
│   │   ├── main.dart         # 入口、启动页、全局 RouteObserver
│   │   ├── feed_page.dart    # 信息流播放页（核心，约 1900 行）
│   │   ├── library_page.dart # 片库
│   │   ├── rank_page.dart    # 排行榜
│   │   ├── search_page.dart  # 搜索
│   │   ├── saved_page.dart   # 我的点赞 / 我的追剧
│   │   ├── history_page.dart # 观看记录
│   │   ├── mine_page.dart    # 我的
│   │   ├── settings_page.dart# 设置 / 许可 / 关于
│   │   ├── engine.dart       # FFI 封装（isolate 内调用，返回 {ok,data}）
│   │   ├── models.dart       # Drama / Episode / PlaybackPlan / FeedEntry
│   │   ├── store.dart        # SharedPreferences 持久化（进度/点赞/追剧）
│   │   ├── webcat.dart       # 网页版数据源（分类/榜单/搜索）
│   │   ├── cache.dart        # 缓存统计与清理
│   │   ├── theme.dart        # 配色与主题
│   │   └── appmeta.dart      # 名称/版本/作者
│   ├── tool/make_icon.py     # 生成蓝色「剧」字启动图标（Pillow）
│   ├── test/                 # 模型解析单元测试
│   └── android/app/src/main/jniLibs/arm64-v8a/libhgnative.so
├── native/                   # Go 桥接层（只导出 HgRequest / HgFree）
│   ├── main.go
│   ├── go.mod                # replace 指向短聚 native 模块
│   └── build_android.sh      # 交叉编译 arm64 原生库
├── probe/                    # 引擎诊断工具（Windows 下直接跑）
│   ├── main.go               # 目录/分类/详情巡检
│   └── cmd/{play,resolve,idcheck}/main.go
├── docs/                     # 设计稿截图 + 版本记录
└── releases/                 # 成品 APK
```

## 引擎协议

`HgRequest(json) -> json`，响应统一 `{ok, data, error}`。

| action | 入参 | 关键返回 |
|---|---|---|
| `initialize` | `directory` | 版本信息 |
| `catalog` | `source`, `page`, `category` | `items[]`、`hasMore`、`page` |
| `categories` | `source` | `items[]` |
| `detail` | `drama` | `chapters[]` |
| `resolve` | `drama`, `chapter`, `index`, `sequence`, `quality` | `url`、`headers`、`decryptionKey`、`qualities`、`session` |
| `release` | `session` | — |
| `cover` | `drama` | 本地封面文件 |
| `danmaku` | `danmakuId`, `startMs` | 弹幕列表（未接 UI） |

`resolve` 返回的 `url` 是引擎自己起的本地回环地址，媒体是 **CENC 加密的 HEVC**，
必须用 mpv 系播放器并传 `decryption_key`：

```dart
final platform = player.platform;
if (platform is NativePlayer) {
  await platform.setProperty('demuxer-lavf-o',
    'seg_max_retry=3,strict=experimental,allowed_extensions=ALL,'
    'protocol_whitelist=[http,https,tcp,tls,crypto,data,file],'
    'decryption_key=$key');
}
```

## 预加载机制

早期是单播放器：切集时要先 `resolve` 拿地址、`release` 旧会话、再 `open` 新流，
三件事串起来就是那一下过渡卡顿（解析几百毫秒 + 重新建连解缓冲 1～3 秒）。

现在 `feed_page.dart` 开三路 `Player` + `VideoController`：

| 路 | 用途 |
|---|---|
| 当前路 | 正在播 |
| 备用路 A | 本剧**下一集**，`open(play: false)` 暂停态，缓冲已经在填 |
| 备用路 B | **下一部剧的第一集**，应付上滑换剧 |

- 切换时 `_activate()` 只做三件事：暂停旧路、`_stageIdx` 换指针、新路 `play()`。
  不 `open`、不 `resolve`，所以没有等待。画面用 `AnimatedOpacity` 90ms 交叉淡入，
  两路纹理一直挂在树上，不会出现「新画面还没接上先黑一下」。
- `_playCurrent()` 开头先查 `_readyStage()`：备用路已有该 `剧id#集号#清晰度`
  就直接走快路，否则退回原来的慢路（首播、跳集、换清晰度走这条）。
- 切完立刻 `_preloadAhead()` 补下一轮，`_freeStage()` 挑一路（优先空着的）
  把旧内容替换掉，旧 `session` 随即 `release` 归还引擎。
- 预加载被重入时用 `_preloadPending` 记一笔，本轮结束后再补一轮
  （踩过坑：补新剧和首次预加载撞上，被重入保护挡住，导致滑动换剧一直走慢路）。
- 切后台 `_dropPreload()` 全部释放；回前台 `_preloadAhead(force: true)` 重备一份
  （闲置久了地址会过期）。播放出错时也会 `_dropPreload()`，避免和正片抢连接。
- mpv 侧把 `cache-secs` 调到 20、`demuxer-readahead-secs` 调到 24，让暂停态也能把缓冲填起来。

实机验证（`adb logcat | grep feed`）：

```
[feed] slow start ep=1                          # 首播，慢路
[feed] warm hongguo:7701...#2#0 -> stage1       # 预热下一集
[feed] warm hongguo:7699...#1#0 -> stage2       # 预热下一部剧
[feed] fast switch ep=2 pos=0ms                 # 播完接下一集，快路
[feed] fast switch ep=1 pos=0ms                 # 上滑换剧，快路
```

## 翻页过渡（虚化 + 无残影）

画面层是**固定**在 PageView 下面的（三路纹理轮流显示），而 PageView 每页只有封面，
所以早期上滑时会出现「旧画面一动不动地留在屏上」的残影感——手已经把这一页推走了，
底下的视频还在原地播。

现在用 `_scrollPos`（`ValueNotifier<double>`，以“页”为单位的绝对页码）驱动两处：

- `_videoLayer()` 订阅它，算 `mix = |page - round(page)| * 2`（0 = 停稳，1 = 滑到两页中间）。
  `mix > 0` 时给画面套 `ImageFiltered` 模糊（上限 sigma 26）、`Transform.scale` 放大 6%、
  `Opacity` 降到 0.06，露出底下同剧的模糊封面。旧画面在滑走的过程中就失焦淡出了。
- `_page()` 也订阅它，每页按自己的 `far = |page - i|` 给海报加模糊（上限 sigma 16）和缩放，
  从底下滑进来的那页一开始是糊的，到位才变清晰。

只订阅这两个局部，滚动时不会重建整棵树。`_scrollPos` 在 `dispose` 时释放。

**两条不能碰的线**（都踩过）：

1. `_page()` 必须始终返回带 `GestureDetector` 的结构。播放正常时这一页是透明的，
   屏幕上的轻触暂停、双击点赞全靠它接着——写提前 `return SizedBox` 会让所有点击失效，
   只剩 PageView 自己的滑动还能用。
2. 滑动全程子树结构不能变。三路 `Video` 常驻（用 `opacity` 表达可见性）、
   `ImageFiltered` 与 `Opacity` 不按 `mix` 分支创建，否则滑停那一帧结构突变，
   视频纹理要重新合成，会闪 1～2 帧。`AnimatedOpacity` 只用在封面层淡出上。

顺带的好处：换剧那一瞬（`onPageChanged` 在滑动过半时触发）`mix ≈ 1`，
旧 stage 的 90ms 交叉淡化被虚化盖住，看不到上一部剧的画面残留。

## 构建

```bash
# 1) 原生库（确认 native/go.mod 里的 replace 路径指向短聚 native）
bash native/build_android.sh

# 2) APK
cd app
flutter pub get
flutter build apk --release --target-platform android-arm64
# 产物：app/build/app/outputs/flutter-apk/app-release.apk
```

Maven 走阿里云镜像，已写在 `app/android/settings.gradle.kts`；
图标改动后跑 `python app/tool/make_icon.py` 重新生成五套 mipmap。

## 排障笔记

**播放页显示「context canceled」，重试/换一部都没用**

引擎按 `sequence` 判重（`app_playback.go`：`sequence <= playbackSequence` 即返回
`context.Canceled`）。Dart 侧若用 1、2、3 这样的计数器，Flutter 引擎被系统回收重建后
计数器归零，而 Go 侧的全局值还停在旧数，之后每次解析都会被当成过期请求 —— 只能杀进程恢复。
0.6.1 起改用**单调时间戳**做序号并自动换号重试，已修复。

**漫剧 / AI 剧列表为空**

App 接口的 `comic_series` / `ai_series` 返回空，改用网页版分类页 `hongguoduanju.com/category/*`
补目录，播放仍走引擎；两边 `series_id` 同体系（`hongguo:<id>`）。

**榜单为空**

`/rank/hot-*` 用普通 UA 时 `content` 为空，需 **Googlebot UA**；第 1 页不能带 `?page=1`（会 301）。

## 版本记录

见 `docs/CHANGELOG.md`。
