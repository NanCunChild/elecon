// elecon:html — 极简 HTML 解析器（ADR-011 参考实现 / spike）
//
// 约束：引擎地板安全（无 ES2022+、无 BigInt），纯 JS、无 I/O、无副作用。
// 同一份源码在客户端 QuickJS 与服务端 QuickJS-wasm 执行 → 零漂移（ADR-005/008）。
// 容错规则固定且文档化（§2.3）：void 元素自闭合；li/p/tr/td 等可选闭合自动收尾；
// script/style 原文跳过；杂散闭合标签忽略。
//
// 非目标：不渲染、不算样式、不执行内联 JS（ADR-011 §2.2）。

const VOID = { area:1, base:1, br:1, col:1, embed:1, hr:1, img:1, input:1,
  link:1, meta:1, param:1, source:1, track:1, wbr:1 };

// 简化版 HTML5 可选闭合：键元素被列表中的新元素隐式关闭
const OPTIONAL_CLOSE = {
  li: ['li'], p: ['p'], option: ['option'],
  tr: ['tr'], td: ['td','th'], th: ['td','th'], dt: ['dt','dd'], dd: ['dt','dd'],
};

class Node {
  constructor(tag, attrs) {
    this.tag = tag;             // 小写标签名，或 '#text' / '#root'
    this.attrs = attrs || {};
    this.children = [];
    this.parent = null;
    this._text = null;          // 文本节点内容
  }
  get isElement() { return this.tag.charAt(0) !== '#'; }

  attr(name) {
    const v = this.attrs[name.toLowerCase()];
    return v === undefined ? null : v;
  }
  hasClass(c) {
    const cl = this.attrs['class'];
    if (!cl) return false;
    const parts = cl.split(/\s+/);
    for (let i = 0; i < parts.length; i++) if (parts[i] === c) return true;
    return false;
  }
  text() {
    if (this.tag === '#text') return this._text || '';
    let out = '';
    for (let i = 0; i < this.children.length; i++) out += this.children[i].text();
    return out;
  }
  matches(sel) {
    if (typeof sel === 'function') return sel(this);
    return matchSimple(this, sel);
  }
  find(sel) {
    let found = null;
    walk(this, (n) => { if (n.matches(sel)) { found = n; return true; } return false; });
    return found;
  }
  findAll(sel) {
    const out = [];
    walk(this, (n) => { if (n.matches(sel)) out.push(n); return false; });
    return out;
  }
  closest(sel) {
    let n = this.parent;
    while (n) { if (n.isElement && n.matches(sel)) return n; n = n.parent; }
    return null;
  }
  next(sel) {
    if (!this.parent) return null;
    const sibs = this.parent.children;
    let i = sibs.indexOf(this);
    for (i = i + 1; i < sibs.length; i++) {
      const n = sibs[i];
      if (!n.isElement) continue;
      if (sel === undefined || n.matches(sel)) return n;
    }
    return null;
  }
}

// 深度优先前序遍历元素节点；visit 返回 true 即停止
function walk(node, visit) {
  for (let i = 0; i < node.children.length; i++) {
    const c = node.children[i];
    if (!c.isElement) continue;
    if (visit(c)) return true;
    if (walk(c, visit)) return true;
  }
  return false;
}

