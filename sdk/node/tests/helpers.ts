import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

export class MockUDSServer {
  path: string;
  private server: net.Server;
  private response: Record<string, unknown> | null = null;
  private lastReq: Record<string, unknown> | null = null;
  private clientConn: net.Socket | null = null;

  constructor() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zb-test-"));
    this.path = path.join(dir, "test.sock");
    this.server = net.createServer((conn) => {
      this.clientConn = conn;
      let buffer = Buffer.alloc(0);
      conn.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 4) {
          const length = buffer.readUInt32BE(0);
          if (buffer.length < 4 + length) break;
          const data = buffer.subarray(4, 4 + length);
          buffer = buffer.subarray(4 + length);
          this.lastReq = JSON.parse(data.toString("utf-8"));
          if (this.response) {
            const resp = { ...this.response, id: this.lastReq!.id };
            const respData = Buffer.from(JSON.stringify(resp), "utf-8");
            const header = Buffer.alloc(4);
            header.writeUInt32BE(respData.length);
            conn.write(Buffer.concat([header, respData]));
          }
        }
      });
    });
  }

  setResponse(response: Record<string, unknown>) {
    this.response = response;
  }

  lastRequest(): Record<string, unknown> {
    if (!this.lastReq) throw new Error("No request received");
    return this.lastReq;
  }

  pushNotification(notification: Record<string, unknown>) {
    if (this.clientConn) {
      const data = Buffer.from(JSON.stringify(notification), "utf-8");
      const header = Buffer.alloc(4);
      header.writeUInt32BE(data.length);
      this.clientConn.write(Buffer.concat([header, data]));
    }
  }

  async start(): Promise<void> {
    return new Promise((resolve) => {
      this.server.listen(this.path, () => resolve());
    });
  }

  async close(): Promise<void> {
    return new Promise((resolve) => {
      if (this.clientConn) this.clientConn.destroy();
      this.server.close(() => {
        try {
          fs.unlinkSync(this.path);
          fs.rmdirSync(path.dirname(this.path));
        } catch {}
        resolve();
      });
    });
  }
}

export async function createMockServer(): Promise<MockUDSServer> {
  const server = new MockUDSServer();
  await server.start();
  return server;
}
