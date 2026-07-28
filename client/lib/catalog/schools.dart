/// 内置学校目录（原型阶段）。
///
/// 把原先写死在 SettingsPage 的 [LoginManifestView] 归位到此目录，UI 只按 id 选校。
/// 真正的「manifest 从 contract 签名声明面加载」是后续工作（ADR-015 §5 / ADR-017 PR-4）；
/// 此目录是过渡：结构上把「有哪些学校 + 各自登录声明」与 UI 解耦，先内置 XIDIAN。
///
/// 🔒 注：这里的 [SchoolDescriptor.login] 仅含 URL / 域模式 / 注入声明，**不含任何凭证值**
/// （红线 #1）。已声明 CAS 母凭证 `ids-cas`（role=sso-master，ADR-017 §2.1）——收割即捕获
/// CASTGC 进核心（PR-2）；静默签票（PR-3）debug 下 Session 已装配 HeadlessSsoMinter。
/// 母凭证 scope 仅 `ids` 认证域、与下游数据域不重叠（ADR-017 §2.4 / 校验器 M4），
/// Broker 最长前缀不会外注。
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
    this.adapterId,
    this.tlsProceedHosts = const {},
    this.available = true,
    this.capabilityCredentials = const {},
  });

  final String id;
  final String displayName;

  /// 该校数据 adapter 的权威 id（catalog `^school-\S+$`），供 [SessionController.runCapability]
  /// 交编排器 `loadAdapter`。**null = 尚未接入 adapter**（仅登录、无数据能力）。真实 adapter bundle
  /// 随端点 D 发布后此值才有对应 catalog entry（见 [[loader-orchestration-progress]] 发布前门禁）。
  final String? adapterId;

  /// 副标题（认证体系说明，如 "IDS CAS 统一身份认证"）。
  final String subtitle;

  final LoginManifestView login;

  /// TLS 证书异常放行白名单（host 精确匹配）；仅 debug build 可忽略证书异常。
  final Set<String> tlsProceedHosts;

  /// 是否可选（false = 占位、即将接入）。
  final bool available;

  /// 能力 → 所需凭证 ref（核心声明，非 adapter 自报；ADR-017 / mint 闭环 §4.1）。
  /// 未出现的 capability = 无凭证要求（如 jwc 公开 `notice.list`）。
  final Map<String, List<String>> capabilityCredentials;
}

/// 西安电子科技大学（内置，默认可选）。
const _xidian = SchoolDescriptor(
  id: 'xidian',
  displayName: '西安电子科技大学',
  subtitle: 'IDS CAS 统一身份认证',
  // adapter 权威 id（catalog 匹配用）；对应 signed bundle 随端点 D 发布后才可加载（发布前门禁）。
  adapterId: 'school-xidian',
  tlsProceedHosts: {'ids.xidian.edu.cn', 'ehall.xidian.edu.cn'},
  // 能力→凭证映射（核心；adapter 不得自报「我要母票」）。
  capabilityCredentials: {
    'grades.list': ['ehall-session'],
    'schedule.week': ['ehall-session'],
    'exam.list': ['ehall-session'],
    // 空教室楼栋列表同样打 ehall jwapp（jxlcx.do），与 classroom.available 同需
    // ehall-session；此前漏配→跳过闸门直接跑 adapter，缺凭证时暴露成误导性的
    // 「fetch 失败」而非清晰的登录提示。补齐以与 available 一致。
    'classroom.buildings': ['ehall-session'],
    'classroom.available': ['ehall-session'],
    'card.balance': ['card-session'],
    'card.transactions': ['card-session'],
    'library.loans': ['library-session'],
    // notice.list 等公开能力：不出现 = 无凭证。
  },
  login: LoginManifestView(
    schoolId: 'xidian',
    // ⚠ service 必须指向 ehall 侧「吃 ticket、建会话」的端点 `ehall/login?service=...`，
    // 而非静态 SPA `/new/index.html`——后者不消费 ST，导致 ehall 从不 set session、
    // 收割永远拿不到 ehall-session（2026-07 真机实测：登录后 ehall 域 0 cookie）。
    // 这里与下方 ssoMint.services['ehall-session'].service 保持一致（等价 Uri.encodeComponent）：
    //   ids/authserver/login?service=ENC(ehall/login?service=ehall/new/index.html)
    url:
        'https://ids.xidian.edu.cn/authserver/login?service=https%3A%2F%2Fehall.xidian.edu.cn%2Flogin%3Fservice%3Dhttps%3A%2F%2Fehall.xidian.edu.cn%2Fnew%2Findex.html',
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
    // 静默签票声明（ADR-017 §2.5）：握有母凭证后按需换下游 session。
    // service URL 校准自 adapters_tests/XIDIAN（ehall/session.py、card/balance.py）；
    // library 仍待 borrow.py 逆向，暂不进 mint 白名单（fail-closed）。
    // 见 docs/reference/xidian_mint_closed_loop_plan.md §3。
    ssoMint: SsoMintDecl(
      authEndpoint:
          'https://ids.xidian.edu.cn/authserver/login?service={service}',
      services: {
        'ehall-session': SsoMintServiceDecl(
          service:
              'https://ehall.xidian.edu.cn/login?service=https://ehall.xidian.edu.cn/new/index.html',
          success: ['https://ehall.xidian.edu.cn/new/index.html*'],
        ),
        'card-session': SsoMintServiceDecl(
          service: 'https://v8scan.xidian.edu.cn/home/openXDOAuth2Page',
          success: [
            'https://v8scan.xidian.edu.cn/myaccount/*',
            'https://v8scan.xidian.edu.cn/myaccount/openMyAccount*',
          ],
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
        // openid 是 URL query 中的可重放凭证，由核心收割/注入，adapter 永不见值（ADR-020）。
        'card-session': CredentialDecl(
          scope: ['https://v8scan.xidian.edu.cn/*'],
          type: 'query',
          queryParam: 'openid',
        ),
        // library 会话常为 form-body token（非 cookie/query）——另案，勿假设 cookie 足够。
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
