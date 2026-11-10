/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-057: fixed phases and booleans only; never IDs, names, URLs or bodies.
export function chatProbe(ctx, stage, event, http = 0, flags = []) {
  try {
    const bits = Array.from({ length: 8 }, (_, i) =>
      flags[i] === true ? "1" : flags[i] === false ? "0" : "?",
    ).join("");
    const status = Number.isInteger(http) && http >= 100 && http <= 599 ? http : 0;
    ctx.log?.("info", `probe/1 stage=${stage} event=${event} http=${status} ms=0 flags=${bits}`);
  } catch {
    // Diagnostics cannot change optional metadata or authentication behavior.
  }
}

export function chatContext(ctx) {
  return {
    ...ctx,
    fetch: async (url, init) => {
      const stage = url.includes("/getUserImToken")
        ? 17
        : url.includes("joined_chatgroups") || url.includes("contacts/users")
          ? 18
          : url.includes("/getUsers4C")
            ? 22
            : url.startsWith("https://photo.chaoxing.com/") ||
                url.startsWith("https://p.ananas.chaoxing.com/") ||
                url.startsWith("https://p.cldisk.com/")
              ? 23
              : url.includes("/chatgroups/") && /\/admin(?:\?|$)/.test(url)
                ? 20
                : url.includes("/chatgroups/") && /\/users(?:\?|$)/.test(url)
                  ? 21
                  : url.includes("/chatgroups/")
                    ? 19
                    : null;
      try {
        const response = await ctx.fetch(url, init);
        if (stage) chatProbe(ctx, stage, response.ok ? "ok" : "failed", response.status);
        return response;
      } catch (error) {
        if (stage) chatProbe(ctx, stage, "failed");
        throw error;
      }
    },
  };
}
