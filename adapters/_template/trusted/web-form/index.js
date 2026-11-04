// Page HTML is inert: all control flow runs here in background QuickJS.
// Never put a protocol, password or a generic native bridge into the document.
export const capabilities = {
  "web.content": async (ctx, { pageId }) => {
    if (pageId !== "draft") throw new Error("undeclared_page");
    await ctx.browser.openContent(pageId);
    const submitted = await ctx.browser.content({
      operation: "waitForEvent",
      selector: "#submit",
      event: "click",
      timeoutMs: 60000,
    });
    if (!submitted) return { pageId, status: "cancelled" };
    const subject = await ctx.browser.content({ operation: "getValue", selector: "#subject" });
    // The page is not trusted validation. School code must validate each input.
    if (typeof subject !== "string" || !subject.trim() || subject.length > 120) {
      await ctx.browser.content({
        operation: "setText",
        selector: "#result",
        value: "No valid draft was submitted.",
      });
      return { pageId, status: "cancelled" };
    }
    // A real service would call ctx.fetch once here, then verify its response.
    // If a submission may have happened but cannot be verified, return unknown.
    await ctx.browser.content({
      operation: "setText",
      selector: "#result",
      value: `Local draft accepted: ${subject}`,
    });
    await ctx.browser.content({ operation: "setDisabled", selector: "#close", value: false });
    await ctx.browser.content({
      operation: "waitForEvent",
      selector: "#close",
      event: "click",
      timeoutMs: 30000,
    });
    return { pageId, status: "completed" };
  },
};
