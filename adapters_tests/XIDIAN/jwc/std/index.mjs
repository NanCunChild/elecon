// XIDIAN 教务处 通知公告 → elecon.notice.list（declarative requestGraph / spike）
//
// 生产形态：`import { parse } from 'elecon:html'`（ADR-011 经 moduleHandler 注入）。
// spike 期：import 本地参考实现，验证 API 形态与端到端产出。
import { parse } from './lib/elecon_html.mjs';

const SOURCE = '西安电子科技大学教务处';
const BASE = 'https://jwc.xidian.edu.cn/';

// "2026.06"（span）+ "12"（p）→ ISO 8601。容错：抽取前三个数字当 年-月-日。
// 注：源页给的是发布日期、无时刻，按校所在时区 Asia/Shanghai 取零点。
function normalizeDate(yearMonth, day) {
  const nums = (String(yearMonth) + ' ' + String(day)).match(/\d+/g) || [];
  if (nums.length < 3) return null;
  const y = nums[0].length >= 4 ? nums[0] : ('20' + nums[0]).slice(-4);
  const mo = ('0' + nums[1]).slice(-2);
  const d = ('0' + nums[2]).slice(-2);
  return y + '-' + mo + '-' + d + 'T00:00:00+08:00';
}

// 稳定 id：优先取 href 里的数字标识，否则 slug 化。
function deriveId(href) {
  const m = String(href).match(/\d{3,}/g);
  if (m && m.length) return 'xidian-jwc-' + m[m.length - 1];
  return 'xidian-jwc-' + String(href).replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

function absUrl(href) {
  if (!href) return BASE;
  return href.indexOf('http') === 0 ? href : BASE + href.replace(/^\//, '');
}

export const capabilities = {
  'notice.list': function (ctx, params, responses) {
    const html = responses.home.body;
    const root = parse(html);

    // 1) 定位文本为「通知公告」的锚点
    const anchor = root.find(function (n) {
      return n.tag === 'a' && n.text().trim() === '通知公告';
    });
    if (!anchor) { ctx.log('warn', 'XIDIAN: 未找到「通知公告」锚点'); return { items: [] }; }

    // 2) 上溯容器 div.tit，取其后的兄弟 ul
    const titDiv = anchor.closest('div.tit') || anchor.closest('div');
    const ul = titDiv ? titDiv.next('ul') : null;
    if (!ul) { ctx.log('warn', 'XIDIAN: 未找到通知列表 ul'); return { items: [] }; }

    // 3) 遍历 li 提取
    const items = [];
    const lis = ul.findAll('li');
    for (let i = 0; i < lis.length; i++) {
      const a = lis[i].find('a');
      if (!a) continue;
      const href = a.attr('href') || '';
      const title = (a.attr('title') || a.text()).trim();
      if (!title) continue;

      const timeDiv = a.find(function (n) { return n.tag === 'div' && n.hasClass('time'); })
        || lis[i].find(function (n) { return n.tag === 'div' && n.hasClass('time'); });
      let publishedAt = null;
      if (timeDiv) {
        const p = timeDiv.find('p');
        const span = timeDiv.find('span');
        publishedAt = normalizeDate(span ? span.text() : '', p ? p.text() : '');
      }

      items.push({
        id: deriveId(href),
        title: title,
        url: absUrl(href),
        publishedAt: publishedAt || '1970-01-01T00:00:00+08:00',
        category: 'unknown',   // 源页无逐条分类信号 → unknown（schema 枚举允许）
        source: SOURCE,
      });
    }
    return { items: items };
  },
};
