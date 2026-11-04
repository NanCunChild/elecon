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
const expectedSchemaCount = 79;
const expectedRegistryReferenceCount = 77;

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

const messageAccount = {
  serviceId: "synthetic-service",
  accountId: "synthetic-account",
  accountLabel: "Synthetic account",
  fetchedAt: "2026-11-02T08:00:00Z",
};
const messageTarget = {
  accountId: messageAccount.accountId,
  conversationId: "synthetic-conversation",
  conversationKind: "group",
};
const textMessage = {
  id: "9007199254740993",
  text: "Synthetic message",
  kind: "text",
  direction: "incoming",
};
const historyPage = {
  ...messageAccount,
  ...messageTarget,
  hasMore: false,
  items: [textMessage],
  recalledIds: ["9007199254740992"],
};
const sendParams = { ...messageTarget, clientId: "9007199254740993", text: "Synthetic message" };

const cases: Record<string, SchemaGolden> = {
  "elecon.web.content": {
    valid: { pageId: "synthetic-page", status: "unknown" },
    invalid: [
      {
        behavior: "unknown submission cannot be rewritten as a successful boolean",
        value: { pageId: "synthetic-page", status: true },
      },
    ],
  },
  "elecon.params.web.content": {
    valid: { pageId: "synthetic-page" },
    invalid: [
      {
        behavior: "page identity is not an arbitrary remote URL",
        value: { pageId: "https://example.invalid/" },
      },
    ],
  },
  "elecon.query.controls": {
    valid: { target: "grades.list", title: "Synthetic filters", submitLabel: "Search", controls: [] },
    invalid: [
      {
        behavior: "a read-only form cannot target a command",
        value: { target: "climate.command", title: "Synthetic filters", submitLabel: "Search", controls: [] },
      },
    ],
  },
  "elecon.params.query.controls": {
    valid: { target: "grades.list" },
    invalid: [{ behavior: "a form request cannot target a command", value: { target: "climate.command" } }],
  },
  "elecon.directory.phones": {
    valid: {
      items: [
        {
          id: "synthetic-office",
          name: "Synthetic office",
          category: "Services",
          phone: "10000",
          sourceUrl: "https://example.invalid/contact",
        },
      ],
      sourceUrl: "https://example.invalid/",
      verifiedDate: "2026-11-04",
    },
    invalid: [
      {
        behavior: "author review date is required, not fabricated from fetch time",
        value: { items: [], sourceUrl: "https://example.invalid/" },
      },
    ],
  },
  "elecon.params.directory.phones": {
    valid: {},
    invalid: [
      { behavior: "a directory query never accepts a dialing command", value: { operation: "call" } },
    ],
  },
  "elecon.account.session": {
    valid: { status: "authenticated", accountId: "synthetic-account", checkedAt: "2026-11-03T00:00:00Z" },
    invalid: [
      { behavior: "credential presence is not a verified login state", value: { status: "saved" } },
      {
        behavior: "account identifiers are nonempty strings",
        value: { status: "authenticated", accountId: 42 },
      },
      {
        behavior: "check time must be a valid timestamp",
        value: { status: "expired", checkedAt: "yesterday" },
      },
    ],
  },
  "elecon.params.account.session": {
    valid: { account: "school", operation: "status" },
    invalid: [
      { behavior: "an account target is explicit", value: { operation: "status" } },
      {
        behavior: "status checking cannot carry password inputs",
        value: { account: "school", operation: "status", password: "synthetic" },
      },
      {
        behavior: "unimplemented account operations are rejected",
        value: { account: "school", operation: "refresh" },
      },
    ],
  },
  "elecon.messages.conversations": {
    valid: {
      ...messageAccount,
      coverage: "partial",
      items: [
        {
          conversationId: "synthetic-conversation",
          conversationKind: "direct",
          title: "Synthetic",
          hasContent: true,
          lastMessageAt: "2026-11-02T08:00:00Z",
        },
      ],
    },
    invalid: [
      {
        behavior: "directory coverage is explicit",
        value: { ...messageAccount, coverage: "window", items: [] },
      },
      {
        behavior: "conversation kind cannot be inferred from the ID",
        value: { ...messageAccount, coverage: "complete", items: [{ conversationId: "c", title: "C" }] },
      },
      {
        behavior: "content evidence is boolean, never an inferred unread count",
        value: {
          ...messageAccount,
          coverage: "complete",
          items: [{ conversationId: "c", conversationKind: "group", title: "C", hasContent: 3 }],
        },
      },
      {
        behavior: "last content time is a valid source timestamp",
        value: {
          ...messageAccount,
          coverage: "complete",
          items: [
            {
              conversationId: "c",
              conversationKind: "group",
              title: "C",
              lastMessageAt: "2026-02-30T00:00:00Z",
            },
          ],
        },
      },
    ],
  },
  "elecon.params.messages.conversations": {
    valid: { accountId: messageAccount.accountId },
    invalid: [
      { behavior: "requests require a verified account", value: {} },
      {
        behavior: "directory read cannot carry write operations",
        value: { accountId: "a", operation: "send" },
      },
    ],
  },
  "elecon.messages.history": {
    valid: { ...historyPage, sendPermission: "muted", items: [{ ...textMessage, kind: "command" }] },
    invalid: [
      {
        behavior: "send permission is explicit domain data",
        value: { ...historyPage, sendPermission: true },
      },
      {
        behavior: "unknown message kinds cannot become commands",
        value: { ...historyPage, items: [{ ...textMessage, kind: "execute" }] },
      },
      {
        behavior: "message IDs never use floating point",
        value: { ...historyPage, items: [{ ...textMessage, id: 42 }] },
      },
      {
        behavior: "cursor is a nonempty opaque string",
        value: { ...historyPage, hasMore: true, nextCursor: 42 },
      },
      { behavior: "source completeness is explicit", value: { ...historyPage, hasMore: null } },
      { behavior: "history page is bounded", value: { ...historyPage, items: Array(201).fill(textMessage) } },
    ],
  },
  "elecon.params.messages.history": {
    valid: { ...messageTarget, cursor: "9007199254740993" },
    invalid: [
      { behavior: "numeric cursor would lose precision", value: { ...messageTarget, cursor: 42 } },
      {
        behavior: "unbounded channel kinds are not supported",
        value: { ...messageTarget, conversationKind: "channel" },
      },
    ],
  },
  "elecon.messages.send": {
    valid: { ...messageAccount, ...messageTarget, clientId: sendParams.clientId, status: "unknown" },
    invalid: [
      {
        behavior: "transport success cannot be reported as delivery confirmation",
        value: { ...messageAccount, ...messageTarget, clientId: sendParams.clientId, status: "success" },
      },
      {
        behavior: "request confirmation ID must stay a decimal string",
        value: { ...messageAccount, ...messageTarget, clientId: 42, status: "unknown" },
      },
    ],
  },
  "elecon.params.messages.send": {
    valid: sendParams,
    invalid: [
      {
        behavior: "only explicit bounded text may be sent",
        value: { ...sendParams, text: "x".repeat(4001) },
      },
      {
        behavior: "attachment uploads are not part of text sending",
        value: { ...sendParams, url: "https://example.invalid/a" },
      },
      { behavior: "client ID cannot be zero", value: { ...sendParams, clientId: "0" } },
    ],
  },
  "elecon.card.qr": {
    valid: {
      imageBase64: "iVBORw0KGgoAAA==",
      issuedAt: "2026-11-02T00:00:00Z",
      expiresAt: "2026-11-02T00:00:30Z",
    },
    invalid: [
      {
        behavior: "only a PNG base64 payload is accepted",
        value: {
          imageBase64: "https://example.invalid/qr",
          issuedAt: "2026-11-02T00:00:00Z",
          expiresAt: "2026-11-02T00:00:30Z",
        },
      },
    ],
  },
  "elecon.faculty.search": {
    valid: {
      items: [],
      page: 1,
      pageSize: 10,
      hasMore: false,
      sourceSystem: "synthetic",
      sourceUrl: "https://example.invalid/faculty",
    },
    invalid: [
      {
        behavior: "page must identify the request and source",
        value: { items: [], page: 1, pageSize: 10, hasMore: false },
      },
    ],
  },
  "elecon.params.faculty.search": {
    valid: { query: "Synthetic", page: 1 },
    invalid: [{ behavior: "empty search cannot enumerate the directory", value: {} }],
  },
  "elecon.forum.session": {
    valid: { serviceId: "synthetic", serviceName: "Synthetic", status: "signedOut" },
    invalid: [
      {
        behavior: "authentication is an explicit state",
        value: { serviceId: "synthetic", serviceName: "Synthetic", status: true },
      },
    ],
  },
  "elecon.params.forum.session": {
    valid: { operation: "login" },
    invalid: [{ behavior: "remote posting is not an account operation", value: { operation: "post" } }],
  },
  "elecon.messages.session": {
    valid: {
      serviceId: "synthetic",
      serviceName: "Synthetic",
      status: "authenticated",
      accountId: "synthetic-id",
    },
    invalid: [{ behavior: "service identity is required", value: { status: "signedOut" } }],
  },
  "elecon.params.messages.session": {
    valid: { operation: "logout" },
    invalid: [{ behavior: "account operations cannot send messages", value: { operation: "send" } }],
  },
  "elecon.messages.list": {
    valid: {
      serviceId: "synthetic",
      accountId: "synthetic-id",
      accountLabel: "Synthetic",
      windowStartedAt: "2026-11-02T00:00:00Z",
      fetchedAt: "2026-11-02T00:00:10Z",
      coverage: "window",
      items: [],
    },
    invalid: [{ behavior: "an empty array cannot hide a missing account or window", value: { items: [] } }],
  },
  "elecon.params.messages.list": {
    valid: {},
    invalid: [{ behavior: "a receive window cannot post a message", value: { text: "Synthetic" } }],
  },
  "elecon.attendance.checkin": {
    valid: { status: "unsupported", reason: "location_required" },
    invalid: [
      { behavior: "raw responses are not a confirmed status", value: { status: "success" } },
      {
        behavior: "diagnostics are a bounded enum",
        value: { status: "rejected", reason: "raw source response" },
      },
    ],
  },
  "elecon.params.attendance.checkin": {
    valid: {
      location: {
        latitude: 12.3456,
        longitude: 45.6789,
        address: "Synthetic classroom",
        coordinateSystem: "service",
      },
    },
    invalid: [
      { behavior: "QR tickets only enter through the scanner", value: { qr: "synthetic-ticket" } },
      {
        behavior: "latitude is a bounded degree coordinate",
        value: {
          location: {
            latitude: 91,
            longitude: 45.6789,
            address: "Synthetic classroom",
            coordinateSystem: "service",
          },
        },
      },
    ],
  },
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
      gradePointScale: "4.0",
      items: [
        {
          courseId: "COURSE-001",
          courseName: "示例课程",
          credit: 2,
          score: { kind: "numeric", value: 90 },
          gradePoint: 3.7,
          gradePointSource: "adapter-derived",
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
      {
        behavior: "gradePointScale enum",
        value: {
          term: "2025-2026-2",
          gradePointScale: "4",
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
      },
      {
        behavior: "gradePointSource enum",
        value: {
          term: "2025-2026-2",
          items: [
            {
              courseId: "COURSE-001",
              courseName: "示例课程",
              credit: 2,
              score: { kind: "numeric", value: 90 },
              gradePoint: 3.7,
              gradePointSource: "derived",
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
    valid: {
      gpa: 3.8,
      gradePointScale: "4.3",
      earnedCredits: 60,
      attemptedCredits: 64,
      rank: 1,
      rankTotal: 100,
    },
    invalid: [
      { behavior: "rank starts at one", value: { gpa: 3.8, rank: 0 } },
      { behavior: "gradePointScale enum", value: { gpa: 3.8, gradePointScale: "4" } },
    ],
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

  // ADR-040: meters retain distinct remaining/reading meanings; commands are finite.
  "elecon.energy.meters": {
    valid: {
      items: [
        {
          meterId: "METER-SYNTHETIC",
          type: "electricity",
          unit: "kWh",
          remaining: 12.5,
          lastReadDate: "2026-10-31",
        },
      ],
    },
    invalid: [
      {
        behavior: "remaining is numeric, never a money/string substitute",
        value: { items: [{ meterId: "M", type: "electricity", unit: "kWh", remaining: "12.5" }] },
      },
      {
        behavior: "calendar reading day is a real date",
        value: { items: [{ meterId: "M", type: "water", unit: "m³", lastReadDate: "2026-02-30" }] },
      },
    ],
  },
  "elecon.climate.devices": {
    valid: {
      items: [
        {
          deviceId: "SYNTHETIC-DEVICE",
          label: "Synthetic room",
          minTemperature: 18,
          maxTemperature: 32,
          modes: ["cool"],
          fanSpeeds: ["auto"],
          commands: ["power", "temperature"],
          modeDefaults: [
            {
              mode: "cool",
              targetTemperature: 26,
              fanSpeed: "auto",
              turbo: false,
              auxiliaryHeat: false,
              indoorClean: false,
              outdoorClean: false,
            },
          ],
          powerOffClearsAuxiliaryHeat: true,
          powerOffClearsCleaning: true,
          fanSpeedClearsTurbo: true,
          turboUsesAutoFan: true,
        },
      ],
    },
    invalid: [
      {
        behavior: "empty device identifier cannot select hardware",
        value: { items: [{ deviceId: "", label: "Synthetic room" }] },
      },
    ],
  },
  "elecon.climate.status": {
    valid: {
      deviceId: "SYNTHETIC-DEVICE",
      power: false,
      mode: "cool",
      targetTemperature: 26,
      observedAt: "2026-10-31T00:00:00Z",
    },
    invalid: [
      {
        behavior: "unknown state is omitted, not an invalid enum",
        value: { deviceId: "SYNTHETIC-DEVICE", mode: "arbitrary" },
      },
      { behavior: "power is boolean", value: { deviceId: "SYNTHETIC-DEVICE", power: 1 } },
    ],
  },
  "elecon.climate.command": {
    valid: { status: "unknown" },
    invalid: [{ behavior: "HTTP success is not a result status", value: { status: "success" } }],
  },
  "elecon.params.climate.status": {
    valid: { deviceId: "SYNTHETIC-DEVICE" },
    invalid: [{ behavior: "a device must be selected", value: {} }],
  },
  "elecon.params.climate.command": {
    valid: { deviceId: "SYNTHETIC-DEVICE", command: "temperature", settings: { targetTemperature: 26 } },
    invalid: [
      {
        behavior: "raw JSON is not a command enum",
        value: { deviceId: "SYNTHETIC-DEVICE", command: "raw", settings: {} },
      },
      {
        behavior: "temperature has a finite upper bound",
        value: { deviceId: "SYNTHETIC-DEVICE", command: "temperature", settings: { targetTemperature: 33 } },
      },
    ],
  },
};

async function main(): Promise<void> {
  // ADR-040: isolate the identifier constraint from all other required fields.
  const blankDevice = structuredClone(cases["elecon.climate.devices"]!.valid) as {
    items: Array<{ deviceId: string }>;
  };
  blankDevice.items[0]!.deviceId = "";
  cases["elecon.climate.devices"]!.invalid = [
    { behavior: "empty device identifier cannot select hardware", value: blankDevice },
  ];
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
