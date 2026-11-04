// ADR-070: author-selected package languages, independent of core UI locales.
// No requests, private data or runtime downloads are used by this example.
export const capabilities = {
  async "generic.section"(ctx) {
    return {
      sectionId: "localization.example",
      title: ctx.i18n.t("title"),
      fields: [{ label: ctx.i18n.locale, role: "label", value: ctx.i18n.t("greeting", { name: "Student" }) }],
    };
  },
};
