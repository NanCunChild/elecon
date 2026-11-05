import type { ScriptContext, ScriptHandlers } from '../types.js';

// A synthetic generic.section query; the host must explicitly open a scope.
// No timer runs during preload or in an ordinary one-shot invocation.
export const capabilities = {
  'generic.section': async (ctx: ScriptContext) => {
    if (ctx.execution) {
      await ctx.execution.state.set('counter', { count: 0 });
      await ctx.execution.register({ id: 'refresh', handler: 'refresh', stateKey: 'counter' });
      await ctx.execution.schedule('refresh', ctx.now() + 10_000);
    }
    return { sectionId: 'example', title: 'Started' };
  },
};

export const handlers: ScriptHandlers = {
  refresh: async ctx => {
    const execution = ctx.execution!;
    const state = await execution.state.get(execution.stateKey!) as { count: number };
    await execution.state.set(execution.stateKey!, { count: state.count + 1 });
    await execution.schedule('refresh', ctx.now() + 10_000);
    return { sectionId: 'example', title: String(state.count + 1) };
  },
};
