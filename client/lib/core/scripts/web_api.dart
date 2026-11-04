/// SDK17's buffered Web API subset, evaluated once per invocation after ctx.
/// Uses the existing authorized transport; no network/native permissions added.
/// No streams, Blob/FormData, URL parser, browser cookie jar, CORS or cache mode.
/// Abort rejects locally and discards late results; it does not recall a sent
/// request. Host invocation cancellation remains authoritative for native I/O.
const scriptWebApiBootstrap = r'''
((transport) => {
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const unsupported = name => { throw new TypeError('Unsupported Web API option: ' + name); };
  const options = (value, allowed) => {
    if (value == null) return {};
    if (typeof value !== 'object') throw new TypeError('Expected options');
    for (const key of Object.keys(value)) if (!allowed.includes(key)) unsupported(key);
    return value;
  };
  // Buffered UTF-8 codec: replaces unpaired surrogates and malformed sequences.
  const encode = value => {
    const result = [];
    for (let c of String(value)) {
      let n = c.codePointAt(0);
      if (n >= 0xd800 && n <= 0xdfff) n = 0xfffd;
      if (n < 0x80) result.push(n);
      else if (n < 0x800) result.push(0xc0 | n >> 6, 0x80 | n & 63);
      else if (n < 0x10000) result.push(0xe0 | n >> 12, 0x80 | n >> 6 & 63, 0x80 | n & 63);
      else result.push(0xf0 | n >> 18, 0x80 | n >> 12 & 63, 0x80 | n >> 6 & 63, 0x80 | n & 63);
    }
    return new Uint8Array(result);
  };
  const decode = bytes => {
    const result = [];
    let i = bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf ? 3 : 0;
    while (i < bytes.length) {
      const a = bytes[i++];
      if (a < 0x80) { result.push(String.fromCharCode(a)); continue; }
      let count = a >= 0xc2 && a <= 0xdf ? 1 : a >= 0xe0 && a <= 0xef ? 2 : a >= 0xf0 && a <= 0xf4 ? 3 : 0;
      if (!count) { result.push('\ufffd'); continue; }
      let n = a & (count === 1 ? 31 : count === 2 ? 15 : 7), valid = true;
      for (let j = 0; j < count; j++) {
        const b = bytes[i];
        const low = j === 0 && a === 0xe0 ? 0xa0 : j === 0 && a === 0xf0 ? 0x90 : 0x80;
        const high = j === 0 && a === 0xed ? 0x9f : j === 0 && a === 0xf4 ? 0x8f : 0xbf;
        if (b === undefined || b < low || b > high) { valid = false; break; }
        i++; n = (n << 6) | (b & 63);
      }
      result.push(valid ? String.fromCodePoint(n) : '\ufffd');
    }
    return result.join('');
  };
  const headerState = new WeakMap();
  const nameOf = value => {
    const name = String(value);
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name)) throw new TypeError('Invalid header name');
    return name.toLowerCase();
  };
  const valueOf = value => {
    const text = String(value).replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, '');
    if (/[\0\r\n]/.test(text) || Array.from(text).some(c => c.charCodeAt(0) > 255)) throw new TypeError('Invalid header value');
    return text;
  };
  class Headers {
    constructor(init) {
      headerState.set(this, {values: new Map(), immutable: false});
      if (init == null) return;
      if (typeof init[Symbol.iterator] === 'function') {
        for (const entry of init) {
          const pair = Array.from(entry);
          if (pair.length !== 2) throw new TypeError('Expected header pair');
          this.append(pair[0], pair[1]);
        }
      } else if (typeof init === 'object') {
        for (const key of Object.keys(init)) this.append(key, init[key]);
      } else throw new TypeError('Invalid headers');
    }
    append(name, value) {
      name = nameOf(name); value = valueOf(value);
      const state = headerState.get(this);
      if (state.immutable) throw new TypeError('Immutable headers');
      state.values.set(name, [...(state.values.get(name) || []), value]);
    }
    set(name, value) {
      name = nameOf(name); value = valueOf(value);
      const state = headerState.get(this);
      if (state.immutable) throw new TypeError('Immutable headers');
      state.values.set(name, [value]);
    }
    delete(name) {
      name = nameOf(name);
      const state = headerState.get(this);
      if (state.immutable) throw new TypeError('Immutable headers');
      state.values.delete(name);
    }
    get(name) { return headerState.get(this).values.get(nameOf(name))?.join(', ') ?? null; }
    has(name) { return headerState.get(this).values.has(nameOf(name)); }
    getSetCookie() { return [...(headerState.get(this).values.get('set-cookie') || [])]; }
    *entries() {
      const values = headerState.get(this).values;
      // Web IDL iterators read the current sorted list at each index. Rebuild
      // after yielding so deletion, insertion and value changes remain live.
      for (let index = 0; ; index++) {
        const entries = [];
        for (const key of [...values.keys()].sort()) {
          if (key === 'set-cookie') for (const value of values.get(key)) entries.push([key, value]);
          else entries.push([key, values.get(key).join(', ')]);
        }
        if (index >= entries.length) return;
        yield entries[index];
      }
    }
    *keys() { for (const [key] of this.entries()) yield key; }
    *values() { for (const [,value] of this.entries()) yield value; }
    [Symbol.iterator]() { return this.entries(); }
    forEach(callback, thisArg) { for (const [key,value] of this) callback.call(thisArg,value,key,this); }
  }
  const signalState = new WeakMap(), controllerState = new WeakMap(), signalToken = {};
  const abortError = () => { const error = new Error('The operation was aborted'); error.name = 'AbortError'; return error; };
  class AbortSignal {
    constructor(token) {
      if (token !== signalToken) throw new TypeError('Illegal constructor');
      signalState.set(this, {aborted:false, reason:undefined, listeners:[], onabort:null});
    }
    get aborted() { return signalState.get(this).aborted; }
    get reason() { return signalState.get(this).reason; }
    get onabort() { return signalState.get(this).onabort; }
    set onabort(value) { signalState.get(this).onabort = typeof value === 'function' ? value : null; }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    addEventListener(type, callback, settings = {}) {
      if (String(type) !== 'abort' || callback == null) return;
      settings ??= {};
      if (typeof callback !== 'function' && typeof callback.handleEvent !== 'function') throw new TypeError('Invalid event listener');
      const state = signalState.get(this);
      const capture = typeof settings === 'boolean' ? settings : !!settings.capture;
      if (!state.listeners.some(x => x.callback === callback && x.capture === capture)) state.listeners.push({callback,capture,once:!!settings.once});
    }
    removeEventListener(type, callback, settings = {}) {
      if (String(type) !== 'abort') return;
      settings ??= {};
      const state = signalState.get(this), capture = typeof settings === 'boolean' ? settings : !!settings.capture;
      state.listeners = state.listeners.filter(x => x.callback !== callback || x.capture !== capture);
    }
    static abort(reason) { const controller = new AbortController(); controller.abort(reason); return controller.signal; }
  }
  class AbortController {
    constructor() { controllerState.set(this,new AbortSignal(signalToken)); }
    get signal() { return controllerState.get(this); }
    abort(reason) {
      const signal = this.signal, state = signalState.get(signal);
      if (state.aborted) return;
      state.aborted = true; state.reason = reason === undefined ? abortError() : reason;
      const event = Object.freeze({type:'abort',target:signal,currentTarget:signal});
      const notify = callback => {
        try { if (typeof callback === 'function') callback.call(signal,event); else callback.handleEvent(event); }
        catch (_) { /* A listener failure must not prevent fetch cancellation. */ }
      };
      for (const listener of [...state.listeners]) {
        if (!state.listeners.includes(listener)) continue;
        if (listener.once) signal.removeEventListener('abort',listener.callback,listener.capture);
        notify(listener.callback);
      }
      if (state.onabort) notify(state.onabort);
    }
  }
  const bodyState = new WeakMap(), requestState = new WeakMap(), responseState = new WeakMap();
  const bodyBytes = value => {
    if (value == null) return null;
    if (typeof value === 'string') return encode(value);
    if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength));
    throw new TypeError('Supported body types: string, ArrayBuffer, ArrayBufferView');
  };
  const initBody = (object, body, signal) => bodyState.set(object,{bytes:bodyBytes(body),used:false,signal});
  const copyBody = object => {
    const state = bodyState.get(object);
    if (state.used) throw new TypeError('Body already consumed');
    return state.bytes?.slice() ?? null;
  };
  const consume = object => {
    const state = bodyState.get(object);
    state.signal?.throwIfAborted();
    if (state.used) throw new TypeError('Body already consumed');
    if (state.bytes !== null) state.used = true;
    return state.bytes?.slice() ?? new Uint8Array();
  };
  class Body {
    get bodyUsed() { return bodyState.get(this).used; }
    async bytes() { return consume(this); }
    async arrayBuffer() { return consume(this).buffer; }
    async text() { return decode(consume(this)); }
    async json() { return JSON.parse(await this.text()); }
  }
  class Request extends Body {
    constructor(input, init) {
      super();
      init = options(init,['method','headers','body','redirect','signal']);
      const prior = input instanceof Request ? requestState.get(input) : null;
      // URL parsing and declaration enforcement belong to the host transport.
      // This subset accepts absolute HTTP(S) strings; no relative URL base.
      const url = prior ? prior.url : String(input);
      if (!/^https?:\/\//i.test(url)) throw new TypeError('Expected absolute HTTP(S) URL');
      const rawMethod = String(init.method ?? prior?.method ?? 'GET');
      if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(rawMethod) || ['CONNECT','TRACE','TRACK'].includes(rawMethod.toUpperCase())) throw new TypeError('Invalid method');
      const method = ['DELETE','GET','HEAD','OPTIONS','POST','PUT'].includes(rawMethod.toUpperCase()) ? rawMethod.toUpperCase() : rawMethod;
      const headers = new Headers(init.headers ?? prior?.headers);
      const redirect = init.redirect ?? prior?.redirect ?? 'follow';
      if (!['follow','manual','error'].includes(redirect)) throw new TypeError('Invalid redirect');
      const signal = own(init,'signal') ? init.signal : prior?.signal;
      if (signal != null && !(signal instanceof AbortSignal)) throw new TypeError('Invalid AbortSignal');
      const body = init.body != null ? init.body : prior ? copyBody(input) : null;
      if (body != null && (method === 'GET' || method === 'HEAD')) throw new TypeError('GET/HEAD cannot have a body');
      if (typeof body === 'string' && !headers.has('content-type')) headers.set('content-type','text/plain;charset=UTF-8');
      initBody(this,body);
      requestState.set(this,{url,method,headers,redirect,signal:signal ?? new AbortController().signal});
      if (prior && init.body == null && body !== null) bodyState.get(input).used = true;
    }
    get url() { return requestState.get(this).url; }
    get method() { return requestState.get(this).method; }
    get headers() { return requestState.get(this).headers; }
    get redirect() { return requestState.get(this).redirect; }
    get signal() { return requestState.get(this).signal; }
    clone() { return new Request(this.url,{method:this.method,headers:this.headers,body:copyBody(this),redirect:this.redirect,signal:this.signal}); }
  }
  class Response extends Body {
    constructor(body = null, init) {
      super(); init = options(init,['status','statusText','headers']);
      const status = init.status ?? 200, statusText = String(init.statusText ?? '');
      if (!Number.isInteger(status) || status < 200 || status > 599) throw new RangeError('Invalid response status');
      if (/[^\t\x20-\x7e\x80-\xff]/.test(statusText)) throw new TypeError('Invalid status text');
      if (body != null && [204,205,304].includes(status)) throw new TypeError('Status cannot have a body');
      const headers = new Headers(init.headers);
      if (typeof body === 'string' && !headers.has('content-type')) headers.set('content-type','text/plain;charset=UTF-8');
      initBody(this,body);
      responseState.set(this,{status,statusText,headers,url:'',type:'default'});
    }
    get status() { return responseState.get(this).status; }
    get statusText() { return responseState.get(this).statusText; }
    get ok() { return this.status >= 200 && this.status < 300; }
    get headers() { return responseState.get(this).headers; }
    get url() { return responseState.get(this).url; }
    get type() { return responseState.get(this).type; }
    clone() {
      const copy = new Response(copyBody(this),{status:this.status,statusText:this.statusText,headers:this.headers});
      Object.assign(responseState.get(copy),{url:this.url,type:this.type});
      bodyState.get(copy).signal = bodyState.get(this).signal;
      headerState.get(copy.headers).immutable = headerState.get(this.headers).immutable;
      return copy;
    }
    static json(value, init = {}) {
      const text = JSON.stringify(value);
      if (text === undefined) throw new TypeError('Value is not JSON serializable');
      const headers = new Headers(init.headers);
      if (!headers.has('content-type')) headers.set('content-type','application/json');
      return new Response(text,{...init,headers});
    }
  }
  const fetch = async (input, init) => {
    const request = new Request(input,init), signal = request.signal;
    signal.throwIfAborted();
    const body = bodyState.get(request).bytes === null ? null : consume(request);
    const headers = Object.fromEntries(request.headers);
    return new Promise((resolve,reject) => {
      let settled = false;
      const finish = (fn,value) => {
        if (settled) return;
        settled = true; signal.removeEventListener('abort',aborted); fn(value);
      };
      const aborted = () => finish(reject,signal.reason);
      signal.addEventListener('abort',aborted,{once:true});
      Promise.resolve().then(() => {
        signal.throwIfAborted();
        return transport(request.url,{method:request.method,headers,redirect:request.redirect,...(body === null ? {} : {body})});
      }).then(async result => {
        if (settled) return;
        const bytes = await result.bytes();
        signal.throwIfAborted();
        const pairs = [];
        for (const [key,values] of Object.entries(result.headers.raw())) for (const value of values) pairs.push([key,value]);
        const response = new Response(request.method === 'HEAD' || [204,205,304].includes(result.status) ? null : bytes,{status:result.status,headers:pairs});
        Object.assign(responseState.get(response),{url:result.url,type:'basic'});
        bodyState.get(response).signal = signal;
        headerState.get(response.headers).immutable = true;
        finish(resolve,response);
      }).catch(error => finish(reject,error));
    });
  };
  for (const [name,value] of Object.entries({Headers,Request,Response,AbortController,AbortSignal,fetch})) {
    Object.defineProperty(globalThis,name,{value,writable:false,configurable:false});
  }
})(ctx.fetch);
''';
