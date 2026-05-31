---
date: 2026-04-30T09:44:23-04:00
researcher: Codex
git_commit: 2caa9430d03aa15c6f43039e2de3dcb9e88011f4
branch: main
repository: silmari-agent-memory
topic: "YouTube video and playlist ingest into Silmari memory stores"
tags: [research, codebase, youtube, cascade-ingest, native-primary, import-export]
status: complete
last_updated: 2026-04-30
last_updated_by: Codex
---

# Research: YouTube Links to Silmari Memory Ingest

## Research Question

How can a user take a YouTube video or playlist link, produce transcript artifacts, ingest those artifacts into a Silmari memory store, and then make that generated memory available inside an existing Silmari memory store?

## Scope

This research covers the current code and docs in:

- Main repo: `/home/maceo/Dev/silmari-agent-memory` at `2caa9430d03aa15c6f43039e2de3dcb9e88011f4`.
- YouTube transcriber repo: `/home/maceo/Dev/bulk_transcribe_youtube_videos_from_playlist` at `ae3fb76e6f839a0aebe31177a829255f69783eef`.
- Agent Mail coordination from RedGorge, VioletBeacon, and CobaltRiver where it affects current validation status.

This document describes what exists today. It does not implement a wrapper or change the pipeline.

## Executive Summary

The current system already has the major pieces for a YouTube-to-memory workflow, but it is not exposed as one general command that accepts an arbitrary YouTube video or playlist URL.

The transcriber repo accepts a single video or playlist through module-level variables, downloads audio, and writes transcript text plus Whisper-style metadata JSON. The cascade pipeline already knows how to consume exactly those artifacts: `TRANSCRIPTS_DIR/<basename>.txt` and, preferably, `TRANSCRIPTS_METADATA_DIR/<basename>.json`.

The clean ingest boundary is direct import into the selected Silmari store. `CASCADE_ENRICHMENT_MODE=off` writes preaddressed cards and structural edges from cached extraction JSON, while `after-import` imports first and then runs hub, keyword, and Gate B enrichment. In native-primary mode, the target store is whichever SQLite database is named by `SILMARI_MEMORY_CONFIG.nativeDbPath`.

For "import into an existing Silmari memory store", the current code supports direct writing into that existing native store by pointing `nativeDbPath` at the existing database before running cascade import. A separate "generate native DB, then merge native DB into existing native DB" command was not found. Existing import commands are for Beads-shaped SQLite sources and verified legacy snapshots, not native-to-native merge.

One important edge visibility caveat remains: Silmari semantic and structural refs are currently label-encoded through `ref:<type>:<target>` labels in the MCP edge layer. The native viewer exporter reads `card_edges`. RedGorge's latest full bundle run reported committed Gate B edges in `link-proposals.jsonl` and aggregate reports, while the native DB had zero `card_edges` rows for viewer export. That is relevant when using generated stores for graph viewing or export.

## Current End-to-End Shape

### 1. YouTube URL to transcript artifacts

The transcriber script is a single Python entry point:

- `/home/maceo/Dev/bulk_transcribe_youtube_videos_from_playlist/bulk_transcribe_youtube_videos_from_playlist.py`
- README: `/home/maceo/Dev/bulk_transcribe_youtube_videos_from_playlist/readme.md`

The script chooses single-video mode or playlist mode from module-level flags:

- `convert_single_video`, `single_video_url`, and `playlist_url` are defined at `bulk_transcribe_youtube_videos_from_playlist.py:22-29`.
- The script prints the selected mode at `bulk_transcribe_youtube_videos_from_playlist.py:31-34`.
- `process_video_or_playlist()` constructs either `YouTube(url)` or `Playlist(url).videos` at `bulk_transcribe_youtube_videos_from_playlist.py:222-228`.
- Per-video work is bounded by `asyncio.Semaphore(max_simultaneous_downloads)` and dispatched with `asyncio.gather()` at `bulk_transcribe_youtube_videos_from_playlist.py:229-241`.

The script creates these output directories relative to its working directory:

