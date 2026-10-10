//! N6: routes the social.* methods the SDK sends through src/social.zig with
//! real ports.
//!
//! Routable now (all four of src/social.zig's verbs):
//! - social.login_check: page URL (PagePort.url -> social.detectPlatform) plus
//!   a heuristic in-page login probe (`login_check_body`, automation world).
//! - social.rate_status: the server's RateLimiter (automation/pacing.zig).
//! - social.set_pacing: updates that RateLimiter; partial params merge into
//!   the current config.
//! - social.pause: runs under the page's queue ticket and sleeps duration_ms
//!   in cancellable slices, so later page commands wait behind it (their
//!   queue wait counts against their deadline). Returns {ok:true} after the
//!   pause, or `cancelled` if the server stops meanwhile.
//! Not routable: any other social.* (e.g. social.post) stays -32601.
//! Note: no dom/page command consumes RateLimiter actions yet, so
//! remaining_actions only changes with daily_cap / the UTC day rollover.
const std = @import("std");
const social = @import("../social.zig");
const pacing = @import("pacing.zig");
const engine_mod = @import("engine.zig");
const script_command = @import("script_command.zig");

pub const Verb = social.SocialVerb;

pub fn verbFromMethod(method: []const u8) ?Verb {
    return social.socialVerb(method);
}

/// Heuristic login probe. LinkedIn: global nav "Me" control present and not
/// on a login/checkpoint path. Instagram: ds_user_id cookie. Anything else:
/// not logged in. Returns {ok,value:{logged_in,username}}.
pub const login_check_body =
    \\try {
    \\  const host = location.hostname;
    \\  let loggedIn = false;
    \\  let username = null;
    \\  if (/(^|\.)linkedin\.com$/.test(host)) {
    \\    const nav = document.querySelector('.global-nav__me, .global-nav__me-photo');
    \\    loggedIn = !!nav && !/^\/(login|checkpoint|uas|authwall)/.test(location.pathname);
    \\    const photo = document.querySelector('img.global-nav__me-photo');
    \\    const alt = photo ? (photo.getAttribute('alt') || '').trim() : '';
    \\    username = loggedIn && alt ? alt.slice(0, 128) : null;
    \\  } else if (/(^|\.)instagram\.com$/.test(host)) {
    \\    loggedIn = /(^|;\s*)ds_user_id=/.test(document.cookie);
    \\  }
    \\  return JSON.stringify({ok:true,value:{logged_in:loggedIn,username:username}});
    \\} catch (e) {
    \\  return JSON.stringify({ok:false,error:'script_exception',retryable:false,data:{reason:'script_exception'}});
    \\}
;

const read_timeout_ms: u64 = 10_000;

