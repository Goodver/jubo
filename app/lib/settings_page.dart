import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appmeta.dart';
import 'cache.dart';
import 'engine.dart';
import 'models.dart';
import 'store.dart';
import 'theme.dart';

Route<void> settingsRoute() =>
    MaterialPageRoute(builder: (_) => const SettingsPage());

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const MethodChannel _deviceChannel = MethodChannel('hgonly/device');

  int _cacheBytes = -1;
  bool _busy = false;
  PlaybackDevice _device = const PlaybackDevice();

  @override
  void initState() {
    super.initState();
    _measure();
    _loadDevice();
  }

  Future<void> _loadDevice() async {
    try {
      final device = await Engine.instance.playbackDevice();
      if (!mounted) return;
      setState(() => _device = device);
    } catch (_) {
      // 读不到就保持未设置状态，不影响其它设置项
    }
  }

  String get _deviceSubtitle {
    if (!_device.configured) return '未设置 · 取流失败时可填自己手机的 did/uid 兜底';
    final parts = <String>[
      if (_device.did.isNotEmpty) 'did ${_mask(_device.did)}',
      if (_device.uid.isNotEmpty) 'uid ${_mask(_device.uid)}',
      if (_device.model.isNotEmpty)
        '机型 ${_device.model}${_device.osVersion.isEmpty ? '' : '/Android ${_device.osVersion}'}',
    ];
    return '${parts.join(' · ')} · 仅取流失败时使用';
  }

  static String _mask(String value) =>
      value.length <= 6 ? value : '${value.substring(0, 3)}…${value.substring(value.length - 3)}';

  Future<void> _editDevice() async {
    final didController = TextEditingController(text: _device.did);
    final uidController = TextEditingController(text: _device.uid);
    String? error;
    String? readNote;
    var saving = false;
    var reading = false;
    PlaybackDevice? readProfile;

    final result = await showDialog<PlaybackDevice>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> submit({bool clear = false}) async {
            if (saving) return;
            setLocal(() {
              saving = true;
              error = null;
            });
            try {
              final saved = await Engine.instance.savePlaybackDevice(
                did: clear ? '' : didController.text,
                uid: clear ? '' : uidController.text,
                profile: clear
                    ? const PlaybackDevice()
                    : (readProfile ?? _device),
              );
              if (context.mounted) Navigator.of(context).pop(saved);
            } on AppFailure catch (failure) {
              if (!context.mounted) return;
              setLocal(() {
                saving = false;
                error = failure.message;
              });
            } catch (_) {
              if (!context.mounted) return;
              setLocal(() {
                saving = false;
                error = '保存失败，请重试';
              });
            }
          }

          // 读取本机身份：root 机器直接读红果 App 缓存里的 did/uid，
          // 没 root 就退回本机硬件档案 + 由 ANDROID_ID 派生的稳定设备号。
          Future<void> readLocal() async {
            if (reading || saving) return;
            setLocal(() {
              reading = true;
              readNote = null;
              error = null;
            });
            try {
              final data =
                  await _deviceChannel.invokeMapMethod<String, dynamic>('readIdentity');
              if (!context.mounted) return;
              final did = (data?['did'] as String? ?? '').trim();
              final uid = (data?['uid'] as String? ?? '').trim();
              final note = (data?['note'] as String? ?? '').trim();
              final model = (data?['model'] as String? ?? '').trim();
              final os = (data?['osVersion'] as String? ?? '').trim();
              final brand = (data?['brand'] as String? ?? '').trim();
              final osApi = (data?['osApi']?.toString() ?? '').trim();
              final resolution = (data?['resolution'] as String? ?? '').trim();
              final dpi = (data?['dpi'] as String? ?? '').trim();
              final abi = (data?['abi'] as String? ?? '').trim();
              setLocal(() {
                reading = false;
                if (did.isNotEmpty) didController.text = did;
                if (uid.isNotEmpty) uidController.text = uid;
                readProfile = PlaybackDevice(
                  did: did,
                  uid: uid,
                  brand: brand,
                  model: model,
                  osVersion: os,
                  osApi: osApi,
                  resolution: resolution,
                  dpi: dpi,
                  abi: abi,
                );
                readNote = [
                  if (note.isNotEmpty) note,
                  if (model.isNotEmpty)
                    '本机：$model${os.isEmpty ? '' : ' · Android $os'}',
                ].join('\n');
              });
            } on PlatformException catch (failure) {
              if (!context.mounted) return;
              setLocal(() {
                reading = false;
                readNote = '读取失败：${failure.message ?? '未知错误'}';
              });
            } catch (_) {
              if (!context.mounted) return;
              setLocal(() {
                reading = false;
                readNote = '读取失败，请重试';
              });
            }
          }

          return AlertDialog(
            backgroundColor: Hg.bg1,
            title: const Text(
              '自定义设备',
              style: TextStyle(fontSize: 16, color: Hg.text),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '平台收紧播放接口后，部分剧集会返回空内容。填上你自己手机的设备号，'
                    '取流时会用它兜底。\n\n'
                    '点下面的「读取本机 ID」自动填：手机已 root 会直接读红果 App 缓存里的 did/uid；'
                    '没有 root 读不到它的私有数据，只能按本机硬件信息派生一个设备号。',
                    style: TextStyle(fontSize: 12, color: Hg.text3, height: 1.55),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: (saving || reading) ? null : readLocal,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: reading
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Hg.text3,
                              ),
                            )
                          : const Icon(
                              Icons.phone_iphone_rounded,
                              size: 15,
                              color: Hg.brand2,
                            ),
                      label: Text(
                        reading ? '读取中…' : '读取本机 ID',
                        style: const TextStyle(fontSize: 12.5, color: Hg.brand2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _field(
                    controller: didController,
                    label: '设备号 did（可留空）',
                    enabled: !saving,
                  ),
                  const SizedBox(height: 10),
                  _field(
                    controller: uidController,
                    label: '用户号 uid（可留空）',
                    enabled: !saving,
                  ),
                  if (readNote != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      readNote!,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Hg.text3,
                        height: 1.5,
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: const TextStyle(fontSize: 11.5, color: Hg.warn),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => submit(clear: true),
                child: const Text('清除', style: TextStyle(color: Hg.text3)),
              ),
              TextButton(
                onPressed: saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消', style: TextStyle(color: Hg.text2)),
              ),
              TextButton(
                onPressed: saving ? null : submit,
                child: saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Hg.text3,
                        ),
                      )
                    : const Text('保存', style: TextStyle(color: Hg.brand2)),
              ),
            ],
          );
        },
      ),
    );
    didController.dispose();
    uidController.dispose();
    if (result == null || !mounted) return;
    setState(() => _device = result);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.configured ? '已保存自定义设备号' : '已清除自定义设备号'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required bool enabled,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(fontSize: 14, color: Hg.text),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12.5, color: Hg.text3),
        filled: true,
        fillColor: Hg.bg2,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Hg.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Hg.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Hg.brand2),
        ),
      ),
    );
  }

  Future<void> _measure() async {
    final bytes = await AppCache.bytes();
    if (!mounted) return;
    setState(() => _cacheBytes = bytes);
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Hg.bg1,
        title: const Text(
          '清空缓存',
          style: TextStyle(fontSize: 16, color: Hg.text),
        ),
        content: const Text(
          '会清空播放记录（观看进度、已看集数）和封面缓存。\n\n点赞和追剧不会被清掉。',
          style: TextStyle(fontSize: 13.5, color: Hg.text2, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Hg.text2)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(color: Hg.brand2)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final freed = await AppCache.clear();
    // 顺带把内存里的图片缓存也丢掉，封面列表会重新加载
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    } catch (_) {}
    await Store.instance.clearPlayback();
    if (!mounted) return;
    setState(() => _busy = false);
    await _measure();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          freed > 0
              ? '已清空播放记录与缓存，释放 ${AppCache.sizeLabel(freed)}'
              : '已清空播放记录与缓存',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        title: const Text(
          '设置',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 30),
        children: [
          _section('播放'),
          _tile(
            icon: Icons.phone_android_rounded,
            title: '自定义设备',
            subtitle: _deviceSubtitle,
            onTap: _editDevice,
          ),
          _section('数据'),
          _tile(
            icon: Icons.cleaning_services_rounded,
            title: '清空缓存',
            subtitle: [
              '播放记录 ${Store.instance.watchCount} 条',
              if (_cacheBytes >= 0) '缓存 ${AppCache.sizeLabel(_cacheBytes)}',
            ].join(' · '),
            trailing: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Hg.text3,
                    ),
                  )
                : null,
            onTap: _clearCache,
          ),
          _section('关于'),
          _tile(
            icon: Icons.description_outlined,
            title: '许可',
            subtitle: '本应用采用的第三方组件与开源许可',
            onTap: () => Navigator.of(context).push(licensesRoute()),
          ),
          _tile(
            icon: Icons.info_outline_rounded,
            title: '关于',
            subtitle: '${AppMeta.appName} ${AppMeta.versionLabel}',
            onTap: () => Navigator.of(context).push(aboutRoute()),
          ),
          const SizedBox(height: 26),
          Center(
            child: Text(
              '${AppMeta.appName} ${AppMeta.versionLabel} · ${AppMeta.packageName}',
              style: const TextStyle(fontSize: 11, color: Hg.text3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Hg.text3,
        letterSpacing: 0.4,
      ),
    ),
  );

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Hg.bg1,
        borderRadius: BorderRadius.circular(Hg.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Hg.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
            child: Row(
              children: [
                Icon(icon, size: 19, color: Hg.text2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Hg.text,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 11.5, color: Hg.text3),
                      ),
                    ],
                  ),
                ),
                trailing ??
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: Hg.text3,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 许可

