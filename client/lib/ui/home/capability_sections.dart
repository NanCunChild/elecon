/// 首页「按需取数」能力区：成绩 / 课表 / 空教室 / 一卡通 / 考试 / 图书借阅。
///
/// 各能力所需凭证由 manifest 声明，[SessionController.runCapability] 内部按需确保。
/// UI 只按用户点击触发，**不在开屏强制登录**；也**不接触凭证值**（红线 #1）——auth
/// 失败一律复用已审的 [runSchoolLogin]，成功后重试能力。
///
/// 卡片由标准 schema 选择并在客户端固定实现，不接受 adapter 渲染描述（ADR-004 §2.1）。
library;

import 'package:flutter/material.dart';

import '../../core/adapter_service.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../session/session_controller.dart';
import '../../session/session_scope.dart';
import '../login/login_flow.dart';
import '../login/webview_login_page.dart';
import '../theme/liquid_glass.dart';
import 'home_page.dart' show GradesCard, ScheduleCard;
import 'models.dart';
import 'schema_decode.dart';

/// 一次能力取数 + 解码的归一化结果。
class _Outcome<T> {
  const _Outcome({this.data, this.needLogin = false, this.error});

  final T? data;
  final bool needLogin;
  final String? error;
}

/// 跑能力 → 解码。auth 失败归为 [needLogin]（引导可见登录后重试），不外泄凭证/原因语义。
Future<_Outcome<T>> _runDecoded<T>(
  SessionController session,
  String capability, {
  Map<String, dynamic>? params,
  required T? Function(Object?) decode,
}) async {
  final run = await session.runCapability(capability, params: params);
  if (!run.ok) {
    if (run.failureKind == CapabilityFailureKind.auth) {
      return const _Outcome(needLogin: true);
    }
    final reason = run.reason?.trim();
    final kind = run.failureKind?.name ?? 'unknown';
    return _Outcome(
      error: reason == null || reason.isEmpty
          ? '$capability 失败（$kind）'
          : '$capability 失败（$kind）：$reason',
    );
  }
  final data = decode(run.data);
  if (data == null) return _Outcome(error: '$capability 产出无法解码');
  return _Outcome(data: data);
}

/// 引导当前会话学校的可见登录；成功返回 true。凭证收割在核心（红线 #1）。
Future<bool> _promptVisibleLogin(
  BuildContext context,
  SessionController session, {
  String? targetRef,
}) async {
  final school = session.selectedSchool;
  if (school == null) return false;
  final serviceUrl = targetRef == null
      ? null
      : school.login.ssoMint?.services[targetRef]?.service;
  final result = await runSchoolLogin(
    context,
    session,
    school,
    initialUrl: serviceUrl,
    requiredRef: targetRef,
  );
  return result?.status == WebViewLoginStatus.success;
}

enum _Phase { idle, loading, loaded, needLogin, error }

// ===========================================================================
// 成绩（无参）
// ===========================================================================

class GradesSection extends StatefulWidget {
  const GradesSection({super.key});

  @override
  State<GradesSection> createState() => _GradesSectionState();
}

class _GradesSectionState extends State<GradesSection> {
  _Phase _phase = _Phase.idle;
  GradesList? _data;
  GpaSummary? _summary;
  String? _error;

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final session = SessionScope.of(context);
    final outcome = await _runDecoded<GradesList>(
      session,
      'grades.list',
      decode: gradesListFromDynamic,
    );
    // 学校官方绩点汇总：**可选增强**，取不到不影响成绩单本身（ADR-001 §3.5——
    // 官方数存在时权威，不存在时卡片退到本机聚合并换标签）。故失败一律吞掉，
    // 不把它的 needLogin/error 冒泡成整个成绩区的失败态。
    final summary = outcome.data == null
        ? null
        : await _loadGpaSummary(session);
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
        _summary = summary;
      }
    });
  }

  /// 取 `gpa.summary`；任何失败都返回 null（见 [_load] 中的理由）。
  Future<GpaSummary?> _loadGpaSummary(SessionController session) async {
    try {
      final run = await _runDecoded<GpaSummary>(
        session,
        'gpa.summary',
        decode: gpaSummaryFromDynamic,
      );
      return run.data;
    } on Object {
      return null;
    }
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(context, SessionScope.of(context));
    if (!mounted) return;
    if (ok) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.loaded && _data != null) {
      return GradesCard(_data!, summary: _summary);
    }
    return _PromptCard(
      title: '成绩',
      subtitle: '登录后查看本学期成绩单',
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: '查看成绩',
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

// ===========================================================================
// 课表（需 week；提供周次选择器）
// ===========================================================================

class ScheduleSection extends StatefulWidget {
  const ScheduleSection({super.key});

  @override
  State<ScheduleSection> createState() => _ScheduleSectionState();
}

class _ScheduleSectionState extends State<ScheduleSection> {
  static const int _maxWeek = 25;

  _Phase _phase = _Phase.idle;
  int _week = 1;
  ScheduleWeek? _data;
  String? _error;

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final session = SessionScope.of(context);
    final outcome = await _runDecoded<ScheduleWeek>(
      session,
      'schedule.week',
      params: {'week': _week},
      decode: scheduleWeekFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(context, SessionScope.of(context));
    if (!mounted) return;
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase == _Phase.loading;
    return Column(
      children: [
        _PromptCard(
          title: '课表',
          subtitle: '选择周次后查询',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WeekPicker(
                week: _week,
                maxWeek: _maxWeek,
                enabled: !busy,
                onChanged: (w) => setState(() => _week = w),
              ),
              const SizedBox(height: 8),
              _PhaseBody(
                phase: _phase,
                error: _error,
                idleLabel: '查询第 $_week 周',
                loadingHidden: false,
                onLoad: _load,
                onLogin: _login,
              ),
            ],
          ),
        ),
        if (_phase == _Phase.loaded && _data != null) ScheduleCard(_data!),
      ],
    );
  }
}