// selector 子集：tag / .class / tag.class / [attr] / [attr=val]
function matchSimple(node, sel) {
  sel = sel.trim();
  let attrCheck = null;
  const ab = sel.indexOf('[');
  if (ab >= 0) {
    const close = sel.indexOf(']', ab);
    const inner = sel.slice(ab + 1, close);
    sel = (sel.slice(0, ab) + sel.slice(close + 1)).trim();
    const eq = inner.indexOf('=');
    if (eq >= 0) {
      let val = inner.slice(eq + 1).replace(/^["']|["']$/g, '');
      attrCheck = { name: inner.slice(0, eq).toLowerCase(), val: val };
    } else {
      attrCheck = { name: inner.toLowerCase(), val: null };
    }
  }
  let tag = sel, cls = null;
  const dot = sel.indexOf('.');
  if (dot >= 0) { tag = sel.slice(0, dot); cls = sel.slice(dot + 1); }
  if (tag && tag !== '*' && node.tag !== tag.toLowerCase()) return false;
  if (cls && !node.hasClass(cls)) return false;
  if (attrCheck) {
    const v = node.attr(attrCheck.name);
    if (v === null) return false;
    if (attrCheck.val !== null && v !== attrCheck.val) return false;
  }
  return true;
}

function decodeEntities(s) {
  if (s.indexOf('&') < 0) return s;
  return s
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (_, d) { return String.fromCharCode(parseInt(d, 10)); });
}

function parseTag(raw) {
  let selfClose = false;
  raw = raw.trim();
  if (raw.charAt(raw.length - 1) === '/') { selfClose = true; raw = raw.slice(0, -1); }
  const m = /^([a-zA-Z][a-zA-Z0-9:-]*)/.exec(raw);
  if (!m) return { tag: null, attrs: {}, selfClose: selfClose };
  const tag = m[1].toLowerCase();
  const attrs = {};
  const rest = raw.slice(m[1].length);
  const attrRe = /([^\s=\/]+)(\s*=\s*("([^"]*)"|'([^']*)'|([^\s]*)))?/g;
  let a;
  while ((a = attrRe.exec(rest)) !== null) {
    if (a[0] === '') { attrRe.lastIndex++; continue; }
    const name = a[1].toLowerCase();
    let val = a[4] !== undefined ? a[4] : (a[5] !== undefined ? a[5] : (a[6] !== undefined ? a[6] : ''));
    attrs[name] = decodeEntities(val);
  }
  return { tag: tag, attrs: attrs, selfClose: selfClose };
}

function addText(stack, txt) {
  if (txt === '') return;
  const t = new Node('#text', {});
  t._text = decodeEntities(txt);
  const parent = stack[stack.length - 1];
  t.parent = parent;
  parent.children.push(t);
}

function closeTag(stack, tag) {
  for (let k = stack.length - 1; k >= 1; k--) {
    if (stack[k].tag === tag) { stack.length = k; return; }
  }
}

function autoClose(stack, tag) {
  const top = stack[stack.length - 1];
  if (!top || !top.isElement) return;
  const closers = OPTIONAL_CLOSE[top.tag];
  if (closers && closers.indexOf(tag) >= 0) {
    stack.pop();
    autoClose(stack, tag);
  }
}

export function parse(html) {
  const root = new Node('#root', {});
  const stack = [root];
  let i = 0;
  const n = html.length;
  while (i < n) {
    const lt = html.indexOf('<', i);
    if (lt < 0) { addText(stack, html.slice(i)); break; }
    if (lt > i) addText(stack, html.slice(i, lt));
    if (html.substr(lt, 4) === '<!--') {
      const end = html.indexOf('-->', lt + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    if (html.charAt(lt + 1) === '!') {            // <!DOCTYPE ...> 等
      const end = html.indexOf('>', lt);
      i = end < 0 ? n : end + 1;
      continue;
    }
    const gt = html.indexOf('>', lt);
    if (gt < 0) { addText(stack, html.slice(lt)); break; }
    const raw = html.slice(lt + 1, gt);
    i = gt + 1;
    if (raw.charAt(0) === '/') {
      closeTag(stack, raw.slice(1).trim().toLowerCase());
      continue;
    }
    const parsed = parseTag(raw);
    if (!parsed.tag) continue;
    autoClose(stack, parsed.tag);
    const el = new Node(parsed.tag, parsed.attrs);
    const parent = stack[stack.length - 1];
    el.parent = parent;
    parent.children.push(el);
    if (VOID[parsed.tag] || parsed.selfClose) {
      // 自闭合，不入栈
    } else if (parsed.tag === 'script' || parsed.tag === 'style') {
      const close = '</' + parsed.tag;
      const ci = html.toLowerCase().indexOf(close, i);
      const endRaw = ci < 0 ? n : ci;
      const txt = html.slice(i, endRaw);
      if (txt) { const t = new Node('#text', {}); t._text = txt; t.parent = el; el.children.push(t); }
      const ge = html.indexOf('>', endRaw);
      i = ge < 0 ? n : ge + 1;
    } else {
      stack.push(el);
    }
  }
  return root;
}

export { Node };
