// TV 分支的全局会话：设备指纹 / 解码偏好 / 当前决策。
// 各页面直接读 TvSession.instance，避免在路由间层层传参。

import 'package:flutter/foundation.dart';

import 'device_profile.dart';

class TvSession extends ChangeNotifier {
  TvSession._();
  static final TvSession instance = TvSession._();

  TvDeviceProfile profile = TvDeviceProfile.empty;
  DecodePreference preference = DecodePreference.auto;

  DecodeDecision get decision => DecodePolicy.decide(profile, preference);

  Future<void> init() async {
    profile = await TvDeviceProfile.load();
    preference = await DecodeSettingsStore.load();
    notifyListeners();
  }

  Future<void> setPreference(DecodePreference value) async {
    if (value == preference) return;
    preference = value;
    await DecodeSettingsStore.save(value);
    notifyListeners();
  }
}