class _WeekPicker extends StatelessWidget {
  const _WeekPicker({
    required this.week,
    required this.maxWeek,
    required this.enabled,
    required this.onChanged,
  });

  final int week;
  final int maxWeek;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: enabled && week > 1 ? () => onChanged(week - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('第 $week 周', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          onPressed: enabled && week < maxWeek
              ? () => onChanged(week + 1)
              : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

// ===========================================================================
// 空教室（需 building + date；先取教学楼列表，再查空闲）
// ===========================================================================

class ClassroomSection extends StatefulWidget {
  const ClassroomSection({super.key});

  @override
  State<ClassroomSection> createState() => _ClassroomSectionState();
}

class _ClassroomSectionState extends State<ClassroomSection> {
  // 教学楼列表阶段
  _Phase _buildingsPhase = _Phase.idle;
  List<ClassroomBuildingsItems> _buildings = const [];
  String? _buildingsError;
  ClassroomBuildingsItems? _selected;

  // 空教室查询阶段
  _Phase _availPhase = _Phase.idle;
  DateTime _date = DateTime.now();
  ClassroomAvailable? _avail;
  String? _availError;

  Future<void> _loadBuildings() async {
    setState(() => _buildingsPhase = _Phase.loading);
    final session = SessionScope.of(context);
    final outcome = await _runDecoded<ClassroomBuildings>(
      session,
      'classroom.buildings',
      decode: classroomBuildingsFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _buildingsPhase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _buildingsPhase = _Phase.error;
        _buildingsError = outcome.error;
      } else {
        _buildingsPhase = _Phase.loaded;
        _buildings = outcome.data?.items ?? const [];
        _selected = _buildings.isNotEmpty ? _buildings.first : null;
      }
    });
  }

  Future<void> _loginThenBuildings() async {
    final ok = await _promptVisibleLogin(context, SessionScope.of(context));
    if (!mounted) return;
    if (ok) await _loadBuildings();
  }

  Future<void> _loadAvailable() async {
    final building = _selected;
    if (building == null) return;
    setState(() => _availPhase = _Phase.loading);
    final session = SessionScope.of(context);
    final params = <String, dynamic>{'date': _formatDate(_date)};
    if (building.buildingId != null && building.buildingId!.isNotEmpty) {
      params['buildingId'] = building.buildingId;
    } else {
      params['building'] = building.building;
    }
    final outcome = await _runDecoded<ClassroomAvailable>(
      session,
      'classroom.available',
      params: params,
      decode: classroomAvailableFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _availPhase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _availPhase = _Phase.error;
        _availError = outcome.error;
      } else {
        _availPhase = _Phase.loaded;
        _avail = outcome.data;
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 180)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    // 教学楼未就绪：先引导取列表（可能触发登录）。
    if (_buildingsPhase != _Phase.loaded) {
      return _PromptCard(
        title: '空教室',
        subtitle: '先加载教学楼列表',
        child: _PhaseBody(
          phase: _buildingsPhase,
          error: _buildingsError,
          idleLabel: '加载教学楼',
          onLoad: _loadBuildings,
          onLogin: _loginThenBuildings,
        ),
      );
    }

    final busy = _availPhase == _Phase.loading;
    return Column(
      children: [
        _PromptCard(
          title: '空教室',
          subtitle: '选择教学楼与日期后查询',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<ClassroomBuildingsItems>(
                isExpanded: true,
                value: _selected,
                onChanged: busy ? null : (b) => setState(() => _selected = b),
                items: [
                  for (final b in _buildings)
                    DropdownMenuItem(
                      value: b,
                      child: Text(
                        b.roomCount == null
                            ? b.building
                            : '${b.building}（${b.roomCount} 间）',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: Text('日期：${_formatDate(_date)}')),
                  TextButton.icon(
                    onPressed: busy ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: const Text('选择日期'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _PhaseBody(
                phase: _availPhase,
                error: _availError,
                idleLabel: '查询空教室',
                onLoad: _loadAvailable,
                onLogin: () async {
                  final ok = await _promptVisibleLogin(
                    context,
                    SessionScope.of(context),
                  );
                  if (mounted && ok) await _loadAvailable();
                },
              ),
            ],
          ),
        ),
        if (_availPhase == _Phase.loaded && _avail != null)
          _ClassroomResultCard(data: _avail!),
      ],
    );
  }
}

class _ClassroomResultCard extends StatelessWidget {
  const _ClassroomResultCard({required this.data});

  final ClassroomAvailable data;

  @override
  Widget build(BuildContext context) {
    final items = data.items ?? const [];
    final free = items.where((i) => i.occupied != true).toList();
    return _SectionShell(
      title: '空教室',
      subtitle: [
        if (data.date != null) data.date!,
        '${free.length}/${items.length} 空闲',
      ].join(' · '),
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('该教学楼当日无可展示教室'),
            )
          : Column(
              children: [
                for (final room in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      room.occupied == true
                          ? Icons.meeting_room
                          : Icons.meeting_room_outlined,
                      color: room.occupied == true
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    title: Text('${room.building} ${room.room}'),
                    subtitle: Text(
                      [
                        if (room.floor != null) '${room.floor} 层',
                        if (room.capacity != null) '${room.capacity} 座',
                        if (room.status != null) _roomStatusText(room.status!),
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
    );
  }
}

String _roomStatusText(String status) => switch (status) {
  'available' => '空闲',
  'occupied' => '占用',
  'partial' => '部分占用',
  _ => status,
};

// ===========================================================================
// 一卡通（用户按需；余额 → 交易明细）
// ===========================================================================

class CardSection extends StatefulWidget {
  const CardSection({super.key, this.transactionsEnabled = true});

  final bool transactionsEnabled;

  @override
  State<CardSection> createState() => _CardSectionState();
}

class _CardSectionState extends State<CardSection> {
  _Phase _phase = _Phase.idle;
  CardBalance? _data;
  String? _error;

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<CardBalance>(
      SessionScope.of(context),
      'card.balance',
      decode: cardBalanceFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(
      context,
      SessionScope.of(context),
      targetRef: 'card-session',
    );
    if (!mounted) return;
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_phase != _Phase.loaded || data == null) {
      return _PromptCard(
        title: '一卡通',
        subtitle: widget.transactionsEnabled ? '仅在你点击后查询余额和交易记录' : '仅在你点击后查询余额',
        child: _PhaseBody(
          phase: _phase,
          error: _error,
          idleLabel: '查看余额',
          onLoad: _load,
          onLogin: _login,
        ),
      );
    }

    return _SectionShell(
      title: '一卡通',
      // 即使 adapter 错把完整卡号填进 cardNumberMasked，UI 也只从权威 cardNumber 派生末四位。
      subtitle: _maskCardNumber(data.cardNumber),
      child: data.errorStatus == null
          ? Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _money(data.balance.amountMinor, data.balance.currency),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (data.status != null)
                        Text(
                          _cardStatusText(data.status!),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (widget.transactionsEnabled)
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const CardTransactionsPage(),
                      ),
                    ),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('交易明细'),
                  ),
              ],
            )
          : Row(
              children: [
                Expanded(child: Text(_balanceErrorText(data.errorStatus!))),
                OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新查询'),
                ),
              ],
            ),
    );
  }
}

class CardTransactionsPage extends StatefulWidget {
  const CardTransactionsPage({super.key});

  @override
  State<CardTransactionsPage> createState() => _CardTransactionsPageState();
}

class _CardTransactionsPageState extends State<CardTransactionsPage> {
  _Phase _phase = _Phase.loading;
  CardTransactions? _data;
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final outcome = await _runDecoded<CardTransactions>(
      SessionScope.of(context),
      'card.transactions',
      params: const {'page': 1, 'size': 20},
      decode: cardTransactionsFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(
      context,
      SessionScope.of(context),
      targetRef: 'card-session',
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _phase = _Phase.loading);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('一卡通交易明细')),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _Phase.needLogin => Center(
          child: FilledButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.login),
            label: const Text('登录并查看'),
          ),
        ),
        _Phase.error => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error ?? '加载失败', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _phase = _Phase.loading);
                    _load();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        _Phase.idle || _Phase.loaded => _transactionsBody(context),
      },
    );
  }

  Widget _transactionsBody(BuildContext context) {
    final data = _data;
    if (data == null || data.items.isEmpty) {
      return const Center(child: Text('暂无交易记录'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: data.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = data.items[index];
        final sign = _directionSign(item.direction);
        final color = sign == '+'
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurface;
        return ListTile(
          leading: Icon(
            sign == '+'
                ? Icons.south_west
                : sign == '-'
                ? Icons.north_east
                : Icons.swap_horiz,
            color: color,
          ),
          title: Text(item.merchant ?? item.type ?? '一卡通交易'),
          subtitle: Text(
            [
              _formatTimestamp(item.time),
              if (item.location != null) item.location!,
              if (item.status != null) _transactionStatusText(item.status!),
            ].join(' · '),
          ),
          trailing: Text(
            '$sign${_money(item.amountMinor, item.currency)}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

String _directionSign(String direction) => switch (direction) {
  'credit' || 'refund' || 'reversal' || 'subsidy' => '+',
  'debit' => '-',
  _ => '',
};

String _money(int amountMinor, String currency) {
  final sign = amountMinor < 0 ? '-' : '';
  final absolute = amountMinor.abs();
  final major = absolute ~/ 100;
  final minor = (absolute % 100).toString().padLeft(2, '0');
  final symbol = currency == 'CNY' ? '¥' : '$currency ';
  return '$sign$symbol$major.$minor';
}

String _maskCardNumber(String cardNumber) {
  if (cardNumber.length <= 4) return '••••';
  return '•••• ${cardNumber.substring(cardNumber.length - 4)}';
}

String _cardStatusText(String status) => switch (status) {
  'active' => '状态正常',
  'frozen' => '已冻结',
  'lost' => '已挂失',
  'cancelled' => '已注销',
  _ => '状态未知',
};

String _balanceErrorText(String status) => switch (status) {
  'failed' => '余额查询失败，当前数值可能不是最新结果。',
  'pending' => '余额仍在处理中，请稍后重试。',
  _ => '余额状态未知，请重新查询。',
};

String _transactionStatusText(String status) => switch (status) {
  'final' => '已完成',
  'pending' => '处理中',
  'failed' => '失败',
  'cancelled' => '已取消',
  _ => '状态未知',
};

String _formatTimestamp(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  return '${_formatDate(date)} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}

// ===========================================================================
// 考试 / 图书借阅（用户按需）
// ===========================================================================

class ExamSection extends StatefulWidget {
  const ExamSection({super.key});

  @override
  State<ExamSection> createState() => _ExamSectionState();
}

class _ExamSectionState extends State<ExamSection> {
  _Phase _phase = _Phase.idle;
  ExamList? _data;
  String? _error;

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<ExamList>(
      SessionScope.of(context),
      'exam.list',
      decode: examListFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(context, SessionScope.of(context));
    if (mounted && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_phase == _Phase.loaded && data != null) {
      return _ExamResultCard(data: data);
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeExamTitle,
      subtitle: l10n.homeExamPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: l10n.homeExamLoad,
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

class _ExamResultCard extends StatelessWidget {
  const _ExamResultCard({required this.data});

  final ExamList data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = data.items ?? const <ExamListItems>[];
    return _SectionShell(
      title: l10n.homeExamTitle,
      subtitle: data.term == null
          ? l10n.homeExamCount(items.length)
          : l10n.homeExamTermCount(data.term!, items.length),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.homeExamEmpty),
            )
          : Column(
              children: [
                for (final item in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_note_outlined),
                    title: Text(item.courseName),
                    subtitle: Text(
                      [
                        if (item.examAt != null) _formatTimestamp(item.examAt!),
                        if (item.campus != null) item.campus!,
                        if (item.building != null) item.building!,
                        if (item.room != null) item.room!,
                        if (item.examType != null) item.examType!,
                        if (item.changeReason != null) item.changeReason!,
                      ].join(' · '),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (item.status != null)
                          Text(_examStatusText(l10n, item.status!)),
                        if (item.seat != null)
                          Text(
                            l10n.homeExamSeat(item.seat!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class LibraryLoansSection extends StatefulWidget {
  const LibraryLoansSection({super.key});

  @override
  State<LibraryLoansSection> createState() => _LibraryLoansSectionState();
}

class _LibraryLoansSectionState extends State<LibraryLoansSection> {
  _Phase _phase = _Phase.idle;
  LibraryLoans? _data;
  String? _error;

  Future<void> _load() async {
    setState(() => _phase = _Phase.loading);
    final outcome = await _runDecoded<LibraryLoans>(
      SessionScope.of(context),
      'library.loans',
      decode: libraryLoansFromDynamic,
    );
    if (!mounted) return;
    setState(() {
      if (outcome.needLogin) {
        _phase = _Phase.needLogin;
      } else if (outcome.error != null) {
        _phase = _Phase.error;
        _error = outcome.error;
      } else {
        _phase = _Phase.loaded;
        _data = outcome.data;
      }
    });
  }

  Future<void> _login() async {
    final ok = await _promptVisibleLogin(context, SessionScope.of(context));
    if (mounted && ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_phase == _Phase.loaded && data != null) {
      return _LibraryLoansResultCard(data: data);
    }
    final l10n = AppLocalizations.of(context);
    return _PromptCard(
      title: l10n.homeLibraryLoansTitle,
      subtitle: l10n.homeLibraryLoansPrompt,
      child: _PhaseBody(
        phase: _phase,
        error: _error,
        idleLabel: l10n.homeLibraryLoansLoad,
        onLoad: _load,
        onLogin: _login,
      ),
    );
  }
}

class _LibraryLoansResultCard extends StatelessWidget {
  const _LibraryLoansResultCard({required this.data});

  final LibraryLoans data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _SectionShell(
      title: l10n.homeLibraryLoansTitle,
      subtitle: l10n.homeLibraryLoansCount(data.items.length),
      child: data.items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(l10n.homeLibraryLoansEmpty),
            )
          : Column(
              children: [
                for (final item in data.items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.overdue == true
                          ? Icons.warning_amber_rounded
                          : Icons.menu_book_outlined,
                      color: item.overdue == true
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    title: Text(item.title),
                    subtitle: Text(
                      [
                        if (item.author != null) item.author!,
                        if (item.branch != null) item.branch!,
                        if (item.location != null) item.location!,
                        if (item.callNumber != null) item.callNumber!,
                        l10n.homeLibraryLoansDue(_formatTimestamp(item.dueAt)),
                        if (item.overdueFee != null)
                          l10n.homeLibraryLoansOverdueFee(
                            _money(
                              item.overdueFee!.amountMinor,
                              item.overdueFee!.currency,
                            ),
                          ),
                      ].join(' · '),
                    ),
                    trailing: item.overdue == true
                        ? Text(
                            l10n.homeLibraryLoansOverdue,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          )
                        : null,
                  ),
              ],
            ),
    );
  }
}

String _examStatusText(AppLocalizations l10n, String status) =>
    switch (status) {
      'scheduled' => l10n.homeExamStatusScheduled,
      'changed' => l10n.homeExamStatusChanged,
      'cancelled' => l10n.homeExamStatusCancelled,
      'completed' => l10n.homeExamStatusCompleted,
      _ => l10n.homeExamStatusUnknown,
    };

// ===========================================================================
// 共用外壳
// ===========================================================================

/// 引导态卡片（与首页 `_SectionCard` 同风格；private 无法跨文件复用，故此处内联）。
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _SectionShell(title: title, subtitle: subtitle, child: child);
}

class _SectionShell extends StatelessWidget {
  const _SectionShell({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 按阶段渲染取数动作/状态；不含已加载内容（由各区自行渲染数据卡片）。
class _PhaseBody extends StatelessWidget {
  const _PhaseBody({
    required this.phase,
    required this.error,
    required this.idleLabel,
    required this.onLoad,
    required this.onLogin,
    this.loadingHidden = false,
  });

  final _Phase phase;
  final String? error;
  final String idleLabel;
  final VoidCallback onLoad;
  final VoidCallback onLogin;

  /// 课表等已内嵌 loading 行时可隐藏内联 spinner（此处始终展示，占位保留）。
  final bool loadingHidden;

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case _Phase.idle:
      case _Phase.loaded: // loaded 时本 body 仅用于「重新查询」入口
        return Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: onLoad,
            icon: const Icon(Icons.download_outlined),
            label: Text(idleLabel),
          ),
        );
      case _Phase.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('正在取数…'),
            ],
          ),
        );
      case _Phase.needLogin:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('需要登录后查看'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onLogin,
              icon: const Icon(Icons.login),
              label: const Text('登录并查看'),
            ),
          ],
        );
      case _Phase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error ?? '加载失败',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onLoad,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        );
    }
  }
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
