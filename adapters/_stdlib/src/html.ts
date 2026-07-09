export { parseDocument, Parser } from "htmlparser2";
export { selectAll, selectOne } from "css-select";
export {
  getText,
  getAttributeValue,
  hasAttrib,
  getName,
  getChildren,
  getParent,
  getSiblings,
  nextElementSibling,
  prevElementSibling,
  find,
  findAll,
  findOne,
  findOneChild,
  existsOne,
  filter,
  removeElement,
  replaceElement,
  textContent,
  innerText,
} from "domutils";
export { Document, Element, Text, Comment, isTag, isText, isCDATA, hasChildren } from "domhandler";

// ---- adapter 通用工具（与 HTML 解析紧耦合的 helper，audit 发现两 adapter 逐字重复） ----

/**
 * "2026-06-12" / "2026/06/12" / "2026.06.12" → RFC3339/UTC。
 * 无法识别返回 null → 调用方省略 `publishedAt`（notice.list schema 可选）。
 */
export function normalizeDate(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const m = s.match(/(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (!m) return null;
  return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}T00:00:00Z`;
}

/**
 * 手工 URL 绝对化（沙箱内无 `URL` 全局）。
 * href 为绝对 → 原样返回；相对 → 拼 `origin + "/" + href`（去前导 `/` 防双斜杆）。
 */
export function makeUrlAbsolute(href: string, origin: string): string {
  if (href.startsWith("http")) return href;
  return origin + "/" + href.replace(/^\//, "");
}
