/**
 * ADR-023 strict linear regex subset for adapter-controlled extraction patterns.
 *
 * This parser and matcher deliberately do not delegate matching to the host RegExp
 * engine. The accepted language has no alternation, assertions, backreferences,
 * group quantifiers, or lazy quantifiers. At most one variable quantifier exists,
 * and it must be on the final consuming atom.
 *
 * Security-sensitive broker path (ADR-023 section 5 decision 1). AI drafted;
 * requires human security review before merge (AGENTS.md section 1).
 */

const MAX_PATTERN_UNITS = 256;
const MAX_GROUPS = 32;
const MAX_EXACT_REPEAT = 64;

type CharSet =
  | { readonly kind: "digit" }
  | { readonly kind: "word" }
  | { readonly kind: "space" }
  | {
      readonly kind: "class";
      readonly negated: boolean;
      readonly ranges: ReadonlyArray<readonly [number, number]>;
    };

interface Atom {
  readonly kind: "literal" | "dot" | "set";
  readonly value?: number;
  readonly set?: CharSet;
  readonly min: number;
  readonly max: number | null;
}

interface CaptureBoundary {
  readonly group: number;
  readonly startAtom: number;
  endAtom: number;
}

export interface LinearRegexPattern {
  readonly source: string;
  readonly anchoredStart: boolean;
  readonly anchoredEnd: boolean;
  readonly atoms: readonly Atom[];
  readonly captures: readonly CaptureBoundary[];
  readonly groupCount: number;
  readonly variableAtom: number | null;
}

export class LinearRegexSyntaxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LinearRegexSyntaxError";
  }
}

export interface LinearRegexMatch {
  /** Group 0 is the whole match; subsequent entries are ordinary capture groups. */
  readonly groups: readonly string[];
}

function fail(message: string): never {
  throw new LinearRegexSyntaxError(message);
}

