// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

export interface LibrarySearch {
  /** 书目关键词；去除首尾空白后非空。 */
  query: string;
  /** 页码，从1开始。 */
  page: number;
  /** 每页书目数，1至50。 */
  size: number;
  /** 是否还有下一页；源站无总数时由满页推断。 */
  hasNext: boolean;
  /** 总书目数；源站未提供则省略。 */
  total?: number;
  /** 当前页书目；不表示个人借阅。 */
  items: LibrarySearchItems[];
}

export interface LibrarySearchItems {
  /** 同源书目记录ID；不是借阅条码。 */
  bookId: string;
  /** 书名。 */
  title: string;
  /** 作者；来源未提供则省略。 */
  author?: string;
  /** ISBN；来源未提供则省略。 */
  isbn?: string;
  /** 出版社；来源未提供则省略。 */
  publisher?: string;
  /** 索书号；来源未提供则省略。 */
  callNumber?: string;
}
