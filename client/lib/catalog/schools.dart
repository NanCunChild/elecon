/// 内置学校目录（原型阶段）。
///
/// 把原先写死在 SettingsPage 的 [LoginManifestView] 归位到此目录，UI 只按 id 选校。
/// 真正的「manifest 从 contract 签名声明面加载」是后续工作（ADR-015 §5 / ADR-017 PR-4）；
/// 此目录是过渡：结构上把「有哪些学校 + 各自登录声明」与 UI 解耦，先内置 XIDIAN。
///
/// 🔒 注：这里的 [SchoolDescriptor.login] 仅含 URL / 域模式 / 注入声明，**不含任何凭证值**
/// （红线 #1）。已声明 CAS 母凭证 `ids-cas`（role=sso-master，ADR-017 §2.1）——收割即捕获
/// CASTGC 进核心（PR-2）；静默签票（PR-3，ssoMint）仍待人工主导实现。母凭证 scope 仅 `ids`
/// 认证域、与下游数据域不重叠（ADR-017 §2.4 / 校验器 M4），Broker 最长前缀不会外注。
library;

import '../core/broker/inject_policy.dart';
import '../core/login/webview_login.dart';

/// 一所学校的展示信息 + 登录声明。
class SchoolDescriptor {
  const SchoolDescriptor({
    required this.id,
    required this.displayName,
    required this.subtitle,
    required this.login,
    this.tlsProceedHosts = const {},
    this.available = true,
  });

  final String id;
  final String displayName;

  /// 副标题（认证体系说明，如 "IDS CAS 统一身份认证"）。
  final String subtitle;

  final LoginManifestView login;

  /// TLS 证书异常放行白名单（host 精确匹配）；仅校园站封闭环境使用。
  final Set<String> tlsProceedHosts;

  /// 是否可选（false = 占位、即将接入）。
  final bool available;
}

/// 西安电子科技大学（内置，默认可选）。
const _xidian = SchoolDescriptor(
  id: 'xidian',
  displayName: '西安电子科技大学',
  subtitle: 'IDS CAS 统一身份认证',
  tlsProceedHosts: {'ids.xidian.edu.cn', 'ehall.xidian.edu.cn'},
  login: LoginManifestView(
    schoolId: 'xidian',
    url:
        'https://ids.xidian.edu.cn/authserver/login?service=https://ehall.xidian.edu.cn/new/index.html',
    navigationAllow: [
      'https://ids.xidian.edu.cn/*',
      'https://ehall.xidian.edu.cn/*',
      'https://v8scan.xidian.edu.cn/*',
      'https://hyytsgxzs.xidian.edu.cn/*',
      'https://xxcapp.xidian.edu.cn/*',
    ],
    successUrlMatches: [
      'https://ehall.xidian.edu.cn/new/index.html*',
      'https://v8scan.xidian.edu.cn/myaccount/openMyAccount*',
      'https://hyytsgxzs.xidian.edu.cn/*',
    ],
    // 静默签票声明（ADR-017 §2.5，PR-3 草案）：握有母凭证后按需换下游 session。
    // TODO(PR-3)：service 的精确 CAS service 参数须取自 adapters_tests/XIDIAN 逆向；
    // 此处用服务域根占位，执行器落地时校准。执行体（换票驱动）人工主导。
    ssoMint: SsoMintDecl(
      authEndpoint:
          'https://ids.xidian.edu.cn/authserver/login?service={service}',
      services: {
        'card-session': SsoMintServiceDecl(
          service: 'https://v8scan.xidian.edu.cn/',
          success: ['https://v8scan.xidian.edu.cn/myaccount/openMyAccount*'],
        ),
        'library-session': SsoMintServiceDecl(
          service: 'https://hyytsgxzs.xidian.edu.cn/',
          success: ['https://hyytsgxzs.xidian.edu.cn/*'],
        ),
      },
    ),
    brokerView: BrokerManifestView(
      allow: [
        // CAS 认证域：母凭证注入端点（静默签票，ADR-017 §2.4）。与下游数据域不重叠。
        'https://ids.xidian.edu.cn/*',
        'https://ehall.xidian.edu.cn/*',
        'https://v8scan.xidian.edu.cn/*',
        'https://hyytsgxzs.xidian.edu.cn/*',
      ],
      credentials: {
        // CAS 母凭证（CASTGC）：收割即捕获进核心；role=sso-master 驱动敏感度标注。
        'ids-cas': CredentialDecl(
          scope: ['https://ids.xidian.edu.cn/*'],
          type: 'cookie',
          role: 'sso-master',
        ),
        'ehall-session': CredentialDecl(
          scope: ['https://ehall.xidian.edu.cn/*'],
          type: 'cookie',
        ),
        'card-session': CredentialDecl(
          scope: ['https://v8scan.xidian.edu.cn/*'],
          type: 'cookie',
        ),
        'library-session': CredentialDecl(
          scope: ['https://hyytsgxzs.xidian.edu.cn/*'],
          type: 'cookie',
        ),
      },
    ),
  ),
);

/// 内置学校列表。原型仅 XIDIAN；后续按 ADR-015 从签名 manifest 装载。
const List<SchoolDescriptor> builtinSchools = [_xidian];

/// 缺省选中项（开始面板默认高亮）。
const SchoolDescriptor defaultSchool = _xidian;