/** Parse and validate an adapter pattern without invoking the native RegExp parser. */
export function parseLinearRegex(source: string): LinearRegexPattern {
  if (source.length > MAX_PATTERN_UNITS) fail(`pattern exceeds ${MAX_PATTERN_UNITS} UTF-16 code units`);
  assertWellFormedUtf16(source);

  let i = 0;
  const anchoredStart = source.startsWith("^");
  if (anchoredStart) i++;
  const end =
    source.endsWith("$") && !isEscaped(source, source.length - 1) ? source.length - 1 : source.length;
  const anchoredEnd = end !== source.length;
  const atoms: Atom[] = [];
  const captures: CaptureBoundary[] = [];
  const stack: CaptureBoundary[] = [];
  let groupCount = 0;
  let variableAtom: number | null = null;

  while (i < end) {
    const c = source[i]!;
    if (c === "(") {
      if (source[i + 1] === "?") fail("special groups and lookaround are not supported");
      if (++groupCount > MAX_GROUPS) fail(`capture group count exceeds ${MAX_GROUPS}`);
      const boundary: CaptureBoundary = { group: groupCount, startAtom: atoms.length, endAtom: -1 };
      captures.push(boundary);
      stack.push(boundary);
      i++;
      continue;
    }
    if (c === ")") {
      const boundary = stack.pop();
      if (boundary === undefined) fail("unmatched ')'");
      boundary.endAtom = atoms.length;
      if (boundary.startAtom === boundary.endAtom) fail("empty capture groups are not supported");
      i++;
      if (i < end && isQuantifierStart(source[i]!)) fail("group quantifiers are not supported");
      continue;
    }
    let parsed: { atom: Omit<Atom, "min" | "max">; next: number };
    if (c === "[") parsed = parseClass(source, i, end);
    else if (c === "\\") parsed = parseEscape(source, i, end);
    else if (c === ".") parsed = { atom: { kind: "dot" }, next: i + 1 };
    else {
      if ("|*+?{}[]^$".includes(c)) fail(`unsupported or misplaced metacharacter '${c}' at ${i}`);
      parsed = { atom: { kind: "literal", value: source.charCodeAt(i) }, next: i + 1 };
    }
    i = parsed.next;
    const quantifier = parseQuantifier(source, i, end);
    i = quantifier.next;
    const atom: Atom = { ...parsed.atom, min: quantifier.min, max: quantifier.max };
    atoms.push(atom);
    if (quantifier.max === null || quantifier.min !== quantifier.max) {
      if (variableAtom !== null) fail("only one variable quantifier is supported");
      variableAtom = atoms.length - 1;
    }
  }

  if (stack.length !== 0) fail("unclosed capture group");
  if (atoms.length === 0) fail("pattern must contain a consuming atom");
  if (variableAtom !== null && variableAtom !== atoms.length - 1) {
    // Narrow compatibility for `client_id:'(\w+)'`. ASCII \w cannot consume
    // either quote delimiter, so candidate scans cover disjoint word runs.
    const prefixDelimiter = atoms[variableAtom - 1];
    const suffix = atoms[variableAtom + 1];
    const variableEndsCapture = captures.some((capture) => capture.endAtom === variableAtom + 1);
    const safeQuotedWord =
      variableAtom === atoms.length - 2 &&
      prefixDelimiter?.kind === "literal" &&
      prefixDelimiter.value === 39 &&
      prefixDelimiter.min === 1 &&
      prefixDelimiter.max === 1 &&
      atoms[variableAtom]!.set?.kind === "word" &&
      suffix?.kind === "literal" &&
      suffix.value === 39 &&
      suffix.min === 1 &&
      suffix.max === 1 &&
      variableEndsCapture;
    if (!safeQuotedWord) fail("a variable quantifier is allowed only on the final consuming atom");
  }
  if (anchoredEnd && variableAtom !== null && !anchoredStart && atoms[variableAtom]!.kind !== "dot") {
    fail("an unanchored end-anchored variable quantifier is allowed only on dot");
  }
  if (
    anchoredEnd &&
    variableAtom !== null &&
    !anchoredStart &&
    atoms[variableAtom]!.kind === "dot" &&
    atoms.slice(0, variableAtom).some(atomCanMatchLineTerminator)
  ) {
    fail("the fixed prefix before an unanchored .*$ must not match line terminators");
  }

  return { source, anchoredStart, anchoredEnd, atoms, captures, groupCount, variableAtom };
}

/** Match the first candidate start with deterministic greedy final-atom semantics. */
export function matchLinearRegex(pattern: LinearRegexPattern, input: string): LinearRegexMatch | null {
  const matchEnd = pattern.anchoredEnd ? endAnchorOffset(input) : input.length;
  const finalVariableDot =
    pattern.anchoredEnd &&
    !pattern.anchoredStart &&
    pattern.variableAtom !== null &&
    pattern.atoms[pattern.variableAtom]!.kind === "dot";
  // `prefix.*$` can only match in the final line. Starting there avoids
  // rescanning every earlier suffix while retaining ordinary `$` behavior.
  const firstStart = finalVariableDot ? finalLineStart(input, matchEnd) : 0;
  const lastStart = pattern.anchoredStart ? 0 : matchEnd;
  for (let start = firstStart; start <= lastStart; start++) {
    const starts = new Array<number>(pattern.groupCount + 1).fill(-1);
    const ends = new Array<number>(pattern.groupCount + 1).fill(-1);
    let pos = start;
    let failed = false;

    for (let atomIndex = 0; atomIndex < pattern.atoms.length; atomIndex++) {
      for (const capture of pattern.captures)
        if (capture.startAtom === atomIndex) starts[capture.group] = pos;
      const atom = pattern.atoms[atomIndex]!;
      let count = 0;
      const limit = atom.max ?? Number.POSITIVE_INFINITY;
      let width: number;
      while (count < limit && pos < matchEnd) {
        width = atomMatchWidth(atom, input, pos);
        if (width <= 0) {
          break;
        }
        pos += width;
        count++;
      }
      if (count < atom.min) {
        failed = true;
        break;
      }
      for (const capture of pattern.captures)
        if (capture.endAtom === atomIndex + 1) ends[capture.group] = pos;
    }

    if (!failed && (!pattern.anchoredEnd || pos === matchEnd)) {
      starts[0] = start;
      ends[0] = pos;
      const groups = starts.map((groupStart, group) => input.slice(groupStart, ends[group]!));
      return { groups };
    }
    if (pattern.anchoredStart) break;
  }
  return null;
}

