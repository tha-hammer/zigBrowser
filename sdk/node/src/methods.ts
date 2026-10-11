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

export type InputMode = "synthetic" | "native";
export interface FilesResult {
  /** The input accepts several files. */
  multiple: boolean;
  /** The input fired `change` (choosing the same files again may not). */
  changed: boolean;
}
export interface ScrollResult {
  scrollX: number;
  scrollY: number;
}
export interface ScreenshotResult {
  /** Base64 PNG. */
  data: string;
  width: number;
  height: number;
}

export interface PageInfo {
  /** "window-<n>" */
  window_id: string;
  url: string;
  title: string;
  primary: boolean;
  /** The window whose page opened this one (a popup). */
  opener_window_id?: string;
  /** Present when the window's web process died since its last page load:
   *  its page is gone and the window shows nothing until it loads again. */
  crashed?: "crashed" | "memory_limit" | "terminated_by_api";
}

export interface PageHealth {
  /** "window-<n>" */
  window_id: string;
  url: string;
  /** False once WebKit has found the window's web process unresponsive for
   *  `debounce_ms` without a break (a suspicion: a long busy script looks
   *  the same). */
  responsive: boolean;
  /** How long WebKit has said unresponsive without a break (0 if not). */
  unresponsive_ms: number;
  loading: boolean;
  dialog_open: boolean;
  crashed?: "crashed" | "memory_limit" | "terminated_by_api";
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

/** An `options` object, or undefined when every value is absent. */
function options(values: Record<string, unknown>): Record<string, unknown> | undefined {
  const out = wire(values);
  return Object.keys(out).length > 0 ? out : undefined;
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
  /**
   * Choose files for an <input type=file> through the browser's own file
   * chooser (GTK backend; others answer -32011 "unsupported"). Absolute
   * paths of readable regular files (else -32602 "bad_file"). Never repeat
   * after -32009 "files_unconfirmed" (they were applied once).
   */
  setInputFiles(selector: string, paths: string[], opts: { timeoutMs?: number; strict?: boolean } = {}): Promise<FilesResult> {
    return this.call("dom.setInputFiles", wire({ selector, paths, options: options({ timeout_ms: opts.timeoutMs, strict: opts.strict }) })) as Promise<FilesResult>;
  }
  /**
   * input "synthetic" (default: pointer/mouse events only, no CSS :hover) or
   * "native" (a real pointer move; humanize = a curved, paced path).
   */
  hover(selector: string, opts: { input?: InputMode; humanize?: boolean; timeoutMs?: number; strict?: boolean } = {}): Promise<OkResult> {
    return this.call("dom.hover", wire({ selector, options: options({ input: opts.input, humanize: opts.humanize, timeout_ms: opts.timeoutMs, strict: opts.strict }) })) as Promise<OkResult>;
  }
  /**
   * Scroll an element into view, or the page by x/y CSS px. Native input uses
   * real wheel events and returns once scrolling has finished.
   */
  async scroll(
    target: { selector: string } | { x?: number; y?: number },
    opts: { input?: InputMode; timeoutMs?: number; strict?: boolean } = {},
  ): Promise<ScrollResult> {
    const t = target as { selector?: string; x?: number; y?: number };
    if ((t.selector === undefined) === (t.x === undefined && t.y === undefined)) {
      throw new Error("scroll needs exactly one of selector or x/y");
    }
    return this.call("dom.scroll", wire({ selector: t.selector, x: t.x, y: t.y, options: options({ input: opts.input, timeout_ms: opts.timeoutMs, strict: opts.strict }) })) as Promise<ScrollResult>;
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

  /**
   * onBeforeUnload: what to do if the page asks "Leave site?": "fail" (default:
   * -32013 dialog_open at once, the prompt stays open), "accept" (leave) or
   * "dismiss" (stay: -32008 beforeunload_dismissed).
   */
  navigate(
    url: string,
    opts: { waitUntil?: string; timeoutMs?: number; onBeforeUnload?: "fail" | "accept" | "dismiss" } = {},
  ): Promise<OkResult> {
    return this.call(
      "page.navigate",
      wire({ url, waitUntil: opts.waitUntil, timeout_ms: opts.timeoutMs, onBeforeUnload: opts.onBeforeUnload }),
    ) as Promise<OkResult>;
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
  /**
   * Every open window, primary first. Send `window_id` with a page.* or dom.*
   * call (`zb.call`) to act on another window, e.g. a login popup.
   */
  list(): Promise<{ pages: PageInfo[] }> {
    return this.call("page.list", {}) as Promise<{ pages: PageInfo[] }>;
  }
  /**
   * Every open window's health, primary first. It answers at once even
   * while a window's commands wait on a frozen page. Nothing is killed or
   * reloaded.
   */
  health(): Promise<{ debounce_ms: number; pages: PageHealth[] }> {
    return this.call("page.health", {}) as Promise<{ debounce_ms: number; pages: PageHealth[] }>;
  }
  /** Close a window from page.list (not the primary one). */
  close(windowId: string): Promise<OkResult> {
    return this.call("page.close", { window_id: windowId }) as Promise<OkResult>;
  }
  /** A backend without screenshots answers -32603. */
  screenshot(opts: { fullPage?: boolean; timeoutMs?: number } = {}): Promise<ScreenshotResult> {
    return this.call("page.screenshot", wire({ fullPage: opts.fullPage, timeout_ms: opts.timeoutMs })) as Promise<ScreenshotResult>;
  }
}

export type DialogType = "alert" | "confirm" | "prompt" | "beforeunload";
export type DialogState =
  | { open: false }
  | { open: true; type: DialogType; message: string; window_id: string; default_text?: string };

/**
 * Page dialogs: alert, confirm, prompt and the beforeunload "Leave site?"
 * prompt. A dialog is not answered for you (except a prompt that
 * page.navigate's onBeforeUnload "accept"/"dismiss" answers): it stays open
 * (a person can answer it) until respond() does.
 */
export class DialogNamespace {
  constructor(private readonly call: Caller) {}

  /** That window's dialog, else the first open one (the primary's first). */
  get(opts: { windowId?: string } = {}): Promise<DialogState> {
    return this.call("dialog.get", wire({ window_id: opts.windowId })) as Promise<DialogState>;
  }
  /** accept: OK / Leave, else Cancel / Stay; text answers an accepted prompt. No dialog: -32602 "no_dialog". */
  respond(accept: boolean, opts: { text?: string; windowId?: string } = {}): Promise<OkResult> {
    return this.call("dialog.respond", wire({ accept, text: opts.text, window_id: opts.windowId })) as Promise<OkResult>;
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

/**
 * `dryRun: true` on an acting flow (x.post, x.schedulePost, linkedin.connect/
 * follow/like/comment, instagram.follow/like/comment/storyView): everything
 * up to the committing click, which is only tried (actionability checks, no
 * event). Nothing is typed, clicked, counted or saved. See
 * docs/how-to-automate.md.
 */
export interface DryRunOption {
  dryRun?: boolean;
}

export interface DryRunCheck {
  name: string;
  /** "pass", "not_reached" (needs the committing action first) or "note". */
  result: "pass" | "not_reached" | "note";
  count?: number;
  reason?: string;
}

export interface DryRunResult {
  dry_run: true;
  would_act: string;
  /** What the committing click would act on; the profile owner's name reads "<owner>". Null when there is none (e.g. a one-frame story). */
  target: { tag: string; label: string; box: { x: number; y: number; width: number; height: number } } | null;
  checks: DryRunCheck[];
}

/**
 * The type of `opts.dryRun`, per member of a union (`O extends unknown`
 * distributes); undefined for a member without the key.
 */
type DryRunFlag<O> = O extends unknown ? ("dryRun" extends keyof O ? O[keyof O & "dryRun"] : undefined) : never;

/**
 * What a flow call resolves to: DryRunResult for a literal `dryRun: true`;
 * R when `dryRun` is absent, undefined or `false`; either (R | DryRunResult)
 * when it is a runtime `boolean` or optional.
 */
export type FlowResult<O, R> = [DryRunFlag<O>] extends [true] ? DryRunResult : true extends DryRunFlag<O> ? R | DryRunResult : R;

function dryRun(opts: DryRunOption): Record<string, unknown> | undefined {
  return opts.dryRun ? { dry_run: true } : undefined;
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
  post<O extends { composeUrl?: string } & DryRunOption = {}>(text: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    const o: { composeUrl?: string } & DryRunOption = opts ?? {};
    return this.call("x.post", wire({ text, compose_url: o.composeUrl, options: dryRun(o) })) as Promise<FlowResult<O, OkResult>>;
  }
  /** Schedule `text` for `date` ("YYYY-MM-DD") at `time` ("HH:MM", 24-hour), X account local time. */
  schedulePost<O extends { composeUrl?: string } & DryRunOption = {}>(text: string, date: string, time: string, opts?: O): Promise<FlowResult<O, SchedulePostResult>> {
    const o: { composeUrl?: string } & DryRunOption = opts ?? {};
    return this.call("x.schedule_post", wire({ text, date, time, compose_url: o.composeUrl, options: dryRun(o) })) as Promise<FlowResult<O, SchedulePostResult>>;
  }
  /** Whether the composer is on the current page. Does not navigate. */
  loginCheck(): Promise<XLoginCheckResult> {
    return this.call("x.login_check", {}) as Promise<XLoginCheckResult>;
  }
  /**
   * `{selector_name: count}` for every entry of X's selector table on the
   * current page. Read-only (no navigation, no input, not paced).
   */
  selfcheck(): Promise<Record<string, number>> {
    return this.call("x.selfcheck", {}) as Promise<Record<string, number>>;
  }
}

export type LinkedInSearchType = "people" | "companies" | "jobs" | "content" | "all";

export interface LinkedInSearchResult extends OkResult {
  url: string;
  resultCount: number;
}

export interface LinkedInProfileSummary {
  name: string;
  headline: string | null;
  location: string | null;
}

export interface StoryViewResult extends OkResult {
  framesViewed: number;
}

/**
 * linkedin.com flows. Each call is one command run by the browser: it needs
 * a signed-in profile (the li_at session cookie; otherwise -32011
 * "logged_out" before anything is opened), takes URLs on
 * https://www.linkedin.com only, and actions share the social pacing
 * (social.rateStatus / social.setPacing; -32010 "social_daily_cap").
 */
export class LinkedInNamespace {
  constructor(private readonly call: Caller) {}

  visit(profileUrl: string): Promise<OkResult> {
    return this.call("linkedin.visit", { profileUrl }) as Promise<OkResult>;
  }
  /** A note longer than 300 characters is cut to 300. */
  connect<O extends { note?: string } & DryRunOption = {}>(profileUrl: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    const o: { note?: string } & DryRunOption = opts ?? {};
    return this.call("linkedin.connect", wire({ profileUrl, note: o.note, options: dryRun(o) })) as Promise<FlowResult<O, OkResult>>;
  }
  follow<O extends DryRunOption = {}>(profileUrl: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("linkedin.follow", wire({ profileUrl, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  /** Exactly one of conversationUrl / profileUrl. */
  message(text: string, target: { conversationUrl: string } | { profileUrl: string }): Promise<OkResult> {
    const t = target as { conversationUrl?: string; profileUrl?: string };
    if ((t.conversationUrl === undefined) === (t.profileUrl === undefined)) {
      throw new Error("message needs exactly one of conversationUrl, profileUrl");
    }
    return this.call("linkedin.message", wire({ text, conversationUrl: t.conversationUrl, profileUrl: t.profileUrl })) as Promise<OkResult>;
  }
  like<O extends DryRunOption = {}>(postUrl: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("linkedin.like", wire({ postUrl, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  comment<O extends DryRunOption = {}>(postUrl: string, text: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("linkedin.comment", wire({ postUrl, text, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  search(query: string, opts: { searchType?: LinkedInSearchType } = {}): Promise<LinkedInSearchResult> {
    return this.call("linkedin.search", wire({ query, searchType: opts.searchType })) as Promise<LinkedInSearchResult>;
  }
  /** Read-only profile summary. */
  extract(profileUrl: string): Promise<LinkedInProfileSummary> {
    return this.call("linkedin.extract", { profileUrl }) as Promise<LinkedInProfileSummary>;
  }
  /** `{selector_name: count}` for LinkedIn's selector table on the current page. */
  selfcheck(): Promise<Record<string, number>> {
    return this.call("linkedin.selfcheck", {}) as Promise<Record<string, number>>;
  }
}

/** instagram.com flows; same rules as LinkedInNamespace (sessionid cookie, https://www.instagram.com URLs, shared pacing). */
export class InstagramNamespace {
  constructor(private readonly call: Caller) {}

  follow<O extends DryRunOption = {}>(profileUrl: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("instagram.follow", wire({ profileUrl, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  like<O extends DryRunOption = {}>(postUrl: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("instagram.like", wire({ postUrl, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  comment<O extends DryRunOption = {}>(postUrl: string, text: string, opts?: O): Promise<FlowResult<O, OkResult>> {
    return this.call("instagram.comment", wire({ postUrl, text, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, OkResult>>;
  }
  /** Opens username's profile, presses Message, sends text. */
  dm(username: string, text: string): Promise<OkResult> {
    return this.call("instagram.dm", { username, text }) as Promise<OkResult>;
  }
  /** With `dryRun: true`: opens the story URL as the real flow does, then only tries Next (no frame viewed, Next never clicked). */
  storyView<O extends DryRunOption = {}>(username: string, opts?: O): Promise<FlowResult<O, StoryViewResult>> {
    return this.call("instagram.story_view", wire({ username, options: dryRun(opts ?? {}) })) as Promise<FlowResult<O, StoryViewResult>>;
  }
  /** `{selector_name: count}` for Instagram's selector table on the current page. */
  selfcheck(): Promise<Record<string, number>> {
    return this.call("instagram.selfcheck", {}) as Promise<Record<string, number>>;
  }
}
