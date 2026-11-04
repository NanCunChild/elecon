/// ADR-081: JS author facade, independent of native execution lifecycle.
library;

import 'dart:convert';

import 'host_protocol.dart';
import 'localization.dart';
import 'web_api.dart';

String scriptRuntimeBootstrap({
  required String capability,
  required int sdkVersion,
  required String packageId,
  required String paramsJson,
  required String? locale,
  required ScriptLocalization? localization,
  required bool browser,
  required bool browserBusy,
  required bool webContent,
  required bool input,
  required bool accounts,
  required bool websocket,
  required bool scanner,
  required bool deviceInputs,
  required bool appTunnel,
  required int maxOutputBytes,
}) =>
    '''
(() => {
  const invokeHost = async (name, ...args) => {
    const envelope = JSON.parse(await globalThis[name](...args));
    if (!envelope || envelope.ok !== true) {
      const code = envelope && envelope.error && envelope.error.code || 'host_failed';
      const error = new Error(code);
      error.code = code;
      error.category = envelope && envelope.error && envelope.error.category || 'internal';
      throw error;
    }
    return envelope.value;
  };
  // flutter_qjs_next 1.2.1 _jsToDart omits STRING_ROPE. QuickJS String()
  // linearizes rope strings; preserve every non-string's type for host checks.
  // ADR-034 execution bridge fix, without changing the SDK or output contract.
  const flat = value => typeof value === 'string' ? String(value) : value;
  const flatFields = value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) return value;
    return Object.fromEntries(Object.keys(value).map(key => [key,flat(value[key])]));
  };
  const hostCredentials = (method,key,value,options) => {
    options = flatFields(options || {});
    if (options && Array.isArray(options.scope)) options.scope = options.scope.map(flat);
    return invokeHost('__script_credentials',method,flat(key),flat(value),options).then(JSON.parse);
  };
  const ctx = {
    now: () => Date.now(),
    log: (level,message) => globalThis.__script_log(level,String(message)),
    credentials: Object.freeze({
      get: (key,options) => hostCredentials('get',key,null,options),
      list: () => hostCredentials('list',null,null,{}),
      set: (key,value,options) => hostCredentials('set',key,value,options),
      delete: (key,options) => hostCredentials('delete',key,null,options),
    }),
    fetch: async (url,init) => {
      init = flatFields(init || {});
      if (init && init.headers) init.headers = flatFields(init.headers);
      if ($deviceInputs && init && init.body != null && typeof init.body !== 'string' && !(init.body instanceof Uint8Array)) throw new Error('invalid_fetch');
      if ($deviceInputs && init && init.body instanceof Uint8Array) {
        if (init.body.byteLength > 1048576) throw new Error('request_body_limit');
        init.body = Array.from(init.body);
      }
      let r;
      try { r = await invokeHost('__script_fetch',String(url),init); }
      catch (error) {
        // Legacy fetch exposed native rejection text without a code property.
        // Keep its terminal classification while SDK17 uses structured codes.
        ${sdkVersion < 17 ? 'delete error.code;' : ''}
        throw error;
      }
      const raw = r.headers || {};
      const find = name => {
        const key = Object.keys(raw).find(k => k.toLowerCase() === String(name).toLowerCase());
        return key === undefined ? [] : (Array.isArray(raw[key]) ? raw[key].map(String) : [String(raw[key])]);
      };
      const headers = Object.freeze({
        get: name => { const v = find(name); return v.length ? v.join(', ') : null; },
        getSetCookie: () => find('set-cookie'),
        raw: () => JSON.parse(JSON.stringify(raw)),
      });
      const text = () => {
        if (r.textAvailable === false) throw new Error('unsupported_encoding');
        return r.body === undefined ? '' : r.body;
      };
      return Object.freeze({status:r.status,ok:r.status>=200 && r.status<300,url:r.url,headers,
        text:async()=>text(),json:async()=>JSON.parse(text()),
        bytes:async()=>new Uint8Array(r.bodyBytes || []),
        arrayBuffer:async()=>(new Uint8Array(r.bodyBytes || [])).buffer});
    },
  };
  ${_localizationBootstrap(locale, localization)}
  if ($accounts) {
    const call = async (method, account, options) => JSON.parse(await invokeHost('__script_accounts',method,flat(account),String(JSON.stringify(options))));
    ctx.accounts = Object.freeze({
      password: (account, options) => call('password', account, options),
      completePassword: (account, options) => call('completePassword', account, options),
      report: (account, event) => call('report', account, event),
    });
  }
  if ($appTunnel) {
    const call = async (method,provider,options={}) => JSON.parse(await invokeHost('__script_app_tunnel',method,flat(provider),String(JSON.stringify(options))));
    ctx.appTunnel = Object.freeze({status: provider => call('status',provider), login: (provider,options) => call('login',provider,options)});
  }
  if ($websocket) {
    const call = async (method,args) => JSON.parse(await invokeHost('__script_websocket',method,String(JSON.stringify(args))));
    ctx.websocket = Object.freeze({
      open: url => call('open',{url}),
      send: bytes => call('send',{bytes:bytes instanceof Uint8Array ? Array.from(bytes) : bytes}),
      receive: async (timeoutMs=1000) => { const bytes = await call('receive',{timeoutMs}); return bytes === null ? null : new Uint8Array(bytes); },
      close: () => call('close',{}),
    });
  }
  if ($input) {
    ctx.ui = {requestInput: async request => JSON.parse(await invokeHost('__script_input',String(JSON.stringify(request))))};
    if ($scanner) ctx.ui.scanQRCode = async (...args) => JSON.parse(await invokeHost('__script_scan',args.length));
    if ($deviceInputs) {
      const deviceInput = async (kind,args) => {
        const result = JSON.parse(await invokeHost('__script_device_input',kind,args.length));
        if (result && result.bytes) result.bytes = new Uint8Array(result.bytes);
        return result;
      };
      ctx.ui.capturePhoto = (...args) => deviceInput('camera',args);
      ctx.ui.pickImage = (...args) => deviceInput('image',args);
      ctx.ui.getCurrentPosition = (...args) => deviceInput('location',args);
    }
    Object.freeze(ctx.ui);
  }
  if ($browser) {
    const call = async (method,args) => {
      try { return JSON.parse(await invokeHost('__script_browser',method,flatFields(args))); }
      catch (error) {
        if (error.code === 'browser_navigation_blocked') error.code = 'network_denied';
        throw error;
      }
    };
    ctx.browser = Object.freeze({
      ${browserBusy ? "setBusy: busy => call('setBusy',{busy})," : ''}
      open: url => call('open',{url:String(url)}),
      ${webContent ? "openContent: id => call('openContent',{id:String(id)}), content: request => call('content',request)," : ''}
      evaluate: (source,...args) => call('evaluate',{
        source:typeof source === 'function' ? '(' + String(source) + ').apply(null,' + JSON.stringify(args) + ')' : String(source)
      }),
      text: selector => call('text',{selector:String(selector)}),
      exists: selector => call('exists',{selector:String(selector)}),
      queryAll: (selector,limit=100) => call('queryAll',{selector:String(selector),limit}),
      waitFor: (selector,timeout=10000) => call('waitFor',{selector:String(selector),timeout}),
      cookies: url => call('cookies',url === undefined ? {} : {url:String(url)}),
      setCookies: async (url,cookies) => { await call('setCookies',{url:String(url),cookies:Array.isArray(cookies) ? cookies.map(flatFields) : cookies}); },
    });
  }
  ${sdkVersion >= 17 ? _sdk17Bootstrap(packageId) : ''}
  Object.freeze(ctx);
  globalThis.__scriptInvoke = async () => {
  const caps = globalThis.__scriptCaps;
  if (!caps || typeof caps !== 'object' || typeof caps[${jsonEncode(capability)}] !== 'function') {
    return JSON.stringify({ok:false,error:{code:'capability_missing'}});
  }
  // Build JSON ourselves: JSON.stringify silently drops unsupported values and
  // invokes toJSON. Strict output never repairs missing/NaN/class values.
  let nodes = 0;
  const seen = new Set();
  const max = $maxOutputBytes;
  const encode = (value,depth) => {
    if (++nodes > 100000 || depth > 64) throw new Error('output_limit');
    let text;
    if (value === null) return 'null';
    if (typeof value === 'string' || typeof value === 'boolean') text = JSON.stringify(value);
    else if (typeof value === 'number' && Number.isFinite(value)) text = String(value);
    else if (typeof value === 'object') {
      if (seen.has(value)) throw new Error('non_json_output');
      seen.add(value);
      if (Array.isArray(value)) {
        const parts = [];
        for(let i=0;i<value.length;i++) parts.push(encode(value[i],depth+1));
        text = '['+parts.join(',')+']';
      } else {
        const proto = Object.getPrototypeOf(value);
        if (proto !== Object.prototype && proto !== null) throw new Error('non_json_output');
        if (Object.getOwnPropertySymbols(value).length) throw new Error('non_json_output');
        text = '{'+Object.keys(value).map(key=>JSON.stringify(key)+':'+encode(value[key],depth+1)).join(',')+'}';
      }
      seen.delete(value);
    } else throw new Error('non_json_output');
    if (text.length > max) throw new Error('output_limit');
    return text;
  };
  try {
    const result = await caps[${jsonEncode(capability)}](Object.freeze(ctx),JSON.parse(${jsonEncode(paramsJson)}));
    return String('{"ok":true,"data":'+encode(result,0)+'}');
  } catch(e) {
    // Useful diagnostics go through the same bounded secret/URL sanitizer as
    // ctx.log; the result channel continues to expose stable codes only.
    try {
      const message = String(e && e.message || e);
      const stack = String(e && e.stack || '');
      globalThis.__script_log('error',String((message + '\\n' + stack).slice(0,4096)));
    } catch (_) {}
    // ADR-034 §6: only a fixed vocabulary may cross the error result channel.
    // A script can classify a failure without exposing its message or data.
    const safeCodes = new Set(['input_required_card_number','input_required_student_id',
      'browser_unavailable','browser_content_unavailable','browser_content_undeclared',
      'browser_content_invalid_operation','browser_content_evaluate_forbidden',
      'browser_content_remote_forbidden','browser_content_cookies_forbidden','browser_content_not_open',
      'account_password_unavailable','account_not_declared','account_invalid_request','account_manual_login_required','account_interactive_fallback',
      'account_silent_unavailable','account_recovery_blocked','account_attempt_limit','account_attempt_invalid',
      'account_invalid_input','account_invalid_event','account_event_limit','account_storage_invalid','account_storage_failed',
      'authentication_required','authentication_timeout','source_response_invalid','network_denied',
      'configuration_required','app_tunnel_unavailable','localization_invalid_key','localization_invalid_arguments',
      'input_invalid_request','input_invalid_result','input_unavailable','input_busy','input_limit','input_cancelled',
      'device_input_unavailable','device_input_permission_denied','device_input_invalid_request',
      'device_input_invalid_result','device_input_busy','device_input_limit','device_input_timeout','invocation_cancelled']);
    ${sdkVersion >= 17 ? 'for (const code of ${jsonEncode(scriptHostErrorCodes.toList())}) safeCodes.add(code);' : ''}
    const code = ${sdkVersion >= 17} && e instanceof Error && e.name === 'AbortError'
      ? 'invocation_cancelled'
      : e && (e.message === 'non_json_output' || e.message === 'output_limit' || e.message === 'unsupported_encoding')
        ? e.message : e && safeCodes.has(e.code) ? e.code : 'adapter_failed';
    if (${sdkVersion >= 17} && e && e.code === 'script_business_error' && typeof e.businessCode === 'string') {
      return JSON.stringify({ok:false,error:{code:'script_business_error',businessCode:e.businessCode}});
    }
    return JSON.stringify({ok:false,error:{code}});
  }
  };
})()
''';