- `downloaded_audio`
- `generated_transcript_combined_texts`
- `generated_transcript_metadata_tables`

Those directories are created at `bulk_transcribe_youtube_videos_from_playlist.py:59-61`.

Filename normalization is important because the cascade pipeline keys everything by basename:

- `clean_filename()` removes punctuation, converts spaces/hyphens to underscores, strips, and lowercases at `bulk_transcribe_youtube_videos_from_playlist.py:98-100`.
- `download_audio()` writes `downloaded_audio/<basename>.mp4`, suffixing duplicates with `_1`, `_2`, etc. at `bulk_transcribe_youtube_videos_from_playlist.py:102-122`.

For each audio file, the transcriber writes:

- `generated_transcript_combined_texts/<basename>.txt`
- `generated_transcript_metadata_tables/<basename>.csv`
- `generated_transcript_metadata_tables/<basename>.json`

The write happens at `bulk_transcribe_youtube_videos_from_playlist.py:213-219`.

The metadata JSON shape is compatible with the cascade segment loader:

```json
{
  "start": 0,
  "end": 0,
  "text": "",
  "avg_logprob": 0
}
```

The OpenAI Whisper path builds that shape at `bulk_transcribe_youtube_videos_from_playlist.py:172-180`. The local Whisper path builds the same keys at `bulk_transcribe_youtube_videos_from_playlist.py:203-209`.

Operational note: the current script stores transcription configuration, including API selection and API key wiring, directly in Python module-level variables at `bulk_transcribe_youtube_videos_from_playlist.py:22-29`. This research intentionally does not reproduce the key value.

### 2. Transcript artifacts to cascade extraction JSON

The cascade pipeline's segment contract is already aligned with the transcriber output.

`scripts/kc-baker-pipeline-v2/extract/segments.ts` explicitly prefers:

1. `$TRANSCRIPTS_METADATA_DIR/<basename>.json`, one Whisper-style row per segment.
2. Fallback to `$TRANSCRIPTS_DIR/<basename>.txt`, split on sentence boundaries.

That preference is documented in code at `segments.ts:10-16` and implemented at `segments.ts:44-72`. Prompt rendering preserves stable segment indexes with `[idx]<text>` lines at `segments.ts:118-124`, and `rebuildRange()` reconstitutes verbatim spans by segment ID at `segments.ts:87-115`.

The pass scripts all accept the same two environment variables:

- Pass 1 reads `TRANSCRIPTS_DIR`, `TRANSCRIPTS_METADATA_DIR`, `EXTRACTED_DIR`, and `TARGET_TRANSCRIPT` at `pass1-themes.ts:182-188`.
- Pass 2 reads the same transcript and metadata roots at `pass2-ideas.ts:220-226`.
- Pass 3 reads them at `pass3-micros.ts:274-279`.

The orchestrator is `scripts/kc-baker-pipeline-v2/run.sh`:

- Defaults `TRANSCRIPTS_DIR=/input/transcripts`, `EXTRACTED_DIR=/extracted`, `SILMARI_DIR=/silmari-store`, and `PASS3_MODEL=haiku` at `run.sh:22-27`.
- Runs Pass 1, Pass 2, Pass 3, Gate A, Fix, Ingest, and graph candidates in order at `run.sh:57-78`.
- Mirrors `micros.${PASS3_MODEL}.json` to canonical `micros.json` at `run.sh:61-73`.

The current Docker compose file is already wired to the YouTube transcriber text output:

- `TRANSCRIPTS_DIR` is `/input/transcripts` at `docker-compose.yml:8-11`.
- The host source bind mount is `${HOME}/Dev/bulk_transcribe_youtube_videos_from_playlist/generated_transcript_combined_texts` at `docker-compose.yml:42-46`.

The compose file does not currently bind `generated_transcript_metadata_tables` or set `TRANSCRIPTS_METADATA_DIR`, so a compose run as written uses text fallback unless the caller supplies that metadata mount and environment variable.

### 3. Cached cascade JSON to a Silmari store

The current preferred ingest path is documented in `scripts/kc-baker-pipeline-v2/README.md:91-150` and `scripts/kc-baker-pipeline-v2/ingest/README.md:1-85`.