pub const SocialState = struct {
    lock: std.atomic.Mutex = .unlocked,
    limiter: pacing.RateLimiter,
    clock: engine_mod.Clock,
    /// Actions admitted by `reserve` and not yet committed or released.
    in_flight: u32 = 0,
    /// Tests: seeds the pacing-delay randomness (production: OS entropy).
    random: ?std.Random = null,

    pub fn init(wall_ms: *const fn () i64, clock: engine_mod.Clock) SocialState {
        return .{ .limiter = pacing.RateLimiter.init(.{}, wall_ms), .clock = clock };
    }

    pub fn pacingConfig(self: *SocialState) pacing.PacingConfig {
        self.acquire();
        defer self.lock.unlock();
        return self.limiter.config;
    }

    /// Actions left today, not counting actions in flight (linkedin.* and
    /// instagram.* flows share this cap with social.rate_status /
    /// social.set_pacing).
    pub fn remaining(self: *SocialState) u32 {
        self.acquire();
        defer self.lock.unlock();
        return self.limiter.remaining() -| self.in_flight;
    }

    /// Atomically admits one action: false at the cap, counting actions in
    /// flight on other pages. Every true must be followed by exactly one
    /// commit (success: counts) or release (failure: does not).
    pub fn reserve(self: *SocialState) bool {
        self.acquire();
        defer self.lock.unlock();
        if (self.limiter.remaining() <= self.in_flight) return false;
        self.in_flight += 1;
        return true;
    }

    /// A reserved action succeeded: it counts against the cap.
    pub fn commit(self: *SocialState) void {
        self.acquire();
        defer self.lock.unlock();
        self.in_flight -|= 1;
        var prng = std.Random.DefaultPrng.init(0);
        _ = self.limiter.recordAction(prng.random()) catch {};
    }

    /// A reserved action failed: it does not count.
    pub fn release(self: *SocialState) void {
        self.acquire();
        defer self.lock.unlock();
        self.in_flight -|= 1;
    }

    /// The pause before an action: uniform in [min_delay_ms, max_delay_ms]
    /// of the current pacing config.
    pub fn actionDelayMs(self: *SocialState, random: std.Random) u64 {
        self.acquire();
        defer self.lock.unlock();
        const config = self.limiter.config;
        const low: u64 = @min(config.min_delay_ms, config.max_delay_ms);
        const high: u64 = @max(config.min_delay_ms, config.max_delay_ms);
        return low + random.uintAtMost(u64, high - low);
    }

    /// Randomness for pacing delays: a CSPRNG seeded from OS entropy, or
    /// (tests) seeded from the injected `random` under the state lock.
    pub fn delayRandom(self: *SocialState, csprng: *std.Random.DefaultCsprng) ?std.Random {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        if (self.random) |injected| {
            self.acquire();
            defer self.lock.unlock();
            injected.bytes(&seed);
        } else {
            std.Io.Threaded.global_single_threaded.io().randomSecure(&seed) catch return null;
        }
        csprng.* = .init(seed);
        return csprng.random();
    }

    fn acquire(self: *SocialState) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

/// Duck-typed ports for src/social.zig.
const PacingPort = struct {
    state: *SocialState,
    reset_buf: [24]u8 = undefined,

    pub fn getState(self: *PacingPort) social.PacingState {
        const limiter = &self.state.limiter;
        const remaining = limiter.remaining();
        return .{
            .remaining_actions = remaining,
            .reset_at = formatUtcMidnight(&self.reset_buf, limiter.current_day + 1),
            .daily_cap = limiter.config.daily_cap,
        };
    }

    pub fn configure(self: *PacingPort, params: social.SetPacingParams) void {
        self.state.limiter.updateConfig(.{
            .min_delay_ms = params.min_delay_ms,
            .max_delay_ms = params.max_delay_ms,
            .daily_cap = params.daily_cap,
        });
    }
};

/// The caller holds the page's queue ticket, so sleeping here holds every
/// later command for that page.
const QueuePort = struct {
    clock: engine_mod.Clock,
    cancel: *const std.atomic.Value(bool),
    cancelled: bool = false,

    pub fn pauseFor(self: *QueuePort, duration_ms: u32) void {
        var left: u64 = duration_ms;
        while (left > 0) {
            if (self.cancel.load(.acquire)) {
                self.cancelled = true;
                return;
            }
            const slice = @min(left, engine_mod.poll_interval_ms);
            self.clock.sleepMs(slice);
            left -= slice;
        }
    }
};

const LoginPort = struct {
    url: []const u8,
    probe: social.LoginCheckScriptResult,

    pub fn getPageUrl(self: *const LoginPort) []const u8 {
        return self.url;
    }

    pub fn evalLoginCheck(self: *const LoginPort) social.LoginCheckScriptResult {
        return self.probe;
    }
};

pub fn handle(
    gpa: std.mem.Allocator,
    state: *SocialState,
    /// From Engine.executeExternal: ids for failures, instrumented page access.
    ext: *engine_mod.External,
    verb: Verb,
    params_json: []const u8,
    /// Set when the server stops; ends a running pause with `cancelled`.
    cancel: *const std.atomic.Value(bool),
) error{OutOfMemory}!engine_mod.Outcome {
    const ids = ext.ids();
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalidParams(),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |object| object,
        else => return invalidParams(),
    };

    const allowed: []const []const u8 = switch (verb) {
        .login_check, .rate_status => &.{},
        .pause => &.{"duration_ms"},
        .set_pacing => &.{ "min_delay_ms", "max_delay_ms", "daily_cap" },
    };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        if (!inList(allowed, entry.key_ptr.*)) return invalidParams();
    }

    return switch (verb) {
        .login_check => loginCheck(gpa, ext),
        .rate_status => {
            state.acquire();
            defer state.lock.unlock();
            var port = PacingPort{ .state = state };
            return jsonResult(gpa, social.rateStatus(&port));
        },
        .set_pacing => {
            state.acquire();
            defer state.lock.unlock();
            const current = state.limiter.config;
            const merged = social.SetPacingParams{
                .min_delay_ms = (optionalU32(params, "min_delay_ms") catch return invalidParams()) orelse current.min_delay_ms,
                .max_delay_ms = (optionalU32(params, "max_delay_ms") catch return invalidParams()) orelse current.max_delay_ms,
                .daily_cap = (optionalU32(params, "daily_cap") catch return invalidParams()) orelse current.daily_cap,
            };
            var port = PacingPort{ .state = state };
            const ok = social.setPacing(&port, merged) catch return invalidParams();
            return jsonResult(gpa, ok);
        },
        .pause => {
            const duration_ms = (optionalU32(params, "duration_ms") catch return invalidParams()) orelse return invalidParams();
            var port = QueuePort{ .clock = state.clock, .cancel = cancel };
            const ok = social.pause(&port, .{ .duration_ms = duration_ms });
            if (port.cancelled) return portError(gpa, error.Cancelled, ids);
            return jsonResult(gpa, ok);
        },
    };
}

