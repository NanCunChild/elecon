/**
 * 🔒 Adapter 源码静态策略闸门（红线 #5；ADR-018 §2.8/§2.10）。
 *
 * 源真相必须留在核心仓；公开 adapter 仓只消费镜像。此检查是纵深防御，不能替代
 * declarative runtime 不提供网络/凭证能力的硬隔离或人工安全审查。
 */

import ts from "typescript";

export interface AdapterPolicyManifest {
  capabilities: Array<{ id: string; requestGraph: string }>;
}

export class AdapterPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AdapterPolicyError";
  }
}

const ALLOWED_MODULE = "elecon:html";
const FORBIDDEN_NAMES = new Set([
  "fetch",
  "setEphemeralCookie",
  "credentials",
  "eval",
  "Function",
  "globalThis",
  "arguments",
  "process",
  "require",
  "self",
  "window",
  "XMLHttpRequest",
  "WebSocket",
]);
const FORBIDDEN_ESCAPE_PROPERTIES = new Set(["constructor", "prototype", "__proto__"]);

function fail(adapterId: string, detail: string): never {
  throw new AdapterPolicyError(`${adapterId}: ${detail}`);
}

function propertyName(node: ts.PropertyName): string | null {
  if (ts.isIdentifier(node) || ts.isStringLiteral(node) || ts.isNumericLiteral(node)) {
    return node.text;
  }
  return null;
}

function exportedCapabilitiesObject(
  sourceFile: ts.SourceFile,
  adapterId: string,
): ts.ObjectLiteralExpression {
  const matches: ts.ObjectLiteralExpression[] = [];
  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) continue;
    if (!statement.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword)) continue;
    for (const declaration of statement.declarationList.declarations) {
      if (
        ts.isIdentifier(declaration.name) &&
        declaration.name.text === "capabilities" &&
        declaration.initializer &&
        ts.isObjectLiteralExpression(declaration.initializer)
      ) {
        matches.push(declaration.initializer);
      }
    }
  }
  if (matches.length !== 1) {
    fail(adapterId, "必须且只能直接导出一个对象字面量 `capabilities`（fail-closed）");
  }
  return matches[0]!;
}

function capabilityValues(
  object: ts.ObjectLiteralExpression,
  adapterId: string,
): Map<string, ts.Expression | ts.MethodDeclaration> {
  const values = new Map<string, ts.Expression | ts.MethodDeclaration>();
  for (const property of object.properties) {
    if (ts.isPropertyAssignment(property)) {
      const name = propertyName(property.name);
      if (name === null) fail(adapterId, "capabilities 不允许计算属性名（fail-closed）");
      if (values.has(name)) fail(adapterId, `capability '${name}' 重复声明`);
      values.set(name, property.initializer);
      continue;
    }
    if (ts.isMethodDeclaration(property)) {
      const name = propertyName(property.name);
      if (name === null) fail(adapterId, "capabilities 不允许计算方法名（fail-closed）");
      if (values.has(name)) fail(adapterId, `capability '${name}' 重复声明`);
      values.set(name, property);
      continue;
    }
    fail(adapterId, "capabilities 只允许显式属性或方法，不允许 spread/shorthand/accessor（fail-closed）");
  }
  return values;
}

function bindingNames(name: ts.BindingName): string[] {
  if (ts.isIdentifier(name)) return [name.text];
  return name.elements.flatMap((element) =>
    ts.isOmittedExpression(element) ? [] : bindingNames(element.name),
  );
}

function topLevelDefinitions(sourceFile: ts.SourceFile): Map<string, ts.Node> {
  const definitions = new Map<string, ts.Node>();
  for (const statement of sourceFile.statements) {
    if ((ts.isFunctionDeclaration(statement) || ts.isClassDeclaration(statement)) && statement.name) {
      definitions.set(statement.name.text, statement);
      continue;
    }
    if (ts.isVariableStatement(statement)) {
      for (const declaration of statement.declarationList.declarations) {
        for (const name of bindingNames(declaration.name)) definitions.set(name, statement);
      }
    }
  }
  return definitions;
}

