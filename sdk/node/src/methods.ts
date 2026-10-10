// Typed wrappers for every method the zigBrowser automation server accepts.
// Option names are camelCase here and mapped to the server's wire keys.

export type WaitState = "attached" | "visible" | "hidden" | "detached";
export type Modifier = "Shift" | "Control" | "Alt" | "Meta";
export type SameSite = "Lax" | "Strict" | "None";

export interface OkResult {
  ok: true;
}
export interface ElementSummary {
  id: string;
  tag: string;
  text: string;
  bbox: { x: number; y: number; width: number; height: number };
}
export interface QueryResult {
  elements: ElementSummary[];
}
export interface TextResult {
  text: string;
}
export interface AttributeResult {
  value: string | null;
}
export interface SelectResult {
  value: string;
}
export interface UrlResult {
  url: string;
}
export interface TitleResult {
  title: string;
}
export interface EvaluateResult<T = unknown> {
  result: T;
}
export interface Cookie {
  name: string;
  value: string;
  domain: string;
  path?: string;
  /** Unix seconds; -1 = session cookie. */
  expires?: number;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: SameSite;
}
export interface ImportResult {
  imported: number;
  skipped: number;
}
export interface LoginCheckResult {
  loggedIn: boolean;
  platform: "linkedin" | "instagram" | "unknown";
  username: string | null;
}
export interface RateStatusResult {
  remaining_actions: number;
  reset_at: string;
  daily_cap: number;
}

export interface ActionOptions {
  force?: boolean;
  trial?: boolean;
  strict?: boolean;
  timeoutMs?: number;
}