The ingestion entry point is `scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts`:

- `CASCADE_ENRICHMENT_MODE` accepts `off`, `after-import`, and `enrich-only` at `ingest-cascade.ts:563-573`.
- `off` runs deterministic import only at `ingest-cascade.ts:1724-1726`.
- `after-import` imports and then enriches at `ingest-cascade.ts:1727-1729`.
- `enrich-only` requires an existing `ingest-report.json` and enriches that report at `ingest-cascade.ts:1730-1734`.
- Batch mode scans `$EXTRACTED_DIR` for transcript directories containing `micros.v2.json` or `micros.json` at `ingest-cascade.ts:1769-1777`.
- Each transcript reads `themes.json`, `ideas.json`, and the selected micros file at `ingest-cascade.ts:1791-1802`.
- Success writes `ingest-report.json`; failure writes `failure-report.json` unless the import writer already wrote one at `ingest-cascade.ts:1813-1857`.
- The final success path runs SQLite `PRAGMA integrity_check` by default at `ingest-cascade.ts:1873-1879`.

The deterministic import writer boundary is:

- `planCascadeImport()` creates preaddressed thesis, theme, idea, and micro cards from cached JSON in `cascade-import-plan.ts`.
- `writeCascadeImport()` writes planned cards, structural edges, flushes, commits the cursor, and returns an import report at `cascade-import-writer.ts:358-497`.
- The import report includes `import.allIds`, key/address maps, created/reused IDs, structural edges, and zeroed Gate B fields at `cascade-import-plan.ts:101-130`.

The native-primary target is selected through `SILMARI_MEMORY_CONFIG`:

- Runtime modes include `legacy-br`, `import-only`, `shadow-read`, `shadow-write`, `native-primary`, and `legacy-read-only` at `apps/silmari-mcp/src/lib/native-mode.ts:6-13`.
- `native-primary` requires an absolute `nativeDbPath` at `native-mode.ts:52-59` and `native-mode.ts:195-203`.
- `resolveSilmariMemoryMode()` reads `SILMARI_MEMORY_CONFIG`, `SILMARI_MEMORY_MODE`, or `$SILMARI_DIR/config/native-memory-mode.json` at `native-mode.ts:79-114`.

The documented native-primary import-only command initializes a native DB, writes:

```json
{"version":1,"mode":"native-primary","nativeDbPath":"$native_db"}
```

and then runs:

```bash
CASCADE_ENRICHMENT_MODE=off \
  SILMARI_MEMORY_CONFIG="$tmp/config/native-memory-mode.json" \
  SILMARI_MEMORY_RUST_BINARY="$rust_bin" \
  SILMARI_DIR="$tmp/silmari-store" \
  EXTRACTED_DIR="$tmp/extracted" \
  bun run ingest/ingest-cascade.ts
```

That command is documented at `scripts/kc-baker-pipeline-v2/README.md:91-110`. The same README documents `after-import` with `SAI_INFERENCE_BACKEND=codex` at `README.md:112-119`.

## Importing Into an Existing Silmari Memory Store

There are three distinct "import" concepts in the current codebase.

### Direct cascade import into an existing native store

This is the current path that matches YouTube/cascade ingestion.

The cascade import writer writes to whatever store the `br-adapter` facade selects. In `native-primary`, that means the native SQLite DB named by `nativeDbPath`. Therefore, using an existing Silmari native store is a configuration choice: point `SILMARI_MEMORY_CONFIG.nativeDbPath` at the existing store before running `ingest-cascade.ts`.

This is not a later merge step. The generated cards are created directly in the target store during cascade import.

### Beads-shaped SQLite into native DB

The Rust CLI exposes:

```bash
silmari_memory_rust import-beads --source <beads.db> --db <native.sqlite> --box-name idea --json
```

The CLI arguments are defined at `apps/silmari_memory_rust/src/cli.rs:52-62`.

