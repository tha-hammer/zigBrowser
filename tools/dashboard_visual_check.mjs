// Permanent visual-regression check for the automation dashboard
// (src/dashboard/content/index.html).
//
// Renders the REAL dashboard HTML in a headless Chromium across its runtime
// states — connected (mock IPC bridge injected) and disconnected (no bridge,
// as a plain browser sees it) — and ASSERTS on the rendered DOM. Exits non-zero
// on any failed assertion, so CI catches UI regressions automatically.
//
// It specifically guards the class of defect where the DISCONNECTED/error state
// renders a blank body: the error view must show a non-empty, human-readable
// error message, not an empty container.
//
// Run:   zig build dashboard-visual      (preferred)
//   or:  node tools/dashboard_visual_check.mjs
// Screenshots are written to tools/dashboard-shots/ (gitignored) for humans.
//
// Requires a Chromium and Playwright. Resolution order:
//   PLAYWRIGHT_PKG (dir containing playwright) -> repo node_modules -> bare 'playwright'.
//   CHROMIUM_BIN env -> /usr/bin/chromium -> Playwright's bundled Chromium.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML = path.join(REPO, 'src/dashboard/content/index.html');
const SHOTS = path.join(REPO, 'tools/dashboard-shots');

function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_PKG && path.join(process.env.PLAYWRIGHT_PKG, 'playwright'),
    path.join(REPO, 'node_modules/playwright'),
    'playwright',
  ].filter(Boolean);
  for (const c of candidates) {
    try { return require(c); } catch { /* try next */ }
  }
  throw new Error('Playwright not found. Run `npm install` (devDependency @playwright/test) or set PLAYWRIGHT_PKG.');
}

const MOCK = {
  'dashboard.bootstrap': {
    apiVersion: 'zb-sequences-v1',
    actor: { userId: 'usr_smoke', orgId: 'org_smoke', roles: ['recruiter'] },
    featureFlags: { sequenceCreation: true, stepAuthoring: true, automationExecution: true, analytics: true },
    mailboxes: [
      { mailboxConnectionId: 'mbx_1', provider: 'gmail', status: 'connected', dailyCapRemaining: 120 },
      { mailboxConnectionId: 'mbx_2', provider: 'outlook', status: 'connected', dailyCapRemaining: 30 },
    ],
    analyticsDefaults: { dateRangeDays: 30, groupBy: 'week' },
  },
  'dashboard.sequences.list': {
    items: [
      { sequenceId: 'seq_1', name: 'Senior Backend Search', status: 'active', ownerUserId: 'usr_ada', updatedAt: '2026-07-11T14:00:00Z', metrics: { profilesContacted: 42, replyRate: 0.214 } },
      { sequenceId: 'seq_2', name: 'Staff SRE Outreach', status: 'pending_approval', ownerUserId: 'usr_lin', updatedAt: '2026-07-10T09:30:00Z', metrics: { profilesContacted: 0, replyRate: null } },
      { sequenceId: 'seq_3', name: 'Design Systems Lead', status: 'draft', ownerUserId: 'usr_ada', updatedAt: '2026-07-09T18:12:00Z', metrics: { profilesContacted: 0, replyRate: null } },
      { sequenceId: 'seq_4', name: 'Q1 Data Eng Pipeline', status: 'archived', ownerUserId: 'usr_max', updatedAt: '2026-06-28T11:00:00Z', metrics: { profilesContacted: 88, replyRate: 0.153 } },
    ],
    nextCursor: null,
  },
  'dashboard.analytics.outreach': {
    groupBy: 'week',
    totals: { profilesContacted: 130, opens: 411, clicks: 96, replies: 28, interestedReplies: 12, bounces: 4 },
    series: [
      { bucketStart: '2026-06-22', profilesContacted: 30, openRate: 0.61, clickRate: 0.18, replyRate: 0.10, bounceRate: 0.03 },
      { bucketStart: '2026-06-29', profilesContacted: 45, openRate: 0.66, clickRate: 0.22, replyRate: 0.14, bounceRate: 0.02 },
    ],
  },
};

const bridgeInit = `
window.webkit = { messageHandlers: { zbHost: { postMessage: function(payload){
  var msg = JSON.parse(payload); var d = ${JSON.stringify(MOCK)};
  return JSON.stringify(d[msg.cmd] !== undefined ? d[msg.cmd] : null);
} } } };`;

