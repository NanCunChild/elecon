// This is a synthetic template. Adjust URLs/selectors to the actual school.
export const capabilities = {
  async "notice.list"(ctx) {
    const base = "https://campus.example.edu";
    const saved = await ctx.credentials.get("browser-cookies");
    if (saved) await ctx.browser.setCookies(base, JSON.parse(saved.value));
    await ctx.browser.open(`${base}/notices`);
    // User can log in and complete a challenge in the visible school page.
    await ctx.browser.waitFor("#notice-list", 30000);
    const cookies = await ctx.browser.cookies(base);
    await ctx.credentials.set("browser-cookies", JSON.stringify(cookies));
    await ctx.credentials.set("session", cookies.map((c) => `${c.name}=${c.value}`).join("; "), {
      type: "cookie",
    });
    const items = await ctx.browser.evaluate(() =>
      Array.from(document.querySelectorAll("#notice-list a")).map((a, index) => ({
        id: String(index),
        title: a.textContent.trim(),
        url: a.href,
        source: "Campus",
        category: "academic",
      })),
    );
    return { items };
  },
};
