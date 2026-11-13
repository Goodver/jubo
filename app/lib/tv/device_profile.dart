// 剧播 TV · 按 SoC 分化解码（2026-11-07）
//
// 背景（两台实机交叉验证，结论已收窄为平台专属问题，不是 mpv / media_kit 通病）：
//   · 海尔 HRA972_TX_A / Amlogic tl1 / Android 9：
//     hwdec=auto-safe → mediacodec-copy, pix=nv12, bt.709，人物肤色变纯蓝。
//     色彩元数据一致、libmpv 无 swapuv 滤镜 → 判定为 Amlogic MediaCodec HAL
//     回读 NV12 时 U/V 色度平面反读。软解 (pix=yuv420p) 颜色正常。
//   · 创维 8H672_A5FMN / 海思 Hi3751V660 (ro.board.platform=huanglong) / Android 12：
//     硬解颜色正常；软解 189.7% CPU / 硬解 74.5% CPU，PSS 158 / 110 MiB。
//     这台机器用软解是白白多烧 2.55 倍 CPU，理应走硬解。
//
// 因此默认档位是「自动」：按平台指纹查表选解；用户仍可在 TV 设置页
// 强制「硬解 / 软解」，选择持久化到 SharedPreferences。
// 清晰度统一 1280（720x1280 竖屏短剧，在 1080p 电视上已验证够用，且软解负载最低）。

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _deviceChannel = MethodChannel('hgonly/device');
const String _decodePreferenceKey = 'tv.decode.preference';

/// 用户在 TV 设置页里选的档位。auto 为出厂默认。
enum DecodePreference { auto, hardware, software }

extension DecodePreferenceX on DecodePreference {
  String get label => switch (this) {
    DecodePreference.auto => '自动（按 SoC 推荐）',
    DecodePreference.hardware => '强制硬解',
    DecodePreference.software => '强制软解',
  };

  String get hint => switch (this) {
    DecodePreference.auto => '已知有色彩缺陷的平台用软解，其余用硬解；新平台保守用软解',
    DecodePreference.hardware => 'hwdec=auto-safe，省 CPU；若出现偏色请切回自动或软解',
    DecodePreference.software => 'hwdec=no，颜色最稳、CPU 约为硬解的 2.5–3 倍',
  };
}

/// 已实测过的 SoC 家族；unknown 走保守策略。
enum SocFamily { amlogicBroken, hisiliconOk, unknown }

extension SocFamilyX on SocFamily {
  String get label => switch (this) {
    SocFamily.amlogicBroken => 'Amlogic（已知色彩缺陷）',
    SocFamily.hisiliconOk => '海思（硬解已验证正常）',
    SocFamily.unknown => '未收录平台',
  };
}

/// MainActivity.readTvDevice 返回的设备指纹。读不到时全为空，走保守软解。
class TvDeviceProfile {
  const TvDeviceProfile({
    this.boardPlatform = '',
    this.hardware = '',
    this.board = '',
    this.product = '',
    this.model = '',
    this.brand = '',
    this.manufacturer = '',
    this.release = '',
    this.sdkInt = 0,
    this.abi = '',
    this.hevcDecoders = const <String>[],
  });

  static const TvDeviceProfile empty = TvDeviceProfile();

  final String boardPlatform;
  final String hardware;
  final String board;
  final String product;
  final String model;
  final String brand;
  final String manufacturer;
  final String release;
  final int sdkInt;
  final String abi;
  final List<String> hevcDecoders;

  factory TvDeviceProfile.fromChannel(Map<dynamic, dynamic> raw) {
    String text(String key) => raw[key]?.toString() ?? '';
    return TvDeviceProfile(
      boardPlatform: text('boardPlatform'),
      hardware: text('hardware'),
      board: text('board'),
      product: text('product'),
      model: text('model'),
      brand: text('brand'),
      manufacturer: text('manufacturer'),
      release: text('release'),
      sdkInt: int.tryParse(text('sdkInt')) ?? 0,
      abi: text('abi'),
      hevcDecoders:
          (raw['hevcDecoders'] as List?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          const <String>[],
    );
  }

  static Future<TvDeviceProfile> load() async {
    try {
      final Object? raw = await _deviceChannel.invokeMethod<Object?>(
        'readTvDevice',
      );
      if (raw is Map) {
        return TvDeviceProfile.fromChannel(Map<dynamic, dynamic>.from(raw));
      }
    } catch (_) {
      // 通道不可用时保持 empty，策略会落到「未知平台 → 软解」，不会崩。
    }
    return empty;
  }

  String get platform => boardPlatform.isNotEmpty ? boardPlatform : hardware;

  String get summary =>
      '${model.isEmpty ? '未知设备' : model} · Android '
      '${release.isEmpty ? '?' : release}'
      '${sdkInt > 0 ? ' (API $sdkInt)' : ''}'
      '${abi.isEmpty ? '' : ' · $abi'}';

  String get fingerprint =>
      'platform=${platform.isEmpty ? '?' : platform} '
      'hardware=${hardware.isEmpty ? '?' : hardware} '
      'board=${board.isEmpty ? '?' : board} '
      'product=${product.isEmpty ? '?' : product}';
}

class DecodeDecision {
  const DecodeDecision({
    required this.hwdec,
    required this.quality,
    required this.reason,
    required this.family,
    required this.preference,
  });