const failures = [];
function check(name, cond, detail) {
  if (cond) { console.log('  PASS  ' + name); }
  else { console.log('  FAIL  ' + name + (detail ? ' — ' + detail : '')); failures.push(name); }
}

async function main() {
  const { chromium } = loadPlaywright();
  fs.mkdirSync(SHOTS, { recursive: true });
  const fileUrl = 'file://' + HTML;

  const launchOpts = { args: ['--no-sandbox'] };
  const explicit = process.env.CHROMIUM_BIN || (fs.existsSync('/usr/bin/chromium') ? '/usr/bin/chromium' : null);
  if (explicit) launchOpts.executablePath = explicit;

  const browser = await chromium.launch(launchOpts);
  try {
    // ---- CONNECTED state (mock bridge) ----
    console.log('\n[connected]');
    const ctx1 = await browser.newContext({ viewport: { width: 1200, height: 860 } });
    const p1 = await ctx1.newPage();
    await p1.addInitScript(bridgeInit);
    await p1.goto(fileUrl, { waitUntil: 'networkidle' });
    await p1.waitForTimeout(500);

    const connLabel = (await p1.textContent('#connection-label')) || '';
    const dotClass = await p1.getAttribute('#connection-dot', 'class');
    check('status shows Connected', /connected/i.test(connLabel), 'label="' + connLabel + '"');
    check('status dot has connected class', /\bconnected\b/.test(dotClass || ''), 'class="' + dotClass + '"');
    check('overview renders KPI cards', (await p1.locator('#main-content .kpi-card').count()) >= 4);
    check('overview renders sequence rows', (await p1.locator('#main-content table tbody tr').count()) >= 1);
    check('overview renders status badges', (await p1.locator('#main-content .badge').count()) >= 1);
    await p1.screenshot({ path: path.join(SHOTS, 'connected_overview.png') });

    await p1.click('button[data-view="sequences"]'); await p1.waitForTimeout(250);
    check('sequences view lists all 4 sequences', (await p1.locator('#main-content table tbody tr').count()) === 4);
    await p1.screenshot({ path: path.join(SHOTS, 'connected_sequences.png') });

    await p1.click('button[data-view="analytics"]'); await p1.waitForTimeout(250);
    check('analytics view renders totals', (await p1.locator('#main-content .kpi-card').count()) >= 6);
    await p1.screenshot({ path: path.join(SHOTS, 'connected_analytics.png') });
    await ctx1.close();

    // ---- DISCONNECTED / error state (no bridge) ----
    console.log('\n[disconnected]');
    const ctx2 = await browser.newContext({ viewport: { width: 1200, height: 600 } });
    const p2 = await ctx2.newPage();
    await p2.goto(fileUrl, { waitUntil: 'networkidle' });
    await p2.waitForTimeout(700);

    const discLabel = (await p2.textContent('#connection-label')) || '';
    const errClass = await p2.getAttribute('#connection-dot', 'class');
    const bodyText = ((await p2.textContent('#main-content')) || '').trim();
    check('status shows Disconnected', /disconnect/i.test(discLabel), 'label="' + discLabel + '"');
    check('status dot has error class', /\berror\b/.test(errClass || ''), 'class="' + errClass + '"');
    // THE REGRESSION GUARD: the body must NOT be blank on error.
    check('error body is not blank', bodyText.length >= 20, 'bodyText length=' + bodyText.length);
    check('error body shows a human-readable message',
      /reach|unavailable|error|connect|try again|host/i.test(bodyText),
      'bodyText="' + bodyText.slice(0, 80) + '"');
    await p2.screenshot({ path: path.join(SHOTS, 'disconnected.png') });
    await ctx2.close();
  } finally {
    await browser.close();
  }

  console.log('\nscreenshots -> ' + SHOTS);
  if (failures.length) {
    console.error('\nVISUAL REGRESSION: ' + failures.length + ' assertion(s) failed:\n  - ' + failures.join('\n  - '));
    process.exit(1);
  }
  console.log('\nALL VISUAL CHECKS PASSED (' + '10' + ' assertions).');
}

main().catch((e) => { console.error('dashboard_visual_check error: ' + (e && e.stack || e)); process.exit(2); });
