// Synthetic SDK16 template: replace domains and implement school evidence.
export const capabilities = {
  "account.session": async (ctx, params) => {
    if (params.account !== "vpn" || !["login", "status"].includes(params.operation)) {
      const error = new Error("input_invalid_request");
      error.code = error.message;
      throw error;
    }
    return params.operation === "status"
      ? ctx.appTunnel.status("hermes-atrust")
      : ctx.appTunnel.login("hermes-atrust", { accountId: "vpn" });
  },
  "notice.list": async (ctx) => {
    // The host selects the declared tunnel only for this capability. A missing
    // session fails before execution. Never fall back to another network.
    const response = await ctx.fetch("https://service.example.invalid/notices");
    if (!response.ok) {
      const error = new Error("source_response_invalid");
      error.code = error.message;
      throw error;
    }
    return response.json(); // Replace with the school's standard-data normalization.
  },
};