  /// mpv 的 hwdec 值：'no' = 纯软解；'auto-safe' = 允许 mediacodec-copy。
  final String hwdec;
  final int quality;
  final String reason;
  final SocFamily family;
  final DecodePreference preference;

  bool get isHardware => hwdec != 'no';
  String get modeLabel => isHardware ? '硬解 auto-safe' : '软解 no';
}

class DecodePolicy {
  const DecodePolicy._();

  /// TV 统一档位；两轮对比后定型为 1280（软解负载远低于 1920，画面足够）。
  static const int tvQuality = 1280;

  // Amlogic 平台/解码器指纹。黑名单优先匹配：宁可多用一点 CPU，也不能出偏色。
  // tl1 = 海尔 HRA972_TX_A 实测平台；g12*/sm1/s905*/s912/s922/p2xx 是同系常见板型。
  static const List<String> _amlogicTokens = <String>[
    'amlogic',
    'omx.amlogic',
    'tl1',
    'g12a',
    'g12b',
    'gxl',
    'gxm',
    'sm1',
    's905',
    's912',
    's922',
    'p212',
    'p291',
  ];

  // 海思平台/解码器指纹。huanglong = 创维 Hi3751V660 的 ro.board.platform。
  static const List<String> _hisiliconTokens = <String>[
    'omx.hisi',
    'hisi',
    'hi3751',
    'hi3796',
    'hi3798',
    'huanglong',
  ];

  static SocFamily classify(TvDeviceProfile profile) {
    final String id = <String>[
      profile.boardPlatform,
      profile.hardware,
      profile.board,
      profile.product,
      profile.manufacturer,
      profile.brand,
      profile.model,
      ...profile.hevcDecoders,
    ].join(' ').toLowerCase();
    if (_amlogicTokens.any(id.contains)) return SocFamily.amlogicBroken;
    if (_hisiliconTokens.any(id.contains)) return SocFamily.hisiliconOk;
    return SocFamily.unknown;
  }

  static DecodeDecision decide(
    TvDeviceProfile profile,
    DecodePreference preference,
  ) {
    final SocFamily family = classify(profile);
    switch (preference) {
      case DecodePreference.hardware:
        return DecodeDecision(
          hwdec: 'auto-safe',
          quality: tvQuality,
          family: family,
          preference: preference,
          reason: '手动强制硬解；如出现偏色请切回「自动」或「强制软解」',
        );
      case DecodePreference.software:
        return DecodeDecision(
          hwdec: 'no',
          quality: tvQuality,
          family: family,
          preference: preference,
          reason: '手动强制软解；颜色最稳，CPU 约为硬解的 2.5–3 倍',
        );
      case DecodePreference.auto:
        switch (family) {
          case SocFamily.amlogicBroken:
            return const DecodeDecision(
              hwdec: 'no',
              quality: tvQuality,
              family: SocFamily.amlogicBroken,
              preference: DecodePreference.auto,
              reason:
                  'Amlogic MediaCodec 回读 NV12 的 U/V 色度平面反读'
                  '（海尔 tl1 实测偏蓝）→ 自动软解',
            );
          case SocFamily.hisiliconOk:
            return const DecodeDecision(
              hwdec: 'auto-safe',
              quality: tvQuality,
              family: SocFamily.hisiliconOk,
              preference: DecodePreference.auto,
              reason:
                  '海思硬解颜色正常，CPU 约为软解的 39%'
                  '（创维 Hi3751V660 实测）→ 自动硬解',
            );
          case SocFamily.unknown:
            return const DecodeDecision(
              hwdec: 'no',
              quality: tvQuality,
              family: SocFamily.unknown,
              preference: DecodePreference.auto,
              reason:
                  '平台未收录 → 保守软解保证颜色正确；'
                  '确认颜色正常后可在设置里改「强制硬解」省 CPU',
            );
        }
    }
  }
}

/// 用户选择的持久化（键 tv.decode.preference，重装 App 会回到 auto）。
class DecodeSettingsStore {
  const DecodeSettingsStore._();

  static Future<DecodePreference> load() async {
    try {
      final String? value = (await SharedPreferences.getInstance()).getString(
        _decodePreferenceKey,
      );
      return DecodePreference.values.firstWhere(
        (DecodePreference item) => item.name == value,
        orElse: () => DecodePreference.auto,
      );
    } catch (_) {
      return DecodePreference.auto;
    }
  }

  static Future<void> save(DecodePreference preference) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _decodePreferenceKey,
        preference.name,
      );
    } catch (_) {
      // 存不下就只影响下次启动，本次会话内仍按用户选择生效。
    }
  }
}