The implementation initializes or opens the target native DB and imports a Beads-shaped source at `apps/silmari_memory_rust/src/importer.rs:77-98`. The lower-level merge-style function is `import_beads_box_into_conn()`, which imports into an existing native SQLite connection at `importer.rs:182-271`.

This path is for Beads-shaped SQLite sources with `issues`, labels, dependencies, and optional keyword entries. It is not a native-to-native merge command.

For a YouTube-generated store, this path only fits if the generated output is a legacy Beads-shaped store. That legacy path is not the preferred transcript validation path: the v2 README records that legacy `br` import-only can report green transcript results while stock SQLite rejects the DB as malformed at `scripts/kc-baker-pipeline-v2/README.md:132-138`.

### Verified legacy snapshot into native DB

The Rust CLI also exposes:

```bash
silmari_memory_rust create-snapshot --source-root <legacy-root> --snapshot-root <snapshot-root> --json
silmari_memory_rust import-snapshot --snapshot-manifest <manifest> --target-db <native.sqlite> --report-dir <reports> --replace --json
```

The CLI arguments are defined at `apps/silmari_memory_rust/src/cli.rs:63-85`.

The implementation validates replace safety, imports snapshot Beads DBs into a staging DB, writes reports, then promotes the staging DB to the target path at `apps/silmari_memory_rust/src/importer.rs:100-175`. `validate_replace_safety()` rejects an existing target unless `--replace` is passed at `apps/silmari_memory_rust/src/migration.rs:144-163`.

This is a migration/cutover import for legacy snapshots. It is not a native-to-native merge of a generated YouTube store into an existing live native store.

### Viewer export

The Rust CLI exposes:

```bash
silmari_memory_rust export-viewer --db <native.sqlite> --output <beads.sqlite3> --mode compat --replace --json
```

The CLI arguments are defined at `apps/silmari_memory_rust/src/cli.rs:165-177`.

This creates a viewer cache from a native DB. It is an export surface, not an import/merge surface.

## Edge Persistence and Viewer Caveat

Silmari's MCP edge layer currently stores typed edges as labels on source cards:

- `edges.ts` states that edges are stored as `ref:<type>:<target-bead-id>` labels at `apps/silmari-mcp/src/lib/edges.ts:1-19`.
- `addEdge()` writes a `ref` label with `brLabelAdd()` at `edges.ts:79-117`.
- `commitLink()` commits a pending proposal by calling `addEdge()` and then flushing at `edges.ts:327-375`.
- `brLabelAdd()` routes native-primary label writes through `NativeCliAdapter.labelAddCompat()` at `apps/silmari-mcp/src/lib/br-adapter.ts:405-413`.

The native Rust store also has a `card_edges` table, and native viewer export reads from `card_edges`:

- `card_edges` is part of the native schema in `apps/silmari_memory_rust/src/schema.rs`.
- Viewer export selects native edges from `card_edges` in `apps/silmari_memory_rust/src/export.rs:413`.
- Legacy Beads import parses `ref:*` labels into native `card_edges` at `apps/silmari_memory_rust/src/importer.rs:245-254`.

The live native-primary MCP path and the Beads-import path therefore differ: live `addEdge()` writes labels, while Beads import can convert labels into native `card_edges`.

RedGorge reported in Agent Mail message 944 that a full native-primary bundle run had 935 cards and 1,316 committed Gate B proposal edges in `link-proposals.jsonl`, but the native DB had zero rows in `card_edges`, causing native Rust viewer export to show zero edges until cache-side edge import was applied. That operational result matches the code paths above and is relevant to graph viewing/export from generated stores.

## Step 8 and Validation Outputs

`scripts/kc-baker-pipeline-v2/extract/step8-aggregate.ts` summarizes successful `ingest-report.json` files and non-empty `failure-report.json` files:

- It reads reports/failures at `step8-aggregate.ts:83-119`.
- It totals cards, Gate B edges, and Gate B token telemetry at `step8-aggregate.ts:121-160`.
- It writes `$EXTRACTED_DIR/step8-aggregate.json` at `step8-aggregate.ts:172-173`.

Recent Agent Mail validation context:

