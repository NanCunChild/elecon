/**
 * 🔒 Linux native PIN entry through the pinentry Assuan protocol.
 *
 * The PIN is entered by the desktop pinentry UI and travels only through the
 * child process pipe. It is never placed in argv, environment variables, or
 * release logs. This is an input provider, not a key store: YubiKey touch
 * remains the separate physical approval gate.
 */

import { spawn } from "node:child_process";

function assuanEscape(value: string): string {
  return value.replace(/%/g, "%25").replace(/\n/g, "%0A").replace(/\r/g, "%0D");
}

export function assuanDecode(value: string): string {
  return value.replace(/%([0-9A-Fa-f]{2})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)));
}

export interface PinentryOptions {
  command?: string;
  description?: string;
  prompt?: string;
  timeoutMs?: number;
}

/** Obtain a PIN using the Linux desktop pinentry selected by the system wrapper. */
export class PinentryPinProvider {
  readonly #command: string;
  readonly #description: string;
  readonly #prompt: string;
  readonly #timeoutMs: number;

  constructor(options: PinentryOptions = {}) {
    this.#command = options.command ?? "pinentry";
    this.#description = options.description ?? "输入 YubiKey PIV PIN 以批准一次 Elecon release 签名";
    this.#prompt = options.prompt ?? "YubiKey PIV PIN: ";
    this.#timeoutMs = options.timeoutMs ?? 120_000;
  }

  async getPin(): Promise<string> {
    const child = spawn(this.#command, [], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });

    return new Promise<string>((resolve, reject) => {
      let buffer = "";
      let phase = 0;
      let pin: string | undefined;
      let finished = false;
      const timer = setTimeout(() => {
        finish(new Error("pinentry 超时，未取得 PIN"));
        child.kill();
      }, this.#timeoutMs);

      const finish = (error?: Error): void => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (error) {
          pin = undefined;
          reject(error);
        } else if (pin === undefined || pin.length === 0) {
          reject(new Error("pinentry 返回空 PIN（fail-closed）"));
        } else {
          resolve(pin);
        }
      };

      const send = (command: string): void => {
        if (finished || child.stdin.destroyed) return;
        try {
          child.stdin.write(`${command}\n`);
        } catch (error) {
          finish(error instanceof Error ? error : new Error(String(error)));
        }
      };

      const handleLine = (line: string): void => {
        if (line.startsWith("ERR ")) {
          finish(new Error(`pinentry 拒绝 PIN：${line}`));
          child.kill();
          return;
        }
        if (line.startsWith("D ")) {
          pin = assuanDecode(line.slice(2));
          return;
        }
        if (!line.startsWith("OK")) return;

        // Assuan commands must be sent one at a time: each command's OK is
        // the permission to send the next command. GETPIN returns D <pin>
        // followed by OK.
        switch (phase) {
          case 0:
            phase = 1;
            send(`SETDESC ${assuanEscape(this.#description)}`);
            break;
          case 1:
            phase = 2;
            send(`SETPROMPT ${assuanEscape(this.#prompt)}`);
            break;
          case 2:
            phase = 3;
            send("GETPIN");
            break;
          case 3:
            send("BYE");
            finish();
            break;
        }
      };

      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        buffer += chunk;
        for (;;) {
          const newline = buffer.indexOf("\n");
          if (newline < 0) break;
          const line = buffer.slice(0, newline).replace(/\r$/, "");
          buffer = buffer.slice(newline + 1);
          handleLine(line);
        }
      });
      child.stderr.resume();
      child.stdin.on("error", (error) => finish(error));
      child.on("error", (error) => finish(error));
      child.on("close", (code) => {
        if (!finished) finish(new Error(`pinentry 异常退出：code=${code ?? "unknown"}`));
      });
    });
  }
}