fn loginCheck(gpa: std.mem.Allocator, ext: *engine_mod.External) error{OutOfMemory}!engine_mod.Outcome {
    const ids = ext.ids();
    const url = ext.url(gpa, read_timeout_ms) catch |err| return portError(gpa, err, ids);
    defer gpa.free(url);
    const text = ext.evalJson(gpa, .automation, login_check_body, "null", read_timeout_ms) catch |err| return portError(gpa, err, ids);
    defer gpa.free(text);

    var script_result = script_command.parseScriptResult(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedScriptResult => return internal("Malformed script result"),
    };
    defer script_result.deinit();
    if (!script_result.ok) return internal("login probe failed");
    const value = switch (script_result.value) {
        .object => |object| object,
        else => return internal("Malformed script result"),
    };
    const logged_in = switch (value.get("logged_in") orelse .null) {
        .bool => |b| b,
        else => false,
    };
    const username: ?[]const u8 = switch (value.get("username") orelse .null) {
        .string => |s| s,
        else => null,
    };

    const port = LoginPort{ .url = url, .probe = .{ .logged_in = logged_in, .username = username } };
    return jsonResult(gpa, social.loginCheck(&port));
}

fn jsonResult(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}!engine_mod.Outcome {
    return .{ .result = try std.json.Stringify.valueAlloc(gpa, value, .{}) };
}

fn invalidParams() engine_mod.Outcome {
    return .{ .failure = .{ .code = -32602, .message = "Invalid params" } };
}

fn internal(message: []const u8) engine_mod.Outcome {
    return .{ .failure = .{ .code = engine_mod.internal_error_code, .message = message } };
}

fn portError(gpa: std.mem.Allocator, err: anyerror, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    return engine_mod.automationFailure(gpa, switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoPage => .session_invalid,
        error.Cancelled => .cancelled,
        error.Timeout => .action_timeout,
        else => return internal("Evaluation failed"),
    }, null, ids);
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

fn optionalU32(obj: std.json.ObjectMap, key: []const u8) error{BadArgs}!?u32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| std.math.cast(u32, n) orelse error.BadArgs,
        else => error.BadArgs,
    };
}

/// "YYYY-MM-DDT00:00:00Z" for a day count since the Unix epoch.
fn formatUtcMidnight(buf: *[24]u8, epoch_day: i32) []const u8 {
    const day = std.time.epoch.EpochDay{ .day = @intCast(@max(epoch_day, 0)) };
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch unreachable;
}
