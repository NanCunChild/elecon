export { selectAll, selectOne } from "css-select";
export { Comment, Document, Element, hasChildren, isCDATA, isTag, isText, Text } from "domhandler";
export {
  existsOne,
  filter,
  find,
  findAll,
  findOne,
  findOneChild,
  getAttributeValue,
  getChildren,
  getName,
  getParent,
  getSiblings,
  getText,
  hasAttrib,
  innerText,
  nextElementSibling,
  prevElementSibling,
  removeElement,
  replaceElement,
  textContent,
} from "domutils";
export { Parser, parseDocument } from "htmlparser2";

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