- RedGorge message 939: cached native-primary bundle run at commit `7438aed` completed 15/15, 929 cards, 1,342 Gate B edges, 21 bundles submitted.
- RedGorge message 940: fail-fast bundle-failure commit `a26c3b3` completed 15/15, 929 cards, 1,316 Gate B edges, 21 bundles submitted.
- RedGorge message 944: viewer cache workaround was needed because committed Gate B edges were in proposal logs, not native `card_edges`.

These are validation observations, not separate source files.

## Historical Context

Relevant prior notes and plans:

- `thoughts/searchable/shared/plans/2026-04-22-tdd-silmari-cascade-extractor.md` defines the multi-pass transcript-to-Zettelkasten cascade.
- `thoughts/searchable/shared/handoffs/general/2026-04-23_09-33-07_kc-baker-pipeline-resume-after-cascade-lands.md` names the YouTube transcriber output directories as the source transcript locations.
- `thoughts/searchable/shared/research/2026-04-29-deterministic-cascade-import-boundary.md` documents why cached cascade JSON should use deterministic import rather than normal MCP save-card paths.
- `thoughts/searchable/shared/plans/2026-04-29-tdd-deterministic-cascade-import-writer.md` tracks the landed import-only / after-import / enrich-only boundary.
- `thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md` tracks native-primary runtime modes, snapshot/import, and viewer export work.

The exact phrase "generated memory store" was not found in the searched `thoughts/` context. The closest current concepts are generated transcript artifacts, cached cascade extraction JSON, deterministic import reports, native-primary target stores, and legacy Beads/native snapshot import.

## Current Gaps Found

No single CLI or script was found that accepts a YouTube URL and performs the full sequence:

1. Transcribe video or playlist.
2. Stage transcript text and metadata for cascade extraction.
3. Run Pass 1, Pass 2, Pass 3, Gate A, and Fix.
4. Import into a configured native-primary Silmari store.
5. Optionally run enrichment/Gate B.
6. Produce a user-facing import report and viewer/export artifact.

No native-to-native merge command was found for "generated native store into existing native store." The current matching path is direct import into the target native DB selected by `nativeDbPath`.

The current Docker compose path mounts transcript text output but not the Whisper metadata directory, so it does not use higher-resolution segment provenance unless `TRANSCRIPTS_METADATA_DIR` is supplied separately.

The cascade defaults remain KC Baker-specific in several places: compose sets `PERSON_SLUG=kc-baker` and `PERSON_LABEL="KC Baker"` at `docker-compose.yml:12-13`, and ingest defaults `PERSON_SLUG` to `kc-baker` at `ingest-cascade.ts:1747`.

The transcriber is configured by editing Python constants rather than by command-line URL arguments.

Live native-primary committed edges currently require care for viewer/export because the MCP edge layer writes `ref:*` labels while Rust viewer export reads `card_edges`.

## Core Permalinks

- Transcriber configuration and processing loop: <https://github.com/Dicklesworthstone/bulk_transcribe_youtube_videos_from_playlist/blob/ae3fb76e6f839a0aebe31177a829255f69783eef/bulk_transcribe_youtube_videos_from_playlist.py#L22-L241>
- Cascade segment loader: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/scripts/kc-baker-pipeline-v2/extract/segments.ts#L10-L124>
- Native-primary cached import docs: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/scripts/kc-baker-pipeline-v2/README.md#L91-L150>
- Ingest mode orchestration: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/scripts/kc-baker-pipeline-v2/ingest/ingest-cascade.ts#L1720-L1879>
- Native runtime mode resolver: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/apps/silmari-mcp/src/lib/native-mode.ts#L6-L210>
- Rust import commands: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/apps/silmari_memory_rust/src/cli.rs#L52-L85>
- Beads import implementation: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/apps/silmari_memory_rust/src/importer.rs#L77-L175>
- Edge label commit path: <https://github.com/tha-hammer/silmari-agent-memory/blob/2caa9430d03aa15c6f43039e2de3dcb9e88011f4/apps/silmari-mcp/src/lib/edges.ts#L327-L375>
