// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class AppAnnouncement {
  const AppAnnouncement({
    this.version,
    this.items,
  });

  final String? version;
  final List<AppAnnouncementItems>? items;
}

class AppAnnouncementItems {
  const AppAnnouncementItems({
    this.title,
    this.content,
    this.publishedAt,
    this.privacyUrl,
  });

  final String? title;
  final String? content;
  final String? publishedAt;
  final String? privacyUrl;
}
