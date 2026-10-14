#!/usr/bin/env bun
// Fixture hook: writes nothing outside the agent home.
const home = process.env.HOME ?? "";
console.log(`hook ran in ${home}/.claude/hooks`);
