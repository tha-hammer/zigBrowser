---
date: "2026-04-15T11:00:00-04:00"
researcher: Silmari
git_commit: 45e5b7d57ea2ecc2fc68afdfbc16da4dfaf15dac
branch: main
repository: silmari-agent-memory
topic: "Incorporating markdown_web_browser into the scraping pipeline — current state of playwright/puppeteer call sites"
tags: [research, scraping, playwright, puppeteer, markdown_web_browser, mdwb, brightdata, apify, browser-automation]
status: complete
last_updated: "2026-04-15"
last_updated_by: Silmari
---

```
┌──────────────────────────────────────────────────────────────────────┐
│  RESEARCH: markdown_web_browser ↔ Scraping Pipeline                  │
│  Status: COMPLETE | 2026-04-15                                       │
│  Scope: documentation of current state, no recommendations           │
└──────────────────────────────────────────────────────────────────────┘
```

# Research: Incorporating `markdown_web_browser` into the scraping pipeline

**Date**: 2026-04-15T11:00:00-04:00
**Researcher**: Silmari
**Git Commit**: 45e5b7d57ea2ecc2fc68afdfbc16da4dfaf15dac
**Branch**: main
**Repository**: silmari-agent-memory

## Research Question

> I want to incorporate the `~/Dev/markdown_web_browser` into the scraping pipeline. Be sure to find all the places where `playwright` or `puppeteer` is called.

## 🎯 Summary

The research covers three independent axes:

1. **What `markdown_web_browser` is** — a Python/FastAPI web-to-markdown capture service that itself uses Playwright under the hood (Chrome for Testing, CDP transport, stealth + screenshot tiling + OCR).
2. **What the scraping pipeline is** — the `~/.claude/skills/scraping/` skill, which defines a four-tier progressive escalation (WebFetch → curl+UA → **mdwb** → Bright Data MCP).
3. **Where Playwright/Puppeteer is actually called** — ~20 projects across `~/Dev/` and `~/.claude/skills/`, almost all of which are unrelated E2E test suites, plus a small number of scraping-adjacent call sites.

**Load-bearing finding**: the scraping pipeline **already documents** mdwb as Tier 3 via `curl` against `http://localhost:8000/jobs`. Integration exists today at the **prompt/workflow layer**, not at the code layer. See `FourTierScrape.md:110-170` below for the exact shell-script call shape currently in use.

---

## 📊 Detailed Findings

### 1. `~/Dev/markdown_web_browser/` — What it is

| Property | Value |
|---|---|
| Language | Python 3.13 backend, HTMX/Alpine/Tailwind frontend |
| Framework | FastAPI + Uvicorn/Granian |
| Purpose | Deterministic URL → markdown capture via stealth Chrome + OCR |
| Underlying browser | Playwright ≥1.48, Chrome for Testing (CDP primary, BiDi fallback) |
| Public surface | HTTP REST + SSE on `:8000` and a typer CLI (`scripts/mdwb_cli.py`) |
| Persistence | SQLite (`runs.db`), filesystem artifact cache (`.cache/`) |

#### Invocation shapes

**As HTTP service** (primary interface):

| Method | Path | Purpose | File |
|---|---|---|---|
| POST | `/jobs` | Create capture job (URL in, job ID out) | `app/main.py:278-282` |
| GET | `/jobs/{id}` | Poll state | `app/main.py:284-291` |
| GET | `/jobs/{id}/stream` | SSE event stream | `app/main.py:304-331` |
| GET | `/jobs/{id}/result.md` | Final markdown | `app/main.py:405-415` |
| GET | `/jobs/{id}/links.json` | Extracted links/forms | `app/main.py:379-392` |
| GET | `/jobs/{id}/manifest.json` | Capture metadata | `app/main.py:394-403` |
| POST | `/replay` | Re-run with different OCR policy | `app/main.py:293-302` |

