// Synthetic SDK15 template. Replace the source login/status with real school
// protocol and business verification. Never mark a password verified on storage.
export const capabilities = {
  "account.session": async (ctx, params) => {
    if (params.account === "school") {
      // Deliberately unavailable until the school's detection is implemented.
      if (params.operation === "status") return { status: "unknown" };
      const error = new Error("configuration_required");
      error.code = "configuration_required";
      throw error;
    }
    if (params.account !== "vpn" || !["status", "login"].includes(params.operation)) {
      const error = new Error("input_invalid_request");
      error.code = "input_invalid_request";
      throw error;
    }
    if (params.operation === "status") return ctx.appTunnel.status("hermes-atrust");
    // The school author must establish that this gateway/domain uses the source
    // identity. The host independently verifies the target before saving it.
    return ctx.appTunnel.login("hermes-atrust", { accountId: "vpn" });
  },
};
