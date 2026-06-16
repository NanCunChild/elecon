# XIDIAN adapter 逆向测试脚本 — 来源说明

本目录下的 Python 脚本从 [traintime_pda](https://github.com/BenderBlog/traintime_pda) 项目的 Dart 代码转化而来，用于验证各接口的登录与取数流程。

## 来源文件映射

| 本目录 | 原始文件 (traintime_pda) | 说明 |
|--------|--------------------------|------|
| `ids/login.py` | `lib/repository/xidian_ids/ids_session.dart` + `slider_captcha_client.dart` + `network_session.dart` | IDS CAS/SSO 登录 + 滑块验证码 |
| `ehall/session.py` | `lib/repository/xidian_ids/ehall_session.dart` | E-Hall 会话 + useApp |
| `ehall/scores.py` | `lib/repository/xidian_ids/score_session.dart` | 成绩查询 (本科 + 研究生) |
| `ehall/schedule.py` | `lib/repository/xidian_ids/classtable_session.dart` | 课表查询 |
| `ehall/exams.py` | `lib/repository/xidian_ids/exam_session.dart` | 考试安排 |
| `card/balance.py` | `lib/repository/xidian_ids/school_card_session.dart` | 一卡通余额 + 消费记录 |
| `library/borrow.py` | `lib/repository/xidian_ids/library_session.dart` | 图书馆 (待完成) |
| `energy/meter.py` | `lib/repository/xidian_ids/energy_session.dart` | 水电查询 (待完成) |
| `jwc/` | 教务处公开通知抓取 (独立逆向) | 已有 |

## 依赖

```
pip install requests pycryptodome Pillow numpy beautifulsoup4
```

## 运行

每个脚本可独立运行，会交互式输入学号密码：

```bash
cd adapters_tests/XIDIAN
python ids/login.py          # 测试 IDS 登录
python ehall/scores.py       # 测试成绩查询
python ehall/schedule.py     # 测试课表查询
python card/balance.py       # 测试一卡通
```

## 安全说明

- 脚本仅用于本地开发验证，不提交任何真实凭证 (红线 #8)
- 密码通过 getpass 交互输入，不落盘
- 本目录不会进入正式 adapter 发布流程