export type Caller = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/** Drops undefined values so absent options are not sent. */
function wire(params: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

function actionOptions(opts?: ActionOptions): Record<string, unknown> | undefined {
  if (!opts) return undefined;
  const options = wire({ force: opts.force, trial: opts.trial, strict: opts.strict, timeout_ms: opts.timeoutMs });
  return Object.keys(options).length > 0 ? options : undefined;
}

export class DomNamespace {
  constructor(private readonly call: Caller) {}

  query(selector: string, opts: { timeoutMs?: number; strict?: boolean } = {}): Promise<QueryResult> {
    return this.call("dom.query", wire({ selector, timeout_ms: opts.timeoutMs, strict: opts.strict })) as Promise<QueryResult>;
  }
  click(selector: string, opts?: ActionOptions): Promise<OkResult> {
    return this.call("dom.click", wire({ selector, options: actionOptions(opts) })) as Promise<OkResult>;
  }
  fill(selector: string, value: string, opts?: ActionOptions): Promise<OkResult> {
    return this.call("dom.fill", wire({ selector, value, options: actionOptions(opts) })) as Promise<OkResult>;
  }
  type(selector: string, text: string, opts: ActionOptions & { delayMs?: number } = {}): Promise<OkResult> {
    return this.call("dom.type", wire({ selector, text, delay_ms: opts.delayMs, options: actionOptions({ ...opts }) })) as Promise<OkResult>;
  }
  getText(selector: string, opts: { timeoutMs?: number; strict?: boolean } = {}): Promise<TextResult> {
    return this.call("dom.getText", wire({ selector, timeout_ms: opts.timeoutMs, strict: opts.strict })) as Promise<TextResult>;
  }
  getAttribute(selector: string, name: string, opts: { timeoutMs?: number; strict?: boolean } = {}): Promise<AttributeResult> {
    return this.call("dom.getAttribute", wire({ selector, name, timeout_ms: opts.timeoutMs, strict: opts.strict })) as Promise<AttributeResult>;
  }
  waitFor(selector: string, opts: { state?: WaitState; timeoutMs?: number; strict?: boolean } = {}): Promise<OkResult> {
    return this.call("dom.waitFor", wire({ selector, state: opts.state, timeout_ms: opts.timeoutMs, strict: opts.strict })) as Promise<OkResult>;
  }
  /** Press one key (KeyboardEvent.key). No selector = focused element. */
  press(key: string, opts: { selector?: string; modifiers?: Modifier[]; timeoutMs?: number } = {}): Promise<OkResult> {
    return this.call("dom.press", wire({ key, selector: opts.selector, modifiers: opts.modifiers, timeout_ms: opts.timeoutMs })) as Promise<OkResult>;
  }
  /** Select by exactly one of value, label or index. */
  async selectOption(
    selector: string,
    choice: ({ value: string } | { label: string } | { index: number }) & { timeoutMs?: number },
  ): Promise<SelectResult> {
    const c = choice as { value?: string; label?: string; index?: number; timeoutMs?: number };
    const count = [c.value, c.label, c.index].filter((x) => x !== undefined).length;
    if (count !== 1) throw new Error("selectOption needs exactly one of value, label, index");
    return this.call("dom.selectOption", wire({ selector, value: c.value, label: c.label, index: c.index, timeout_ms: c.timeoutMs })) as Promise<SelectResult>;
  }
}

export class PageNamespace {
  constructor(private readonly call: Caller) {}

  navigate(url: string, opts: { waitUntil?: string; timeoutMs?: number } = {}): Promise<OkResult> {
    return this.call("page.navigate", wire({ url, waitUntil: opts.waitUntil, timeout_ms: opts.timeoutMs })) as Promise<OkResult>;
  }
  reload(opts: { waitUntil?: string; timeoutMs?: number } = {}): Promise<OkResult> {
    return this.call("page.reload", wire({ waitUntil: opts.waitUntil, timeout_ms: opts.timeoutMs })) as Promise<OkResult>;
  }
  url(): Promise<UrlResult> {
    return this.call("page.url", {}) as Promise<UrlResult>;
  }
  title(): Promise<TitleResult> {
    return this.call("page.title", {}) as Promise<TitleResult>;
  }
  evaluate<T = unknown>(expression: string): Promise<EvaluateResult<T>> {
    return this.call("page.evaluate", { expression }) as Promise<EvaluateResult<T>>;
  }
  /** Not supported by the GTK backend yet (answers -32603). */
  screenshot(opts: { fullPage?: boolean } = {}): Promise<{ data: string }> {
    return this.call("page.screenshot", wire({ fullPage: opts.fullPage })) as Promise<{ data: string }>;
  }
}

export class CookiesNamespace {
  constructor(private readonly call: Caller) {}

  /** All cookies, or the ones that would be sent to `url`. */
  getAll(opts: { url?: string } = {}): Promise<{ cookies: Cookie[] }> {
    return this.call("cookies.getAll", wire({ url: opts.url })) as Promise<{ cookies: Cookie[] }>;
  }
  set(cookie: Cookie): Promise<OkResult> {
    return this.call("cookies.set", wire({ ...cookie })) as Promise<OkResult>;
  }
  /** No domain = delete the cookie on every domain. */
  delete(name: string, domain?: string): Promise<OkResult> {
    return this.call("cookies.delete", wire({ name, domain })) as Promise<OkResult>;
  }
  /** Import a cookies.txt ("netscape") or JSON export, read by the browser process. */
  import(path: string, format: "netscape" | "json"): Promise<ImportResult> {
    return this.call("cookies.import", { path, format }) as Promise<ImportResult>;
  }
}

export class SocialNamespace {
  constructor(private readonly call: Caller) {}

  loginCheck(): Promise<LoginCheckResult> {
    return this.call("social.login_check", {}) as Promise<LoginCheckResult>;
  }
  rateStatus(): Promise<RateStatusResult> {
    return this.call("social.rate_status", {}) as Promise<RateStatusResult>;
  }
  /** Holds page commands for durationMs; resolves after the pause. */
  pause(durationMs: number): Promise<OkResult> {
    return this.call("social.pause", { duration_ms: durationMs }) as Promise<OkResult>;
  }
  setPacing(opts: { minDelayMs?: number; maxDelayMs?: number; dailyCap?: number }): Promise<OkResult> {
    return this.call("social.set_pacing", wire({ min_delay_ms: opts.minDelayMs, max_delay_ms: opts.maxDelayMs, daily_cap: opts.dailyCap })) as Promise<OkResult>;
  }
}

export interface XLoginCheckResult {
  loggedIn: boolean;
  platform: "x";
}

export interface SchedulePostResult extends OkResult {
  /** "YYYY-MM-DDTHH:MM", as requested. */
  scheduledFor: string;
}

/**
 * x.com flows. Each call is one command that drives the composer in the
 * current profile (log in first). Posts and scheduled posts are capped at 50
 * per UTC day (-32010, reason "x_daily_cap").
 */
export class XNamespace {
  constructor(private readonly call: Caller) {}

  /** Post `text` (1-280 characters) now. `composeUrl` overrides the page the flow opens. */
  post(text: string, opts: { composeUrl?: string } = {}): Promise<OkResult> {
    return this.call("x.post", wire({ text, compose_url: opts.composeUrl })) as Promise<OkResult>;
  }
  /** Schedule `text` for `date` ("YYYY-MM-DD") at `time` ("HH:MM", 24-hour), X account local time. */
  schedulePost(text: string, date: string, time: string, opts: { composeUrl?: string } = {}): Promise<SchedulePostResult> {
    return this.call("x.schedule_post", wire({ text, date, time, compose_url: opts.composeUrl })) as Promise<SchedulePostResult>;
  }
  /** Whether the composer is on the current page. Does not navigate. */
  loginCheck(): Promise<XLoginCheckResult> {
    return this.call("x.login_check", {}) as Promise<XLoginCheckResult>;
  }
}
