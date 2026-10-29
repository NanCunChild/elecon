// ADR-034: school-specific flow stays in ordinary JavaScript.
export const capabilities = {
  async "notice.list"(ctx) {
    const session = await ctx.credentials.get("session");
    if (!session) {
      ctx.log("error", "Sign in using the browser script before requesting private notices");
      throw new Error("session_required");
    }
    const response = await ctx.fetch("https://campus.example.edu/api/notices", {
      headers: { Cookie: session.value },
      // Use manual for authentication chains that need intermediate Set-Cookie.
      redirect: "manual",
    });
    if (!response.ok) throw new Error("notice_http_failed");
    const json = await response.json();
    return {
      items: json.items.map((item) => ({
        id: String(item.id),
        title: item.title,
        source: "Campus",
        category: "academic",
      })),
    };
  },
};