**As CLI**:
```bash
cd ~/Dev/markdown_web_browser && uv run python -m scripts.mdwb_cli fetch "<URL>" --watch
cd ~/Dev/markdown_web_browser && uv run python -m scripts.mdwb_cli jobs artifacts markdown <JOB_ID>
```

**As Python library**: `from app.capture import capture_tiles`, `from app.ocr_client import submit_tiles`, `from app.stitch import stitch_markdown`.

No MCP server surface is exposed.

#### Inputs / outputs

- **Input** (`POST /jobs`, `app/schemas.py:14-65`): `{ url, viewport_width, viewport_height, device_scale_factor, color_scheme, long_side_px, profile_id, reuse_cache }`.
- **Output `result.md`**: concatenated tile markdown with `<!-- source: tile_N -->` provenance comments + Links Appendix grouped by domain.
- **Output `links.json`**: `[{ href, text, source: 'dom'|'ocr', rel, target, domain, kind: 'link'|'form'|'heading', tile_indices, crawled }]`.
- **Output `manifest.json`** (`app/schemas.py:122-200`): full capture metadata — CfT version, playwright version, viewport settings, tile list with sha256, scroll policy, OCR backend, warnings.

#### Playwright internals

The project IS a Playwright consumer at:

| File | Line | Usage |
|---|---|---|
| `app/capture.py` | 13 | `from playwright.async_api import Browser, BrowserContext, Page, async_playwright` |
| `app/capture_warnings.py` | 8 | `from playwright.async_api import Page` |
| `app/blocklist.py` | 12 | `from playwright.async_api import Page` |
| `pyproject.toml` | 14 | Dep: `playwright>=1.48` |
| `playwright.config.mjs` | — | Playwright Test config (BiDi + CfT channel) |
| `playwright/smoke_capture.spec.ts` | — | TS smoke spec |
| `scripts/capture_readme_screenshots.py` | 13 | README screenshot automation |
| `Dockerfile` | 32-34 | `playwright install chromium && playwright install-deps chromium` |
| `install.sh` | 352 | `uv run playwright install chromium --with-deps --channel=cft` |
| `.github/workflows/ci.yml` | 138 | CI install |
| `.github/workflows/nightly_smoke.yml` | 93 | Nightly CI install |

Config surface (env vars read via `python-decouple` in `app/settings.py`): `OCR_SERVER`, `OCR_API_KEY`, `OCR_MODEL`, `CFT_VERSION`, `PLAYWRIGHT_CHANNEL`, `PLAYWRIGHT_TRANSPORT`, `VIEWPORT_OVERLAP_PX`, `CAPTURE_LONG_SIDE_PX`, `SCROLL_SETTLE_MS`, `MAX_VIEWPORT_SWEEPS`, `BLOCKLIST_PATH`, `CACHE_ROOT`, `RUNS_DB_PATH`, `WEBHOOK_SECRET`, `PROMETHEUS_PORT`.

---

### 2. `~/.claude/skills/scraping/` — The scraping pipeline

**Entry**: `SKILL.md` dispatches to two sub-skills:

- **`BrightData/`** — URL scraping + crawling (Workflows: `FourTierScrape.md`, `Crawl.md`)
- **`Apify/`** — platform-specific actors (Instagram, LinkedIn, TikTok, YouTube, Facebook, Twitter/X, Google Maps, Amazon, generic web-scraper)

#### Four-Tier progressive escalation

Source: `BrightData/Workflows/FourTierScrape.md:35-220`

| Tier | Tool | When | Cost |
|---|---|---|---|
| 🟢 1 | Claude Code `WebFetch` | Fast, simple sites | Free |
| 🟡 2 | `curl` + Chrome user-agent | Tier 1 blocked | Free |
| 🟠 3 | **mdwb (localhost:8000)** | JS-heavy, Cloudflare, SPAs | Local compute + OCR |
| 🔴 4 | `mcp__Brightdata__scrape_as_markdown` | CAPTCHA / advanced fingerprinting | Per-call |