function parseEscape(
  source: string,
  i: number,
  end: number,
): { atom: Omit<Atom, "min" | "max">; next: number } {
  if (i + 1 >= end) fail("dangling escape");
  const escaped = source[i + 1]!;
  if ((escaped >= "1" && escaped <= "9") || escaped === "k") fail("backreferences are not supported");
  if (escaped === "d" || escaped === "w" || escaped === "s") {
    const kind = escaped === "d" ? "digit" : escaped === "w" ? "word" : "space";
    return { atom: { kind: "set", set: { kind } }, next: i + 2 };
  }
  const control = escaped === "n" ? 10 : escaped === "r" ? 13 : escaped === "t" ? 9 : null;
  if (control !== null) return { atom: { kind: "literal", value: control }, next: i + 2 };
  if (!"\\.()[]{}+*?^$-/".includes(escaped)) fail(`unsupported escape \\${escaped}`);
  return { atom: { kind: "literal", value: source.charCodeAt(i + 1) }, next: i + 2 };
}

function parseClass(
  source: string,
  start: number,
  end: number,
): { atom: Omit<Atom, "min" | "max">; next: number } {
  let i = start + 1;
  let negated = false;
  if (source[i] === "^") {
    negated = true;
    i++;
  }
  const ranges: Array<readonly [number, number]> = [];
  let hasItem = false;
  while (i < end && source[i] !== "]") {
    const left = parseClassLiteral(source, i, end);
    i = left.next;
    hasItem = true;
    if (i < end && source[i] === "-" && i + 1 < end && source[i + 1] !== "]") {
      const right = parseClassLiteral(source, i + 1, end);
      if (left.code > right.code) fail("character class range is reversed");
      ranges.push([left.code, right.code]);
      i = right.next;
    } else {
      ranges.push([left.code, left.code]);
    }
  }
  if (!hasItem || i >= end || source[i] !== "]") fail("unclosed or empty character class");
  return { atom: { kind: "set", set: { kind: "class", negated, ranges } }, next: i + 1 };
}

function parseClassLiteral(source: string, i: number, end: number): { code: number; next: number } {
  if (source[i] === "\\") {
    if (i + 1 >= end) fail("dangling escape in character class");
    if ("dws".includes(source[i + 1]!))
      fail("ASCII shorthand classes cannot be range endpoints or class members");
    const escaped = source[i + 1]!;
    const control = escaped === "n" ? 10 : escaped === "r" ? 13 : escaped === "t" ? 9 : null;
    if (control !== null) return { code: control, next: i + 2 };
    if (!"\\]-^/".includes(escaped)) fail(`unsupported character class escape \\${escaped}`);
    return { code: source.charCodeAt(i + 1), next: i + 2 };
  }
  const code = source.charCodeAt(i);
  if (isSurrogate(code)) fail("non-BMP characters are not supported inside character classes");
  return { code, next: i + 1 };
}