function assertModulePolicy(sourceFile: ts.SourceFile, adapterId: string): void {
  const checkSpecifier = (specifier: ts.Expression | undefined, kind: string): void => {
    if (!specifier || !ts.isStringLiteral(specifier) || specifier.text !== ALLOWED_MODULE) {
      const shown = specifier && ts.isStringLiteral(specifier) ? specifier.text : "动态表达式";
      fail(adapterId, `${kind} '${shown}' 不在允许白名单（仅 ${ALLOWED_MODULE}）`);
    }
  };

  const visit = (node: ts.Node): void => {
    if (ts.isImportDeclaration(node)) checkSpecifier(node.moduleSpecifier, "import");
    if (ts.isExportDeclaration(node) && node.moduleSpecifier) {
      checkSpecifier(node.moduleSpecifier, "re-export");
    }
    if (ts.isImportEqualsDeclaration(node)) {
      fail(adapterId, "不允许 import-equals/require 模块加载");
    }
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
      fail(adapterId, "不允许动态 import（即使参数是字面量）");
    }
    ts.forEachChild(node, visit);
  };
  visit(sourceFile);
}

function assertTopLevelShape(sourceFile: ts.SourceFile, adapterId: string): void {
  for (const statement of sourceFile.statements) {
    if (
      ts.isImportDeclaration(statement) ||
      ts.isExportDeclaration(statement) ||
      ts.isFunctionDeclaration(statement) ||
      ts.isEmptyStatement(statement)
    ) {
      continue;
    }
    if (ts.isClassDeclaration(statement)) {
      if (statement.members.some(ts.isClassStaticBlockDeclaration)) {
        fail(adapterId, "顶层 class 不允许 static block（模块加载副作用）");
      }
      continue;
    }
    if (ts.isVariableStatement(statement)) {
      if (!(statement.declarationList.flags & ts.NodeFlags.Const)) {
        fail(adapterId, "顶层变量必须使用 const，禁止可变绑定绕过可达性分析");
      }
      for (const declaration of statement.declarationList.declarations) {
        if (!declaration.initializer) continue;
        const visitInitializer = (node: ts.Node): void => {
          if (ts.isFunctionLike(node) || ts.isClassExpression(node)) {
            return;
          }
          if (
            ts.isCallExpression(node) ||
            ts.isNewExpression(node) ||
            ts.isAwaitExpression(node) ||
            ts.isTaggedTemplateExpression(node)
          ) {
            fail(adapterId, "顶层 const 初始化不允许执行调用/new/await/tagged template（模块加载副作用）");
          }
          ts.forEachChild(node, visitInitializer);
        };
        visitInitializer(declaration.initializer);
      }
      continue;
    }
    fail(adapterId, `不允许顶层 ${ts.SyntaxKind[statement.kind]}（模块加载副作用）`);
  }
}

function referencedTopLevelNames(node: ts.Node, definitions: Map<string, ts.Node>): Set<string> {
  const names = new Set<string>();
  const visit = (child: ts.Node): void => {
    if (ts.isIdentifier(child) && definitions.has(child.text)) names.add(child.text);
    ts.forEachChild(child, visit);
  };
  visit(node);
  return names;
}

function resolveCapabilityFunction(
  value: ts.Expression | ts.MethodDeclaration,
  definitions: Map<string, ts.Node>,
): ts.FunctionLikeDeclaration | null {
  if (ts.isArrowFunction(value) || ts.isFunctionExpression(value) || ts.isMethodDeclaration(value)) {
    return value;
  }
  if (!ts.isIdentifier(value)) return null;
  const definition = definitions.get(value.text);
  if (definition && ts.isFunctionDeclaration(definition)) return definition;
  if (definition && ts.isVariableStatement(definition)) {
    for (const declaration of definition.declarationList.declarations) {
      if (
        ts.isIdentifier(declaration.name) &&
        declaration.name.text === value.text &&
        declaration.initializer &&
        (ts.isArrowFunction(declaration.initializer) || ts.isFunctionExpression(declaration.initializer))
      ) {
        return declaration.initializer;
      }
    }
  }
  return null;
}