Light Crawl = MCP batch (<50 pages); Full Crawl = Bright Data Crawl API (unlimited).

#### The existing mdwb integration (Tier 3)

**This is the load-bearing finding for the user's question.** Integration already exists — documented in `FourTierScrape.md:110-170` — as a shell-script workflow:

```bash
# FourTierScrape.md:122-127 — health check + auto-start
if ! curl -sf http://localhost:8000/health > /dev/null 2>&1; then
  cd ~/Dev/markdown_web_browser && uv run python scripts/run_server.py &
  # wait-for-up loop on /health
fi

# FourTierScrape.md:137 — create job
JOB_RESPONSE=$(curl -sf -X POST http://localhost:8000/jobs ...)

# FourTierScrape.md:145 — poll state
STATUS=$(curl -sf "http://localhost:8000/jobs/$JOB_ID" | python3 ...)

# FourTierScrape.md:157 — fetch markdown
MARKDOWN=$(curl -sf "http://localhost:8000/jobs/$JOB_ID/result.md")
```

Also documented as a CLI path at `FourTierScrape.md:165-170`:
```bash
cd ~/Dev/markdown_web_browser && uv run python -m scripts.mdwb_cli fetch "[URL]" --watch
cd ~/Dev/markdown_web_browser && uv run python -m scripts.mdwb_cli jobs artifacts markdown [JOB_ID]
```

Routing rules (`FourTierScrape.md:339-342`):
- Explicit user request `"use browser"` or `"use mdwb"` → skip straight to Tier 3
- URL has Cloudflare protection → start at Tier 3

Skill-level references: `BrightData/SKILL.md:103` and `BrightData/SKILL.md:135`.

#### Existing integration seams for downstream work

| Seam | Location | Shape |
|---|---|---|
| Post-markdown processing | After any Tier returns markdown | Currently linear — no hook system |
| Apify result filtering | `Apify/index.ts:232-247` | `ApifyDataset.filter()` / `.top()` |
| Link discovery (Crawl) | `Crawl.md` | Extracts from markdown before `scrape_batch` |
| Apify actor config | `Apify/actors/<category>/*.ts` | Typed wrappers per actor |

Config/secrets read from env: `APIFY_TOKEN` / `APIFY_API_KEY` (`Apify/index.ts:54`), `BRIGHT_DATA_API_KEY` (per `Crawl.md`). No secrets hardcoded.

---

### 3. Playwright / Puppeteer call sites — full catalogue

