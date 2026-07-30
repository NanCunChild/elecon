/// 应用自述信息的单一来源：版本号与官方链接。
///
/// 与 [l10n](l10n/app_zh.arb) 分工：**可翻译的文案在 arb，不可翻译的事实在这里**
/// （版本号、URL）。UI 只读这里的常量，不散落硬编码字符串。
///
/// 版本号：`--dart-define=ELECON_VERSION=…` 可在构建期注入（CI 发版用 tag 去掉 v
/// 前缀）；未注入时回落到 [_fallbackVersion]，与 `pubspec.yaml` 的本地基线对齐。
/// 不引 package_info_plus——多一个平台通道依赖只为读一个字符串不划算。
library;

/// 官方站点根。私密数据永不经此（红线 #3）：这里只有公开静态页。
const String kOfficialSiteBase = 'https://elecon.xidian.one';

/// 隐私政策全文地址。
///
/// ⚠️ 占位：正式条款尚未发布，链接先指向该路径，页面上线后此常量不必改动。
const String kPrivacyPolicyUrl = '$kOfficialSiteBase/privacy';

const String _fallbackVersion = '0.1.0-dev';

/// 展示用版本号，如 `0.1.0-dev` / `0.2.1`。
const String kAppVersion = String.fromEnvironment(
  'ELECON_VERSION',
  defaultValue: _fallbackVersion,
);
