//! The one fact the macOS seatbelt readiness derives from (plan R29-MS6 D2, bd zigBrowser-4pa.66):
//! `agent_setup.seatbelt_ready` is `accepted_commit != null`, never a boolean set by hand. Only the reviewed MS6
//! acceptance commit sets this, naming the commit whose both-Mac kernel-denial gate passed. That same commit must
//! flip PROFILE_CURATION to CURATED in agent/host/zb_agent_host/sandbox_macos.py, or the registered invariant
//! (tests/agent_seatbelt_readiness_invariant_test.zig) fails.
pub const accepted_commit: ?[]const u8 = null;
