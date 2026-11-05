/// No callback serialization: SDK19 sends only names, storage keys and times.
const scriptExecutionBootstrap = r'''
  const executionCall = (method, value) => {
    const seen = new Set();
    const encode = (v, depth) => {
      if (depth > 33) throw new Error('execution_invalid_request');
      if (v === null || typeof v === 'string' || typeof v === 'boolean') return JSON.stringify(v);
      if (typeof v === 'number' && Number.isFinite(v)) return String(v);
      if (typeof v !== 'object' || seen.has(v)) throw new Error('execution_invalid_request');
      const proto = Object.getPrototypeOf(v);
      if (!Array.isArray(v) && proto !== Object.prototype && proto !== null) throw new Error('execution_invalid_request');
      if (Object.getOwnPropertySymbols(v).length) throw new Error('execution_invalid_request');
      seen.add(v);
      const parts = [];
      if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) {
          const d = Object.getOwnPropertyDescriptor(v, String(i));
          if (!d || !('value' in d)) throw new Error('execution_invalid_request');
          parts.push(encode(d.value, depth + 1));
        }
      } else {
        for (const k of Object.keys(v)) {
          const d = Object.getOwnPropertyDescriptor(v, k);
          if (!d || !('value' in d)) throw new Error('execution_invalid_request');
          parts.push(JSON.stringify(k) + ':' + encode(d.value, depth + 1));
        }
      }
      seen.delete(v);
      const text = Array.isArray(v) ? '[' + parts.join(',') + ']' : '{' + parts.join(',') + '}';
      if (text.length > 131072) throw new Error('execution_invalid_request');
      return text;
    };
    let encoded;
    try { encoded = encode(value, 0); }
    catch (_) { const e = new Error('execution_invalid_request'); e.code = 'execution_invalid_request'; throw e; }
    return invokeHost('__script_execution', method, String(encoded));
  };
  ctx.execution = Object.freeze({
    stateKey: executionContext.stateKey,
    trigger: executionContext.trigger,
    state: Object.freeze({
      get: key => executionCall('get', {key}),
      set: (key, value) => executionCall('set', {key, value}),
      delete: key => executionCall('delete', {key}),
    }),
    register: value => {
      if (!value || typeof value.handler !== 'string' ||
          !Object.prototype.hasOwnProperty.call(globalThis.__scriptHandlers || {}, value.handler) ||
          typeof globalThis.__scriptHandlers[value.handler] !== 'function') {
        const e = new Error('execution_handler_missing'); e.code = 'execution_handler_missing'; throw e;
      }
      return executionCall('register', value);
    },
    unregister: id => executionCall('unregister', {id}),
    schedule: (id, at) => executionCall('schedule', {id, at}),
    cancel: id => executionCall('cancel', {id}),
  });
''';