Route<void> licensesRoute() =>
    MaterialPageRoute(builder: (_) => const LicensesPage());

class _Component {
  const _Component(this.name, this.license, this.note);

  final String name;
  final String license;
  final String note;
}

class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static const _components = <_Component>[
    _Component('Flutter', 'BSD-3-Clause', '跨平台 UI 框架，含 Flutter Engine'),
    _Component('Dart', 'BSD-3-Clause', 'Dart 语言与运行时'),
    _Component('media_kit', 'MIT', '视频播放能力封装'),
    _Component('media_kit_video', 'MIT', '视频渲染与控制层'),
    _Component(
      'media_kit_libs_android_video',
      'MIT',
      '打包的 libmpv 遵循 GPLv2+，FFmpeg 遵循 LGPLv2.1+',
    ),
    _Component('shared_preferences', 'BSD-3-Clause', '本地偏好设置存储'),
    _Component('path_provider', 'BSD-3-Clause', '应用数据目录定位'),
    _Component('package_info_plus', 'BSD-3-Clause', '读取应用版本信息'),
    _Component('ffi', 'BSD-3-Clause', '调用本地播放内核'),
    _Component('path', 'BSD-3-Clause', '路径处理'),
    _Component('cupertino_icons', 'MIT', '图标字体'),
    _Component('Material Icons', 'Apache-2.0', '界面图标'),
    _Component('Go 播放内核 (libhgnative.so)', '自有代码', '负责取源与解析播放地址'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        title: const Text(
          '许可',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(2, 0, 2, 14),
            child: Text(
              '本应用基于以下开源项目构建，感谢它们的作者。'
              '完整的许可原文可点下方按钮查看（由 Flutter 自动汇总每个依赖的 LICENSE 文件）。',
              style: TextStyle(fontSize: 12, height: 1.7, color: Hg.text2),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Hg.bg1,
              borderRadius: BorderRadius.circular(Hg.radius),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _components.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Hg.line,
                      indent: 14,
                      endIndent: 14,
                    ),
                  _row(_components[i]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: AppMeta.appName,
                applicationVersion: AppMeta.versionLabel,
                applicationLegalese:
                    '© ${AppMeta.author}　剧集内容版权归原权利方所有',
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Hg.line2),
                foregroundColor: Hg.text,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Hg.radius),
                ),
              ),
              child: const Text('查看完整开源许可', style: TextStyle(fontSize: 13.5)),
            ),
          ),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '说明：应用本身不包含任何剧集内容，视频均来自公开网络，'
              '相关版权归原始权利方所有。',
              style: TextStyle(fontSize: 11, height: 1.7, color: Hg.text3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(_Component item) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Hg.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                item.note,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: Hg.text3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Hg.bg2,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            item.license,
            style: const TextStyle(fontSize: 10.5, color: Hg.text2),
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------ 关于

Route<void> aboutRoute() => MaterialPageRoute(builder: (_) => const AboutPage());

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Hg.bg,
      appBar: AppBar(
        backgroundColor: Hg.bg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        title: const Text(
          '关于',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Hg.text,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Hg.logo2, Hg.logo],
                    ),
                    borderRadius: BorderRadius.circular(19),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '剧',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  AppMeta.appName,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Hg.text,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '版本 ${AppMeta.versionLabel}',
                  style: const TextStyle(fontSize: 12, color: Hg.text3),
                ),
                const SizedBox(height: 2),
                const Text(
                  '短剧信息流播放器',
                  style: TextStyle(fontSize: 11.5, color: Hg.text3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          Container(
            decoration: BoxDecoration(
              color: Hg.bg1,
              borderRadius: BorderRadius.circular(Hg.radius),
            ),
            child: Column(
              children: [
                _kv('应用名称', AppMeta.appName),
                _divider(),
                _kv('版本号', AppMeta.versionLabel),
                _divider(),
                _kv('包名', AppMeta.packageName),
                _divider(),
                _kv('作者', AppMeta.author),
                _divider(),
                _kv('播放内核', 'Go + libmpv (arm64)'),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '提示',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Hg.text2,
            ),
          ),
          const SizedBox(height: 10),
          const _Tip('这是一个个人练手项目，用 Flutter 重做的短剧信息流播放器。'),
          const _Tip('剧集内容全部来自公开网络，版权归原权利方所有；应用不存储、不分发任何视频文件。'),
          const _Tip('内容可用性依赖上游站点，随时可能失效，遇到白屏可以上滑换一部。'),
          const _Tip('仅供学习交流，请勿用于商业用途。喜欢某部剧，请支持正版。'),
          const SizedBox(height: 22),
          Center(
            child: Text(
              '© ${DateTime.now().year} ${AppMeta.author}',
              style: const TextStyle(fontSize: 11, color: Hg.text3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => const Divider(
    height: 1,
    thickness: 1,
    color: Hg.line,
    indent: 14,
    endIndent: 14,
  );

  Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    child: Row(
      children: [
        Text(key, style: const TextStyle(fontSize: 13, color: Hg.text2)),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: Hg.text),
          ),
        ),
      ],
    ),
  );
}

class _Tip extends StatelessWidget {
  const _Tip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: SizedBox(
              width: 4,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Hg.text3,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.75,
                color: Hg.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