/// Package strings are parsed as data, never interpolated into executable JS.
String _localizationBootstrap(
  String? locale,
  ScriptLocalization? localization,
) {
  if (locale == null) return '';
  final prefix = 'ctx.locale = ${jsonEncode(locale)};';
  if (localization == null) return prefix;
  final selected = localization.resolveLocale(locale);
  final messages = {
    ...localization.messages[localization.defaultLocale]!,
    ...localization.messages[selected]!,
  };
  return '''
$prefix
(() => {
  const messages = JSON.parse(${jsonEncode(jsonEncode(messages))});
  const own = (value,key) => Object.prototype.hasOwnProperty.call(value,key);
  const fail = code => { const error = new Error(code); error.code = code; throw error; };
  ctx.i18n = Object.freeze({
    locale: ${jsonEncode(selected)},
    supportedLocales: Object.freeze(JSON.parse(${jsonEncode(jsonEncode(localization.supportedLocales))})),
    t: (key,values={}) => {
      if (typeof key !== 'string' || !own(messages,key)) fail('localization_invalid_key');
      if (!values || typeof values !== 'object' || Array.isArray(values) ||
          ![Object.prototype,null].includes(Object.getPrototypeOf(values)) ||
          Object.getOwnPropertySymbols(values).length) fail('localization_invalid_arguments');
      const message = messages[key];
      const pattern = /\\{([A-Za-z][A-Za-z0-9_]{0,63})\\}/g;
      const expected = new Set(Array.from(message.matchAll(pattern), match => match[1]));
      const keys = Object.getOwnPropertyNames(values);
      if (keys.length !== expected.size || keys.some(name => !expected.has(name)))
        fail('localization_invalid_arguments');
      const resolved = Object.create(null);
      for (const name of expected) {
        const descriptor = Object.getOwnPropertyDescriptor(values,name);
        if (!descriptor || !own(descriptor,'value')) fail('localization_invalid_arguments');
        const value = descriptor.value;
        if ((typeof value !== 'string' && !(typeof value === 'number' && Number.isFinite(value))) ||
            String(value).length > 4096) fail('localization_invalid_arguments');
        resolved[name] = String(value);
      }
      const result = message.replace(pattern, (_,name) => resolved[name]);
      if (result.length > 65536) fail('localization_invalid_arguments');
      return result;
    },
  });
})();
''';
}

// SDK17 confines project-specific APIs to one namespace. The same object is
// still passed to handlers, so existing ctx-style functions need no adapter.
String _sdk17Bootstrap(String packageId) =>
    '''
  ctx.errors = Object.freeze({create: localCode => {
    if (typeof localCode !== 'string' || !/^[a-z][a-z0-9_]{0,63}\$/.test(localCode)) {
      throw new TypeError('invalid_business_code');
    }
    const error = new Error('script_business_error');
    error.name = 'EleconError';
    error.code = 'script_business_error';
    error.businessCode = ${jsonEncode(packageId)} + ':' + localCode;
    return error;
  }});
  $scriptWebApiBootstrap
  Object.defineProperty(globalThis, 'elecon', {value: ctx, writable: false, configurable: false});
''';
