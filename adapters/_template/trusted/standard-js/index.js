// SDK17 globals are available while loading this ordinary ES module.
const headers = new Headers({ accept: "application/json" });

export const capabilities = {
  async "notice.list"() {
    const request = new Request("https://school.example/notices", { headers });
    const response = await fetch(request);
    if (!response.ok) throw elecon.errors.create("notices_unavailable");
    const data = await response.json();
    return { items: data.items.map(notice) };
  },
};

// Private helpers need no capability, manifest entry or dedicated syntax.
function notice(item) {
  return { id: String(item.id), title: item.title, source: "Campus", category: "unknown" };
}
