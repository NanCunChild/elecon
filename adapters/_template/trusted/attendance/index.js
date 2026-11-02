/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */
// ADR-058: a service-neutral example, deliberately disabled until an author
// implements and verifies a real school's requirements, auth and status API.
const configuration = { configured: false, origin: "https://attendance.example.invalid" };
const error = (code) => Object.assign(new Error(code), { code });
const utf8 = (text) =>
  Uint8Array.from(
    encodeURIComponent(String(text)).replace(/%([0-9A-F]{2})/g, (_, hex) =>
      String.fromCharCode(parseInt(hex, 16)),
    ),
    (char) => char.charCodeAt(0),
  );

/** Finite multipart example; field names/filename are host-template constants.
 * No local filename/path, EXIF, photo bytes or coordinates are logged. */
export function multipart(fields, image, boundary) {
  const chunks = [];
  for (const [name, value] of Object.entries(fields)) {
    if (!/^[a-zA-Z][a-zA-Z0-9_]*$/.test(name)) throw error("input_invalid_request");
    chunks.push(utf8(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`));
  }
  if (image) {
    chunks.push(
      utf8(
        `--${boundary}\r\nContent-Disposition: form-data; name="image"; filename="image.png"\r\nContent-Type: image/png\r\n\r\n`,
      ),
    );
    chunks.push(image.bytes);
    chunks.push(utf8("\r\n"));
  }
  chunks.push(utf8(`--${boundary}--\r\n`));
  const length = chunks.reduce((total, value) => total + value.length, 0);
  if (length > 1024 * 1024) throw error("input_invalid_request");
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

export function createAttendanceHandler(config) {
  return async (ctx) => {
    if (!config.configured) throw error("configuration_required");
    // Replace this account key and protocol with the school's explicit login.
    const account = await ctx.credentials.get("attendance-token");
    if (!account) throw error("authentication_required");
    // A real adapter chooses from verified activity requirements. This author
    // template offers a menu to demonstrate each supported native input.
    const input = await ctx.ui.requestInput({
      title: "签到模板 / Check-in template",
      message: "仅演示输入编排；人脸图片不是活体认证。/ An image is not proof of liveness.",
      fields: [
        {
          id: "kind",
          label: "输入类型 / Input",
          type: "select",
          options: [
            { label: "按钮 / Button", value: "button" },
            { label: "二维码 / QR", value: "qr" },
            { label: "拍照 / Photo", value: "photo" },
            { label: "选择本人图片 / Choose your image", value: "face-image" },
            { label: "当前位置 / Current location", value: "location" },
          ],
        },
      ],
    });
    if (!input) return { status: "cancelled" };
    const kind = input.kind;
    if (!["button", "qr", "photo", "face-image", "location"].includes(kind))
      throw error("input_invalid_request");
    const fields = { kind };
    let image;
    if (kind === "qr") {
      const qr = await ctx.ui.scanQRCode();
      if (!qr) return { status: "cancelled" };
      // The school adapter must validate its expected QR origin/path/fields;
      // never fetch an arbitrary URL obtained from a QR code.
      fields.qrText = qr.text;
    } else if (kind === "photo" || kind === "face-image") {
      image = kind === "photo" ? await ctx.ui.capturePhoto() : await ctx.ui.pickImage();
      if (!image) return { status: "cancelled" };
    } else if (kind === "location") {
      const location = await ctx.ui.getCurrentPosition();
      if (!location) return { status: "cancelled" };
      // Explicit WGS84; service-specific conversion belongs in this adapter.
      Object.assign(fields, location);
    }
    const boundary = `elecon-${ctx.now()}`;
    const body = multipart(fields, image, boundary);
    // Sending may succeed even if the response is lost. Never retry this POST.
    let receipt;
    try {
      receipt = await (
        await ctx.fetch(`${config.origin}/checkin`, {
          method: "POST",
          redirect: "error",
          headers: {
            Authorization: `Bearer ${account.value}`,
            "Content-Type": `multipart/form-data; boundary=${boundary}`,
          },
          body,
        })
      ).json();
    } catch {
      return { status: "unknown" };
    }
    if (typeof receipt?.requestId !== "string" || !/^[A-Za-z0-9_-]{1,80}$/.test(receipt.requestId))
      return { status: "unknown" };
    try {
      const observed = await (
        await ctx.fetch(
          `${config.origin}/checkin/status?requestId=${encodeURIComponent(receipt.requestId)}`,
          {
            headers: { Authorization: `Bearer ${account.value}` },
            redirect: "error",
          },
        )
      ).json();
      if (observed.requestId !== receipt.requestId) return { status: "unknown" };
      // HTTP 200, accepted upload and captured evidence do not imply success.
      if (!["confirmed", "already", "ended", "unsupported", "rejected", "unknown"].includes(observed.status))
        return { status: "unknown" };
      return { status: observed.status };
    } catch {
      return { status: "unknown" };
    }
  };
}
export const capabilities = { "attendance.checkin": createAttendanceHandler(configuration) };
