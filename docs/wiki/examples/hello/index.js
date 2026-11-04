export const capabilities = {
  async "generic.section"(ctx, params = {}) {
    const section = params.section ?? "welcome";
    if (section !== "welcome") throw new Error("unsupported_section");
    return {
      sectionId: "welcome",
      title: "开发示例（合成数据）",
      fields: [
        { label: "状态", role: "status", value: "脚本已运行" },
        { label: "示例数量", role: "quantity", value: 1 }
      ]
    };
  }
};