function parseQuantifier(
  source: string,
  i: number,
  end: number,
): { min: number; max: number | null; next: number } {
  if (i >= end) return { min: 1, max: 1, next: i };
  const c = source[i]!;
  if (c === "?" || c === "*" || c === "+") {
    if (source[i + 1] === "?") fail("lazy quantifiers are not supported");
    return c === "?"
      ? { min: 0, max: 1, next: i + 1 }
      : c === "*"
        ? { min: 0, max: null, next: i + 1 }
        : { min: 1, max: null, next: i + 1 };
  }
  if (c !== "{") return { min: 1, max: 1, next: i };
  const close = source.indexOf("}", i + 1);
  if (close < 0 || close >= end) fail("invalid repeat quantifier");
  const body = source.slice(i + 1, close);
  let min: number;
  let max: number | null;
  const comma = body.indexOf(",");
  if (comma < 0) {
    min = parseRepeatNumber(body);
    max = min;
  } else {
    if (body.indexOf(",", comma + 1) >= 0) fail("invalid repeat quantifier");
    min = parseRepeatNumber(body.slice(0, comma));
    max = body.slice(comma + 1) === "" ? null : parseRepeatNumber(body.slice(comma + 1));
    if (max !== null && min > max) fail("repeat quantifier minimum exceeds maximum");
  }
  if (source[close + 1] === "?") fail("lazy quantifiers are not supported");
  return { min, max, next: close + 1 };
}

function parseRepeatNumber(value: string): number {
  if (value === "" || !asciiDigits(value)) fail("invalid repeat quantifier");
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number > MAX_EXACT_REPEAT) {
    fail(`repeat bound exceeds ${MAX_EXACT_REPEAT}`);
  }
  return number;
}

function asciiDigits(value: string): boolean {
  for (let i = 0; i < value.length; i++)
    if (value.charCodeAt(i) < 48 || value.charCodeAt(i) > 57) return false;
  return true;
}

function isQuantifierStart(c: string): boolean {
  return c === "?" || c === "*" || c === "+" || c === "{";
}

function isEscaped(source: string, index: number): boolean {
  let slashes = 0;
  for (let i = index - 1; i >= 0 && source[i] === "\\"; i--) slashes++;
  return slashes % 2 === 1;
}

function atomMatchWidth(atom: Atom, input: string, pos: number): number {
  const code = input.charCodeAt(pos);
  if (atom.kind === "dot") {
    if (code === 10 || code === 13 || code === 0x2028 || code === 0x2029) return 0;
    if (isHighSurrogate(code)) {
      return pos + 1 < input.length && isLowSurrogate(input.charCodeAt(pos + 1)) ? 2 : 0;
    }
    return isLowSurrogate(code) ? 0 : 1;
  }
  if (atom.kind === "literal") return code === atom.value ? 1 : 0;
  if (isSurrogate(code)) return 0;
  const set = atom.set!;
  if (set.kind === "digit") return code >= 48 && code <= 57 ? 1 : 0;
  if (set.kind === "word")
    return (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      code === 95 ||
      (code >= 97 && code <= 122)
      ? 1
      : 0;
  if (set.kind === "space") return code === 32 || (code >= 9 && code <= 13) ? 1 : 0;
  const included = set.ranges.some(([low, high]) => code >= low && code <= high);
  return (set.negated ? !included : included) ? 1 : 0;
}

function atomCanMatchLineTerminator(atom: Atom): boolean {
  return [10, 13, 0x2028, 0x2029].some((code) => atomMatchWidth(atom, String.fromCharCode(code), 0) > 0);
}

function assertWellFormedUtf16(value: string): void {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (isHighSurrogate(code)) {
      if (i + 1 >= value.length || !isLowSurrogate(value.charCodeAt(i + 1)))
        fail("pattern contains an unpaired surrogate");
      i++;
    } else if (isLowSurrogate(code)) {
      fail("pattern contains an unpaired surrogate");
    }
  }
}

function endAnchorOffset(value: string): number {
  if (value.length === 0) return 0;
  const last = value.charCodeAt(value.length - 1);
  if (last === 10 && value.length > 1 && value.charCodeAt(value.length - 2) === 13) return value.length - 2;
  return last === 10 || last === 13 || last === 0x2028 || last === 0x2029 ? value.length - 1 : value.length;
}

function finalLineStart(value: string, end: number): number {
  for (let i = end - 1; i >= 0; i--) {
    const code = value.charCodeAt(i);
    if (code === 10 || code === 13 || code === 0x2028 || code === 0x2029) return i + 1;
  }
  return 0;
}

function isSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdfff;
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

function isLowSurrogate(code: number): boolean {
  return code >= 0xdc00 && code <= 0xdfff;
}
