import fs from "node:fs";
import net from "node:net";
import { AutomationError } from "./errors.js";
import { CookiesNamespace, DomNamespace, PageNamespace, SocialNamespace } from "./methods.js";

type EventCallback = (params: Record<string, unknown>) => void;

export class ZigBrowser {
  private socket: net.Socket | null = null;
  private socketPath: string;
  private idCounter = 0;
  private pendingResolve: ((value: Record<string, unknown>) => void) | null = null;
  private pendingReject: ((reason: Error) => void) | null = null;
  private buffer = Buffer.alloc(0);
  private eventListeners = new Map<string, EventCallback[]>();
  private token: string | undefined;
  private readonly explicitToken: string | undefined;

  readonly dom: DomNamespace;
  readonly page: PageNamespace;
  readonly cookies: CookiesNamespace;
  readonly social: SocialNamespace;

  /** `token`: sent as `auth` on every request (--automation-token-file). */
  constructor(opts: { socketPath: string; token?: string }) {
    this.socketPath = opts.socketPath;
    this.explicitToken = opts.token;
    this.token = opts.token;
    const call = (method: string, params?: Record<string, unknown>) => this.call(method, params);
    this.dom = new DomNamespace(call);
    this.page = new PageNamespace(call);
    this.cookies = new CookiesNamespace(call);
    this.social = new SocialNamespace(call);
  }

  async connect(): Promise<void> {
    // Per-session token the browser writes next to its socket (mode 0600)
    // when no --automation-token-file is used.
    // An explicit token always wins; otherwise re-read the sidecar on every
    // connect, since a restarted browser has a new session token.
    if (this.explicitToken === undefined) {
      this.token = undefined;
      try {
        const sidecar = fs.readFileSync(`${this.socketPath}.token`, "utf-8").trim();
        if (sidecar) this.token = sidecar;
      } catch {
        // no sidecar: unauthenticated server, or an explicit token is required
      }
    }
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection(this.socketPath, () => resolve());
      this.socket.on("error", reject);
      this.socket.on("data", (chunk: Buffer) => this.onData(chunk));
    });
  }

  private onData(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32BE(0);
      if (this.buffer.length < 4 + length) break;
      const data = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.subarray(4 + length);
      const parsed = JSON.parse(data.toString("utf-8"));
      if ("id" in parsed && this.pendingResolve) {
        this.pendingResolve(parsed);
        this.pendingResolve = null;
        this.pendingReject = null;
      } else if ("method" in parsed && !("id" in parsed)) {
        this.dispatchEvent(
          parsed.method as string,
          (parsed.params ?? {}) as Record<string, unknown>,
        );
      }
    }
  }

  async call(
    method: string,
    params?: Record<string, unknown>,
  ): Promise<unknown> {
    if (!this.socket) throw new Error("Not connected");

    const id = ++this.idCounter;
    const request: Record<string, unknown> = { jsonrpc: "2.0", method, params: params ?? {}, id };
    if (this.token) request.auth = this.token;
    const data = Buffer.from(JSON.stringify(request), "utf-8");
    const header = Buffer.alloc(4);
    header.writeUInt32BE(data.length);

    this.socket.write(Buffer.concat([header, data]));

    const response = await new Promise<Record<string, unknown>>(
      (resolve, reject) => {
        this.pendingResolve = resolve;
        this.pendingReject = reject;
        setTimeout(() => {
          if (this.pendingReject === reject) {
            this.pendingResolve = null;
            this.pendingReject = null;
            reject(new Error("Request timeout"));
          }
        }, 30000);
      },
    );

    if ("error" in response) {
      throw AutomationError.fromRpcError(
        response.error as {
          code: number;
          message: string;
          data?: Record<string, unknown>;
        },
      );
    }
    return response.result;
  }

  on(eventType: string, callback: EventCallback): void {
    const list = this.eventListeners.get(eventType) ?? [];
    list.push(callback);
    this.eventListeners.set(eventType, list);
  }

  private dispatchEvent(method: string, params: Record<string, unknown>): void {
    const listeners = this.eventListeners.get(method);
    if (listeners) {
      for (const cb of listeners) {
        cb(params);
      }
    }
  }

  async disconnect(): Promise<void> {
    return new Promise((resolve) => {
      if (this.socket) {
        this.socket.end(() => resolve());
        this.socket = null;
      } else {
        resolve();
      }
    });
  }
}
