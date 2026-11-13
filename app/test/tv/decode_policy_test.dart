// 按 SoC 分化解码的规则表回归测试（2026-11-07 两台实机结论）。
// 纯 Dart 逻辑，不依赖真机；新增平台规则时请同步补用例。

import 'package:flutter_test/flutter_test.dart';
import 'package:hgonly/tv/device_profile.dart';

TvDeviceProfile _haier() => const TvDeviceProfile(
      boardPlatform: 'tl1',
      hardware: 'amlogic',
      board: 'p291',
      product: 'HRA972_TX_A',
      model: 'HRA972_TX_A',
      release: '9',
      sdkInt: 28,
      hevcDecoders: <String>['OMX.amlogic.hevc.decoder.awesome'],
    );

TvDeviceProfile _skyworth() => const TvDeviceProfile(
      boardPlatform: 'huanglong',
      hardware: 'huanglong',
      board: 'huanglong',
      product: 'Hi3751V660',
      model: '8H672_A5FMN',
      release: '12',
      sdkInt: 31,
      hevcDecoders: <String>['OMX.hisi.video.decoder.hevc'],
    );

void main() {
  group('DecodePolicy.classify', () {
    test('Amlogic tl1 命中色彩缺陷黑名单', () {
      expect(DecodePolicy.classify(_haier()), SocFamily.amlogicBroken);
    });

    test('海思 huanglong / Hi3751V660 命中硬解白名单', () {
      expect(DecodePolicy.classify(_skyworth()), SocFamily.hisiliconOk);
    });

    test('平台属性缺失时靠解码器名也能识别 Amlogic', () {
      expect(
        DecodePolicy.classify(const TvDeviceProfile(
          hevcDecoders: <String>['OMX.amlogic.hevc.decoder.awesome'],
        )),
        SocFamily.amlogicBroken,
      );
    });

    test('黑名单优先于白名单，避免疑似设备误开硬解偏色', () {
      expect(
        DecodePolicy.classify(const TvDeviceProfile(
          boardPlatform: 'huanglong',
          hevcDecoders: <String>['OMX.amlogic.hevc.decoder.awesome'],
        )),
        SocFamily.amlogicBroken,
      );
    });

    test('通道读不到属性时归为未收录平台', () {
      expect(DecodePolicy.classify(TvDeviceProfile.empty), SocFamily.unknown);
    });
  });

  group('DecodePolicy.decide', () {
    test('海尔 tl1 自动走软解 @1280', () {
      final DecodeDecision d =
          DecodePolicy.decide(_haier(), DecodePreference.auto);
      expect(d.hwdec, 'no');
      expect(d.isHardware, isFalse);
      expect(d.quality, DecodePolicy.tvQuality);
      expect(d.family, SocFamily.amlogicBroken);
    });

    test('创维海思自动走硬解 @1280', () {
      final DecodeDecision d =
          DecodePolicy.decide(_skyworth(), DecodePreference.auto);
      expect(d.hwdec, 'auto-safe');
      expect(d.isHardware, isTrue);
      expect(d.quality, DecodePolicy.tvQuality);
      expect(d.family, SocFamily.hisiliconOk);
    });

    test('未知平台保守软解', () {
      final DecodeDecision d =
          DecodePolicy.decide(TvDeviceProfile.empty, DecodePreference.auto);
      expect(d.hwdec, 'no');
      expect(d.family, SocFamily.unknown);
    });

    test('手动硬解 / 软解覆盖自动结果', () {
      expect(
        DecodePolicy.decide(_haier(), DecodePreference.hardware).hwdec,
        'auto-safe',
      );
      expect(
        DecodePolicy.decide(_skyworth(), DecodePreference.software).hwdec,
        'no',
      );
    });
  });
}
