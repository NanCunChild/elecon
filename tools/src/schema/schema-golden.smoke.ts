/**
 * Registry 中全部 emits/params schema 的行为 golden。
 *
 * 每个 schema 都有一个有语义的合法样例，以及至少一个固定具体约束的非法样例。
 * Registry 反向核对保证新增引用不会在没有 golden 的情况下静默进入契约。
 */

import { strict as assert } from "node:assert";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const schemaDir = join(repoRoot, "contract/schema");
const registryPath = join(repoRoot, "contract/capability/registry.json");
const expectedSchemaCount = 48;
const expectedRegistryReferenceCount = 46;

interface InvalidGolden {
  behavior: string;
  value: unknown;
}

interface SchemaGolden {
  valid: unknown;
  invalid: InvalidGolden[];
}

interface RegistryEntry {
  emits: { schema: string };
  params?: { schema: string };
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function validatorFor(schemaId: string) {
  assert.ok(schemaId.startsWith("elecon."), `不支持的 schema id：${schemaId}`);
  const schemaName = schemaId.slice("elecon.".length);
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv.compile(readJson<object>(join(schemaDir, `${schemaName}.schema.json`)));
}

const cases: Record<string, SchemaGolden> = {
  "elecon.envelope": {
    valid: {
      schema: "elecon.notice.list",
      schemaVersion: "1.1",
      source: {
        schoolId: "school-example",
        adapterId: "adapter-example",
        adapterVersion: "1.0.0",
        origin: "client-direct",
      },
      freshness: { fetchedAt: "2026-03-01T00:00:00Z", ttlSeconds: 300, stale: false },
      data: { items: [] },
    },
    invalid: [
      {
        behavior: "nested freshness required",
        value: {
          schema: "elecon.notice.list",
          schemaVersion: "1.1",
          source: {
            schoolId: "school-example",
            adapterId: "adapter-example",
            adapterVersion: "1.0.0",
            origin: "client-direct",
          },
          freshness: { fetchedAt: "2026-03-01T00:00:00Z", stale: false },
          data: { items: [] },
        },
      },
    ],
  },
  "elecon.error": {
    valid: {
      schema: "elecon.error",
      schemaVersion: "1.0",
      error: {
        kind: "source_unavailable",
        retriable: true,
        capability: "notice.list",
        message: "示例服务暂不可用",
      },
    },
    invalid: [
      {
        behavior: "error schema const",
        value: {
          schema: "elecon.failure",
          schemaVersion: "1.0",
          error: {
            kind: "source_unavailable",
            retriable: true,
            capability: "notice.list",
            message: "示例服务暂不可用",
          },
        },
      },
    ],
  },
  "elecon.grades.list": {
    valid: {
      term: "2025-2026-2",
      items: [
        {
          courseId: "COURSE-001",
          courseName: "示例课程",
          credit: 2,
          score: { kind: "numeric", value: 90 },
          category: "required",
          status: "final",
        },
      ],
    },
    invalid: [
      {
        behavior: "nested score required",
        value: {
          term: "2025-2026-2",
          items: [
            {
              courseId: "COURSE-001",
              courseName: "示例课程",
              credit: 2,
              score: { value: 90 },
              category: "required",
              status: "final",
            },
          ],
        },
      },
    ],
  },
  "elecon.schedule.week": {
    valid: {
      term: "2025-2026-2",
      week: 1,
      days: [{ dayOfWeek: 1, slots: [{ start: "1", end: "2", courseName: "示例课程" }] }],
    },
    invalid: [
      {
        behavior: "nested slot required",
        value: { term: "2025-2026-2", week: 1, days: [{ dayOfWeek: 1, slots: [{ start: "1", end: "2" }] }] },
      },
    ],
  },
  "elecon.card.balance": {
    valid: {
      cardNumber: "****1234",
      balance: { amountMinor: -50, currency: "CNY" },
      lastTransaction: { amountMinor: 250, currency: "CNY", time: "2026-01-01T00:00:00Z" },
    },
    invalid: [
      {
        behavior: "Money currency pattern",
        value: { cardNumber: "****1234", balance: { amountMinor: 1250, currency: "cny" } },
      },
    ],
  },
  "elecon.card.transactions": {
    valid: {
      cardNumber: "****1234",
      items: [{ time: "2026-01-01T00:00:00Z", amountMinor: 250, currency: "CNY", direction: "debit" }],
    },
    invalid: [
      {
        behavior: "transaction amount is a non-negative integer",
        value: {
          cardNumber: "****1234",
          items: [{ time: "2026-01-01T00:00:00Z", amountMinor: -1, currency: "CNY", direction: "debit" }],
        },
      },
    ],
  },
  "elecon.library.loans": {
    valid: {
      items: [
        {
          bookId: "BOOK-001",
          title: "示例图书",
          borrowedAt: "2026-01-01T00:00:00Z",
          dueAt: "2026-02-01T00:00:00Z",
          overdueFee: { amountMinor: 0, currency: "CNY" },
        },
      ],
    },
    invalid: [
      {
        behavior: "nested overdue Money required",
        value: {
          items: [
            {
              bookId: "BOOK-001",
              title: "示例图书",
              borrowedAt: "2026-01-01T00:00:00Z",
              dueAt: "2026-02-01T00:00:00Z",
              overdueFee: { amountMinor: 0 },
            },
          ],
        },
      },
    ],
  },
  "elecon.notice.list": {
    valid: {
      items: [
        {
          id: "NOTICE-001",
          title: "示例通知",
          category: "academic",
          source: "示例部门",
          attachments: [{ name: "说明", url: "https://example.invalid/notice.pdf" }],
        },
      ],
    },
    invalid: [
      {
        behavior: "attachment URI format",
        value: {
          items: [
            {
              id: "NOTICE-001",
              title: "示例通知",
              category: "academic",
              source: "示例部门",
              attachments: [{ name: "说明", url: "not a uri" }],
            },
          ],
        },
      },
    ],
  },
  "elecon.generic.section": {
    valid: {
      sectionId: "energy",
      title: "能源",
      fields: [
        { label: "余额", role: "amount", value: { amountMinor: 1250, currency: "CNY" } },
        { label: "备注", role: "label", value: null },
      ],
    },
    invalid: [
      {
        behavior: "Money amountMinor is integer",
        value: {
          sectionId: "energy",
          title: "能源",
          fields: [{ label: "余额", role: "amount", value: { amountMinor: 12.5, currency: "CNY" } }],
        },
      },
    ],
  },
  "elecon.profile.me": {
    valid: { name: "示例用户", studentIdMasked: "****0001", identityType: "undergraduate" },
    invalid: [
      { behavior: "missing optional differs from null", value: { name: "示例用户", updatedAt: null } },
    ],
  },
  "elecon.term.list": {
    valid: { currentTerm: "2025-2026-2", items: [{ id: "TERM-2", name: "第二学期" }] },
    invalid: [
      {
        behavior: "nested term required",
        value: { currentTerm: "2025-2026-2", items: [{ id: "TERM-2" }] },
      },
    ],
  },
  "elecon.calendar.academic": {
    valid: {
      term: "2025-2026-2",
      startDate: "2026-02-23",
      holidays: [{ date: "2026-05-01", name: "示例假日", isTeachingDay: false }],
    },
    invalid: [
      {
        behavior: "nested holiday required",
        value: { term: "2025-2026-2", holidays: [{ date: "2026-05-01" }] },
      },
    ],
  },
  "elecon.exam.list": {
    valid: { term: "2025-2026-2", items: [{ courseName: "示例课程", examAt: "2026-06-01T01:00:00Z" }] },
    invalid: [
      {
        behavior: "exam date-time format",
        value: { term: "2025-2026-2", items: [{ courseName: "示例课程", examAt: "2026-06-01" }] },
      },
    ],
  },
  "elecon.classroom.available": {
    valid: {
      date: "2026-03-01",
      weekday: 7,
      items: [
        { building: "示例楼", room: "101", sections: [{ index: 24, occupied: false }], status: "available" },
      ],
    },
    invalid: [
      {
        behavior: "nested section upper boundary",
        value: {
          date: "2026-03-01",
          items: [{ building: "示例楼", room: "101", sections: [{ index: 25, occupied: false }] }],
        },
      },
    ],
  },
  "elecon.classroom.buildings": {
    valid: { campus: "示例校区", items: [{ building: "示例楼", roomCount: 10 }] },
    invalid: [
      {
        behavior: "nested building minLength",
        value: { campus: "示例校区", items: [{ building: "", roomCount: 10 }] },
      },
    ],
  },
  "elecon.attendance.summary": {
    valid: {
      term: "2025-2026-2",
      total: 1,
      items: [{ courseName: "示例课程", date: "2026-03-01", type: "leave", appealStatus: "approved" }],
    },
    invalid: [
      {
        behavior: "attendance enum",
        value: { items: [{ courseName: "示例课程", type: "present" }] },
      },
    ],
  },
  "elecon.library.seats": {
    valid: {
      items: [
        {
          library: "示例图书馆",
          seatId: "SEAT-001",
          status: "available",
          availableFrom: "2026-03-01T01:00:00Z",
        },
      ],
    },
    invalid: [
      {
        behavior: "seat date-time format",
        value: { items: [{ seatId: "SEAT-001", availableFrom: "tomorrow" }] },
      },
    ],
  },
  "elecon.library.booking": {
    valid: {
      items: [
        {
          id: "BOOKING-001",
          seatId: "SEAT-001",
          startAt: "2026-03-01T01:00:00Z",
          endAt: "2026-03-01T02:00:00Z",
          status: "reserved",
        },
      ],
    },
    invalid: [
      {
        behavior: "booking status enum",
        value: { items: [{ id: "BOOKING-001", status: "active" }] },
      },
    ],
  },
  "elecon.energy.usage": {
    valid: {
      items: [
        {
          type: "electricity",
          usage: 12.5,
          unit: "kWh",
          from: "2026-03-01T00:00:00Z",
          to: "2026-04-01T00:00:00Z",
        },
      ],
    },
    invalid: [
      { behavior: "energy date-time format", value: { items: [{ type: "water", from: "2026-03-01" }] } },
    ],
  },
  "elecon.course.catalog": {
    valid: { items: [{ courseId: "COURSE-001", name: "示例课程", capacity: 30, enrolled: 20 }] },
    invalid: [
      { behavior: "course capacity minimum", value: { items: [{ name: "示例课程", capacity: -1 }] } },
    ],
  },
  "elecon.course.selection": {
    valid: { items: [{ courseId: "COURSE-001", name: "示例课程", selected: true, status: "selected" }] },
    invalid: [
      { behavior: "selection status enum", value: { items: [{ name: "示例课程", status: "waiting" }] } },
    ],
  },
  "elecon.gpa.summary": {
    valid: { gpa: 3.8, earnedCredits: 60, attemptedCredits: 64, rank: 1, rankTotal: 100 },
    invalid: [{ behavior: "rank starts at one", value: { gpa: 3.8, rank: 0 } }],
  },
  "elecon.notice.detail": {
    valid: {
      id: "NOTICE-001",
      title: "示例通知",
      attachments: [{ name: "说明", url: "https://example.invalid/notice.pdf" }],
    },
    invalid: [
      {
        behavior: "nested attachment URI format",
        value: { id: "NOTICE-001", title: "示例通知", attachments: [{ name: "说明", url: "://bad" }] },
      },
    ],
  },
  "elecon.dorm.health": {
    valid: { items: [{ metric: "temperature", value: 24, unit: "C", status: "normal" }] },
    invalid: [
      { behavior: "health status enum", value: { items: [{ metric: "temperature", status: "good" }] } },
    ],
  },
  "elecon.dorm.service": {
    valid: {
      items: [{ id: "SERVICE-001", type: "repair", status: "processing", updatedAt: "2026-03-01T00:00:00Z" }],
    },
    invalid: [
      { behavior: "service date-time format", value: { items: [{ id: "SERVICE-001", updatedAt: "now" }] } },
    ],
  },
  "elecon.transport.schedule": {
    valid: {
      items: [
        {
          route: "示例线路",
          stop: "示例站点",
          departureAt: "2026-03-01T00:00:00Z",
          operatingDate: "2026-03-01",
          status: "scheduled",
        },
      ],
    },
    invalid: [
      { behavior: "transport status enum", value: { items: [{ route: "示例线路", status: "departed" }] } },
    ],
  },
  "elecon.dining.summary": {
    valid: { items: [{ merchant: "示例餐厅", amountMinor: 1250, currency: "CNY", period: "2026-03" }] },
    invalid: [
      {
        behavior: "dining Money currency pattern",
        value: { items: [{ amountMinor: 1250, currency: "cny" }] },
      },
    ],
  },
  "elecon.invoice.list": {
    valid: {
      items: [
        {
          invoiceNo: "INV-001",
          amountMinor: 1250,
          currency: "CNY",
          issuedAt: "2026-03-01T00:00:00Z",
          downloadUrl: "https://example.invalid/invoice.pdf",
        },
      ],
    },
    invalid: [
      {
        behavior: "invoice URI format",
        value: { items: [{ invoiceNo: "INV-001", downloadUrl: "invoice pdf" }] },
      },
    ],
  },
  "elecon.program.progress": {
    valid: {
      requiredCredits: 160,
      completedCredits: 120,
      remainingCredits: 40,
      status: "inProgress",
      groups: [{ name: "必修", requiredCredits: 100, completedCredits: 90 }],
    },
    invalid: [{ behavior: "program status enum", value: { requiredCredits: 160, status: "pending" } }],
  },
  "elecon.research.income": {
    valid: { items: [{ month: "2026-03", amountMinor: 10000, currency: "CNY", status: "paid" }] },
    invalid: [
      {
        behavior: "research Money amount is integer",
        value: { items: [{ amountMinor: 10.5, currency: "CNY" }] },
      },
    ],
  },
  "elecon.campus.network": {
    valid: {
      accountStatus: "active",
      usageBytes: 1024,
      online: true,
      devices: [{ id: "DEVICE-001", online: true }],
    },
    invalid: [{ behavior: "network account enum", value: { accountStatus: "locked" } }],
  },
  "elecon.app.announcement": {
    valid: {
      version: "1.0",
      items: [
        {
          title: "示例公告",
          content: "示例内容",
          publishedAt: "2026-03-01T00:00:00Z",
          url: "https://example.invalid/announcement",
          privacyUrl: "https://example.invalid/privacy",
        },
      ],
    },
    invalid: [
      { behavior: "announcement URI format", value: { items: [{ title: "示例公告", url: "announcement" }] } },
    ],
  },
  "elecon.params.grades.list": {
    valid: {},
    invalid: [{ behavior: "missing optional term differs from null", value: { term: null } }],
  },
  "elecon.params.schedule.week": {
    valid: { term: "2025-2026-2", week: 1 },
    invalid: [{ behavior: "week lower boundary", value: { term: "2025-2026-2", week: 0 } }],
  },
  "elecon.params.card.transactions": {
    valid: { from: "2026-01-01", to: "2026-01-31", page: 1, size: 20 },
    invalid: [
      { behavior: "transaction params date format", value: { from: "2026-02-30", page: 1 } },
      { behavior: "transaction params page lower boundary", value: { page: 0 } },
    ],
  },
  "elecon.params.notice.list": {
    valid: { category: "event", page: 1, size: 20 },
    invalid: [{ behavior: "notice params category enum", value: { category: "all" } }],
  },
  "elecon.params.generic.section": {
    valid: { section: "energy" },
    invalid: [{ behavior: "required section rejects null", value: { section: null } }],
  },
  "elecon.params.term.list": {
    valid: { includePast: true },
    invalid: [{ behavior: "includePast boolean type", value: { includePast: "true" } }],
  },
  "elecon.params.exam.list": {
    valid: { term: "2025-2026-2" },
    invalid: [{ behavior: "exam term string type", value: { term: null } }],
  },
  "elecon.params.classroom.available": {
    valid: {
      date: "2026-03-01",
      weekday: 7,
      buildingId: "BUILDING-001",
      sectionStart: 1,
      sectionEnd: 24,
      onlyAvailable: true,
    },
    invalid: [{ behavior: "weekday upper boundary", value: { weekday: 8 } }],
  },
  "elecon.params.classroom.buildings": {
    valid: { campus: "示例校区", term: "2025-2026-2" },
    invalid: [{ behavior: "campus string type", value: { campus: null } }],
  },
  "elecon.params.attendance.summary": {
    valid: { term: "2025-2026-2" },
    invalid: [{ behavior: "attendance term string type", value: { term: null } }],
  },
  "elecon.params.library.seats": {
    valid: { library: "示例图书馆", date: "2026-03-01" },
    invalid: [{ behavior: "seat params date format", value: { date: "2026-13-01" } }],
  },
  "elecon.params.library.booking": {
    valid: { from: "2026-03-01T00:00:00Z", to: "2026-03-02T00:00:00Z" },
    invalid: [{ behavior: "booking params date-time format", value: { from: "2026-03-01" } }],
  },
  "elecon.params.energy.usage": {
    valid: { from: "2026-03-01T00:00:00Z", to: "2026-04-01T00:00:00Z" },
    invalid: [{ behavior: "energy params date-time format", value: { to: "next month" } }],
  },
  "elecon.params.course.catalog": {
    valid: { term: "2025-2026-2", query: "示例课程" },
    invalid: [{ behavior: "catalog query string type", value: { query: null } }],
  },
  "elecon.params.course.selection": {
    valid: { term: "2025-2026-2" },
    invalid: [{ behavior: "selection term string type", value: { term: null } }],
  },
  "elecon.params.gpa.summary": {
    valid: { term: "2025-2026-2", window: "all" },
    invalid: [{ behavior: "GPA window string type", value: { window: null } }],
  },
};

async function main(): Promise<void> {
  const registry = readJson<{ capabilities: Record<string, RegistryEntry> }>(registryPath);
  const references = Object.values(registry.capabilities).flatMap((entry) => [
    entry.emits.schema,
    ...(entry.params ? [entry.params.schema] : []),
  ]);
  const uniqueSchemas = [...new Set(references)].sort();
  const goldenSchemas = Object.keys(cases).sort();
  const contractSchemas = readdirSync(schemaDir)
    .filter((file) => file.endsWith(".schema.json"))
    .map((file) => readJson<{ $id: string }>(join(schemaDir, file)).$id)
    .sort();

  assert.equal(
    contractSchemas.length,
    expectedSchemaCount,
    `contract schema 数已从 ${expectedSchemaCount} 变化`,
  );
  assert.equal(
    references.length,
    expectedRegistryReferenceCount,
    `registry 引用数已从 ${expectedRegistryReferenceCount} 变化，请同步 golden 口径`,
  );
  assert.deepEqual(goldenSchemas, contractSchemas, "golden case table 必须精确覆盖全部 contract schema");
  assert.deepEqual(
    uniqueSchemas.filter((schemaId) => !(schemaId in cases)),
    [],
    "golden case table 必须覆盖 registry 的全部唯一 emits/params schema",
  );

  for (const schemaId of contractSchemas) {
    const testCase = cases[schemaId]!;
    const validate = validatorFor(schemaId);
    assert.ok(validate(testCase.valid), `${schemaId} 合法 golden 未通过：${JSON.stringify(validate.errors)}`);
    assert.ok(testCase.invalid.length > 0, `${schemaId} 缺少行为非法样例`);

    for (const invalid of testCase.invalid) {
      assert.equal(validate(invalid.value), false, `${schemaId} 未拒绝非法行为样例 [${invalid.behavior}]`);
    }
  }

  console.log(
    `schema golden smoke：${contractSchemas.length}/${expectedSchemaCount} 个 schema 行为全部通过；registry emits/params ${references.length}/${expectedRegistryReferenceCount} 引用（${uniqueSchemas.length} 个唯一 schema，envelope/error 不由 registry 引用）`,
  );
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
