// Compile-time checks (tsc, tests/tsconfig.types.json; run by
// methods.test.ts): what a flow call's promise resolves to, by `dryRun`.
import type { ZigBrowser } from "../src/client.js";
import type { DryRunResult, OkResult, SchedulePostResult, StoryViewResult } from "../src/methods.js";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
function expectType<A, B>(_: Equal<A, B>): void {}

declare const zb: ZigBrowser;
declare const flag: boolean;
declare const opts: { dryRun?: boolean };

// Absent or false: the real result.
expectType<Awaited<ReturnType<typeof zb.x.post>>, OkResult | DryRunResult>(true);
const plain = zb.linkedin.follow("u");
expectType<Awaited<typeof plain>, OkResult>(true);
const off = zb.linkedin.connect("u", { note: "n", dryRun: false });
expectType<Awaited<typeof off>, OkResult>(true);
const none = zb.instagram.storyView("u", {});
expectType<Awaited<typeof none>, StoryViewResult>(true);
// Literal true: the dry-run result.
const dry = zb.x.schedulePost("t", "2026-11-05", "14:07", { dryRun: true });
expectType<Awaited<typeof dry>, DryRunResult>(true);
// A runtime boolean, or an optional one: either.
const either = zb.x.post("t", { dryRun: flag });
expectType<Awaited<typeof either>, OkResult | DryRunResult>(true);
const maybe = zb.instagram.like("u", opts);
expectType<Awaited<typeof maybe>, OkResult | DryRunResult>(true);
const sched = zb.x.schedulePost("t", "2026-11-05", "14:07", { dryRun: flag });
expectType<Awaited<typeof sched>, SchedulePostResult | DryRunResult>(true);
// A union where one branch has no dryRun (RoseCat 5102): either.
declare const choice: { dryRun: true } | {};
const mixed = zb.x.post("t", choice);
expectType<Awaited<typeof mixed>, OkResult | DryRunResult>(true);
declare const offOrOn: { dryRun: false } | { dryRun: true; composeUrl: string };
const both = zb.x.post("t", offOrOn);
expectType<Awaited<typeof both>, OkResult | DryRunResult>(true);