Grouped by project. Items marked 🕸 are **scraping-adjacent** (the ones relevant to the user's integration goal). Others are **test suites** that drive their own UIs and wouldn't typically route through mdwb.

#### 🕸 Scraping-adjacent call sites

| Project | File | Line | Usage |
|---|---|---|---|
| `markdown_web_browser` | `app/capture.py` | 13 | `async_playwright` — the primary capture engine |
| `markdown_web_browser` | `app/capture_warnings.py` | 8 | `Page` type |
| `markdown_web_browser` | `app/blocklist.py` | 12 | `Page` type |
| `markdown_web_browser` | `scripts/capture_readme_screenshots.py` | 13 | README screenshots via playwright |
| `~/.claude/skills/security/WebAssessment/WebappExamples/` | `console_logging.py` | 1 | `sync_playwright` — security web assessment |
| `~/.claude/skills/security/WebAssessment/WebappExamples/` | `static_html_automation.py` | 1 | `sync_playwright` — static HTML automation |
| `~/.claude/skills/security/WebAssessment/WebappExamples/` | `element_discovery.py` | 1 | `sync_playwright` — element discovery |
| `~/.claude/skills/utilities/Documents/Pptx/Scripts/` | `html2pptx.js` | 28 | `const { chromium } = require('playwright')` — HTML→PPTX render |
| `Agent-Assistant-Infrastructure` | `Packs/Utilities/src/Documents/Pptx/Scripts/html2pptx.js` | 28 | Same as above, shared with utilities skill |
| `Agent-Assistant-Infrastructure` | `Packs/Utilities/src/Browser/` | — | Browser skill (`bunx playwright screenshot`, full README/SKILL.md) |
| `agentic_coding_flywheel_setup` | `apps/web/scripts/research_final.mjs` | 1 | `chromium` — research scraping |
| `agentic_coding_flywheel_setup` | `apps/web/scripts/research_contabo_checkout.mjs` | 1 | `chromium` — pricing scrape |
| `agentic_coding_flywheel_setup` | `apps/web/scripts/research-vps-pricing.mjs` | 17 | `chromium` — pricing scrape |
| `openclaw` | `scripts/ui.js` | 90-91 | `require.resolve("playwright")` — runtime resolver |
| `cosmic-backup/rust/auth_Protocol/standards/cosmic/` | `package.json` | 53 | Dep: `puppeteer@^24.17.0` (only puppeteer user) |
| `jat` | `install.sh` | — | Comment referencing `puppeteer-core` + `cheerio` |

#### Test-suite call sites (E2E for own UIs — not integration candidates)

<details>
<summary><b>Click to expand — ~15 projects, mostly @playwright/test consumers</b></summary>

| Project | Files | Usage |
|---|---|---|
| `agent-ui/frontend` | `playwright.config.ts`, `scripts/capture-screenshots.ts`, `scripts/record-demo.ts`, `tests/demo-validation.spec.ts`, `tests/plan-mode.spec.ts`, `package.json:19,33` | E2E + demo recording |
| `cosmic-cmo-builder` | `playwright.config.ts`, `e2e/workflow.spec.ts` | E2E |
| `cosmic-HR`, `cosmic-HR04`, `cosmic-HR04-ui-redesign`, `cosmic-HR05` | `playwright.config.js`, `playwright.real.config.js`, `tests/e2e/*.spec.js`, `.github/workflows/ci.yml:63` | E2E across 4 HR variants |
| `coding_agent_session_search` | `tests/playwright.config.ts`, `tests/e2e/setup/test-utils.ts`, `tests/e2e/reporters/jsonl-reporter.ts:22`, `tests/e2e/mobile/touch-navigation.spec.ts:2`, `tests/e2e/accessibility/axe-core.spec.ts:2`, `scripts/tests/run_all.sh`, `tests/performance/package.json:12` | Full E2E incl. a11y |
| `agentic_coding_flywheel_setup/apps/web` | `playwright.config.ts`, 8× `e2e/*.spec.ts` | E2E (separate from scraping scripts above) |
| `silmari-writer/frontend` | `playwright.config.ts` | E2E config |
| `remote_compilation_helper/web` | `playwright.config.ts`, `tests/a11y/accessibility.spec.ts:2`, `tests/fixtures/test-utils.ts:1`, 6× `tests/e2e/*.spec.ts` | Full E2E incl. a11y |
| `cosmic-agent-memory/frankensqlite` | `playwright.config.ts`, `e2e/frankensqlite.spec.ts:1` | E2E with console inspection |
| `cosmic-agent-memory/asupersync` | `tests/fixtures/*/scripts/check-browser-run.mjs:4` (×4) | `playwright-core` worker tests |
| `openclaw/ui` | `package.json:20` | Dep: `playwright@^1.58.2` |
| `claude_code_agent_farm` | `tool_setup_scripts/setup_sveltekit_remix_astro.sh` | Scaffolds playwright into new projects |

</details>

#### Summary statistics

| Category | Count |
|---|---|
| Playwright config files | 12 (`playwright.config.{ts,js,mjs}`) |
| Projects with Playwright | 15+ |
| Projects with Puppeteer | 2 (`cosmic-backup`, `jat`) |
| Python `async_api` / `sync_api` imports | 10+ files (mdwb + security skill) |
| TS/JS test-spec imports | 40+ |
| CLI invocations (`install`, `test`, `bunx`, `uv run`) | 30+ |
| CI/CD workflows (GitHub Actions) | 6 |
| Dockerfiles | 3 |

**`silmari-agent-memory/` (the current repo) has zero Playwright or Puppeteer usage.**

---

## 🔗 Code References

### markdown_web_browser HTTP surface
- `~/Dev/markdown_web_browser/app/main.py:278-282` — `POST /jobs` (job creation)
- `~/Dev/markdown_web_browser/app/main.py:304-331` — `GET /jobs/{id}/stream` (SSE)
- `~/Dev/markdown_web_browser/app/main.py:405-415` — `GET /jobs/{id}/result.md`
- `~/Dev/markdown_web_browser/app/schemas.py:14-65` — `JobCreateRequest`
- `~/Dev/markdown_web_browser/app/schemas.py:122-200` — `ManifestMetadata`
- `~/Dev/markdown_web_browser/app/capture.py:13` — the playwright import

### Scraping pipeline integration points
- `~/.claude/skills/scraping/SKILL.md:1-16` — skill entry
- `~/.claude/skills/scraping/BrightData/SKILL.md:103` — Tier 3 advertised
- `~/.claude/skills/scraping/BrightData/SKILL.md:135` — mdwb tool list entry
- `~/.claude/skills/scraping/BrightData/Workflows/FourTierScrape.md:28` — mdwb prerequisite
- `~/.claude/skills/scraping/BrightData/Workflows/FourTierScrape.md:110-170` — the existing shell-script integration
- `~/.claude/skills/scraping/BrightData/Workflows/FourTierScrape.md:339-342` — routing rules
- `~/.claude/skills/scraping/BrightData/Workflows/FourTierScrape.md:364-387` — CLI reference
- `~/.claude/skills/scraping/Apify/index.ts:49-163` — `ApifyClient` wrapper
- `~/.claude/skills/scraping/Apify/index.ts:232-247` — `ApifyDataset.filter()` seam

## 🏛 Architecture Documentation

The scraping skill is prompt-level orchestration, not a code library. It routes by natural-language trigger, escalates tiers shell-command-by-shell-command, and returns text back to the model. The **only** code-level layer today is the Apify sub-skill's TypeScript client (`Apify/index.ts`), which wraps `apify-client@^2.19.0` and exists specifically because raw MCP actor calls leaked too much context.

mdwb's own architecture: FastAPI foreground → background capture worker (Playwright stealth Chrome with CDP, 60+ line stealth JS patch, deterministic 1280×2000 viewport, ≤200 scroll steps at ~1000px/step with 350ms settle) → screenshot tiling via pyvips → remote olmOCR server for tile OCR → stitch phase that fuses OCR text with DOM-extracted links/forms/headings into provenance-tagged markdown. Outputs: `result.md`, `links.json`, `manifest.json`, raw tiles. Cached by URL + viewport; replayable from manifest.

## 📜 Historical Context (from thoughts/)

No prior research documents in `thoughts/` cover either `markdown_web_browser` or the scraping pipeline — this is the first research pass on this topic in this repo.

## Related Research

- `thoughts/shared/research/2026-04-12-beads-viewer-zettelkasten-graph-redesign.md` — unrelated viewer work
- No prior scraping or browser-automation research in this repo.

## ❓ Open Questions

These are informational — flagging gaps the documentation does not itself answer:

1. **Does the scraping skill's Tier 3 handshake persist the mdwb server process beyond one call?** `FourTierScrape.md:122-127` starts it in the background with `&` but does not describe teardown.
2. **Is there a shared workspace convention for mdwb job artifacts across different scraping callers?** The skill calls directly with `http://localhost:8000/jobs` — no per-caller namespace appears documented.
3. **Are any callers currently wired to mdwb's SSE stream (`/jobs/{id}/stream`) or is everyone on the poll loop?** The skill's existing recipe at `FourTierScrape.md:145` uses polling.
4. **Does `silmari-agent-memory` itself need browser capture anywhere?** Current grep shows zero playwright/puppeteer usage in this repo.