function assertDeclarativeReachablePolicy(
  adapterId: string,
  capabilityId: string,
  seed: ts.Expression | ts.MethodDeclaration,
  definitions: Map<string, ts.Node>,
): void {
  const capabilityFunction = resolveCapabilityFunction(seed, definitions);
  if (!capabilityFunction) {
    fail(adapterId, `declarative capability '${capabilityId}' 必须是静态可解析的函数（fail-closed）`);
  }

  const firstParameter = capabilityFunction.parameters[0];
  if (firstParameter && !ts.isIdentifier(firstParameter.name)) {
    fail(adapterId, `declarative capability '${capabilityId}' 不允许解构 ctx 参数`);
  }
  const contextName =
    firstParameter && ts.isIdentifier(firstParameter.name) ? firstParameter.name.text : null;
  const contextDeclaration = firstParameter?.name;

  const queue: ts.Node[] = [seed];
  const reachable = new Set<ts.Node>();
  while (queue.length > 0) {
    const node = queue.pop()!;
    if (reachable.has(node)) continue;
    reachable.add(node);
    for (const name of referencedTopLevelNames(node, definitions)) {
      const definition = definitions.get(name);
      if (definition && !reachable.has(definition)) queue.push(definition);
    }
  }

  const visit = (node: ts.Node): void => {
    if (node.kind === ts.SyntaxKind.ThisKeyword) {
      fail(adapterId, `declarative capability '${capabilityId}' 不允许使用 this`);
    }
    if (ts.isIdentifier(node)) {
      if (FORBIDDEN_NAMES.has(node.text)) {
        fail(adapterId, `declarative capability '${capabilityId}' 可达代码包含禁用标识符 '${node.text}'`);
      }
      if (contextName !== null && node.text === contextName && node !== contextDeclaration) {
        fail(adapterId, `declarative capability '${capabilityId}' 不允许读取 ctx（网络/凭证能力必须不可达）`);
      }
    }
    if (ts.isPropertyAccessExpression(node) && FORBIDDEN_ESCAPE_PROPERTIES.has(node.name.text)) {
      fail(adapterId, `declarative capability '${capabilityId}' 不允许访问 '${node.name.text}' 逃逸属性`);
    }
    if (
      ts.isElementAccessExpression(node) &&
      node.argumentExpression &&
      ts.isStringLiteral(node.argumentExpression) &&
      (FORBIDDEN_NAMES.has(node.argumentExpression.text) ||
        FORBIDDEN_ESCAPE_PROPERTIES.has(node.argumentExpression.text))
    ) {
      fail(
        adapterId,
        `declarative capability '${capabilityId}' 不允许访问 '${node.argumentExpression.text}'`,
      );
    }
    ts.forEachChild(node, visit);
  };
  for (const node of reachable) visit(node);
}

/** 对一个 adapter 入口源码执行 import 与逐 declarative capability 静态策略检查。 */
export function checkAdapterSourcePolicy(
  adapterId: string,
  source: string,
  manifest: AdapterPolicyManifest,
): void {
  const sourceFile = ts.createSourceFile(
    `${adapterId}/index.js`,
    source,
    ts.ScriptTarget.ES2022,
    true,
    ts.ScriptKind.JS,
  );
  const diagnostics = (sourceFile as ts.SourceFile & { parseDiagnostics?: readonly ts.Diagnostic[] })
    .parseDiagnostics;
  if (diagnostics && diagnostics.length > 0) {
    fail(
      adapterId,
      `JavaScript 语法错误：${ts.flattenDiagnosticMessageText(diagnostics[0]!.messageText, " ")}`,
    );
  }

  assertModulePolicy(sourceFile, adapterId);
  assertTopLevelShape(sourceFile, adapterId);
  const capabilities = capabilityValues(exportedCapabilitiesObject(sourceFile, adapterId), adapterId);
  const definitions = topLevelDefinitions(sourceFile);
  for (const capability of manifest.capabilities) {
    if (capability.requestGraph !== "declarative") continue;
    const value = capabilities.get(capability.id);
    if (!value) {
      fail(adapterId, `declarative capability '${capability.id}' 未在源码 capabilities 中找到`);
    }
    assertDeclarativeReachablePolicy(adapterId, capability.id, value, definitions);
  }
}
