import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const scriptPath = path.resolve(__dirname, '../src/automation_script/automation.js');
const selectorsFixtureUrl = pathToFileURL(
  path.resolve(__dirname, '../tests/fixtures/automation/selectors.html')
).toString();
const actionabilityFixtureUrl = pathToFileURL(
  path.resolve(__dirname, '../tests/fixtures/automation/actionability.html')
).toString();

test('automation injected script source is wired into the Playwright harness', async () => {
  const source = await readFile(scriptPath, 'utf8');

  expect(source).toContain('__zbAutomation');
});

test.describe('selector engine', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(selectorsFixtureUrl);
    await page.addScriptTag({ path: scriptPath });
  });

  async function handle(page, command) {
    return page.evaluate((payload) => globalThis.__zbAutomation.handle(payload), command);
  }

  test('resolves Phase 1 selector prefixes to serializable element summaries', async ({ page }) => {
    const cases = [
      { selector: 'role=button[name="Save"]', tag: 'button', text: 'Save' },
      { selector: 'testid=send-message-btn', tag: 'button', text: 'Send' },
      { selector: 'text=Follow', tag: 'button', text: 'Follow' },
      { selector: 'css=[aria-label="Comment"]', tag: 'button', text: 'Comment' },
      { selector: 'xpath=//button[@data-case="xpath"]', tag: 'button', text: 'XPath' },
    ];

    for (const item of cases) {
      const result = await handle(page, {
        op: 'query',
        selector: item.selector,
        trace_id: 'trace-selector',
        command_id: 'cmd-selector',
        parent_span_id: 'span-root',
      });

      expect(result.ok).toBe(true);
      expect(result.value.elements.length).toBeGreaterThan(0);
      const element = result.value.elements[0];
      expect(Object.keys(element).sort()).toEqual(['bbox', 'id', 'tag', 'text']);
      expect(element.tag).toBe(item.tag);
      expect(element.text).toContain(item.text);
      expect(element.bbox.width).toBeGreaterThan(0);
      expect(element.bbox.height).toBeGreaterThan(0);
    }
  });

  test('enforces strict mode for zero, one, and multiple matches', async ({ page }) => {
    const zero = await handle(page, { op: 'query', selector: 'text=Missing', strict: true });
    expect(zero.ok).toBe(false);
    expect(zero.error).toBe('element_not_found');
    expect(zero.data.reason).toBe('strict_zero');

    const one = await handle(page, { op: 'query', selector: 'testid=send-message-btn', strict: true });
    expect(one.ok).toBe(true);
    expect(one.value.elements).toHaveLength(1);

    const multiple = await handle(page, { op: 'query', selector: 'text=Follow', strict: true });
    expect(multiple.ok).toBe(false);
    expect(multiple.error).toBe('element_not_found');
    expect(multiple.data.reason).toBe('strict_multiple');
  });

  test('rejects malformed selector prefixes', async ({ page }) => {
    const result = await handle(page, { op: 'query', selector: 'label=Save' });

    expect(result.ok).toBe(false);
    expect(result.error).toBe('element_not_found');
    expect(result.data.reason).toBe('malformed_selector');
  });

  test('returns getText and getAttribute values without DOM handles', async ({ page }) => {
    const text = await handle(page, { op: 'getText', selector: 'testid=send-message-btn' });
    expect(text).toEqual({ ok: true, value: { text: 'Send' }, telemetry: expect.any(Array) });

    const attr = await handle(page, { op: 'getAttribute', selector: 'css=[aria-label="Comment"]', name: 'aria-label' });
    expect(attr).toEqual({ ok: true, value: { value: 'Comment' }, telemetry: expect.any(Array) });
  });

  test('emits redacted selector telemetry drafts', async ({ page }) => {
    const result = await handle(page, {
      op: 'query',
      selector: 'css=[aria-label="Comment"]',
      strict: true,
      trace_id: 'trace-abc',
      command_id: 'cmd-abc',
      parent_span_id: 'span-root',
    });

    expect(result.ok).toBe(true);
    expect(result.telemetry).toHaveLength(1);
    const span = result.telemetry[0];
    expect(span.name).toBe('automation.selector.resolve');
    expect(span.trace_id).toBe('trace-abc');
    expect(span.command_id).toBe('cmd-abc');
    expect(span.parent_span_id).toBe('span-root');
    expect(span.attributes['selector.kind']).toBe('css');
    expect(span.attributes['selector.hash']).toBeTruthy();
    expect(span.attributes['selector.strict']).toBe('true');
    expect(span.attributes['selector.match_count']).toBe('1');
    expect(span.attributes.duration_ms).toBeGreaterThanOrEqual(0);

    const serializedAttrs = JSON.stringify(span.attributes);
    expect(serializedAttrs).not.toContain('css=[aria-label="Comment"]');
    expect(serializedAttrs).not.toContain('Comment');
  });
});

test.describe('actionability checks', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(actionabilityFixtureUrl);
    await page.addScriptTag({ path: scriptPath });
  });

  async function handle(page, command) {
    return page.evaluate((payload) => globalThis.__zbAutomation.handle(payload), command);
  }

  test('blocks mutating actions until elements are actionable', async ({ page }) => {
    const cases = [
      { op: 'click', selector: 'testid=hidden-button', error: 'element_not_visible', check: 'visible' },
      { op: 'click', selector: 'testid=moving-button', error: 'element_not_stable', check: 'stable' },
      { op: 'click', selector: 'testid=obscured-button', error: 'element_obscured', check: 'receives-events' },
      { op: 'click', selector: 'testid=disabled-button', error: 'element_disabled', check: 'enabled' },
      { op: 'fill', selector: 'testid=readonly-input', value: 'blocked', error: 'element_not_editable', check: 'editable' },
      { op: 'type', selector: 'testid=readonly-input', text: 'blocked', error: 'element_not_editable', check: 'editable' },
    ];

    for (const item of cases) {
      const result = await handle(page, {
        op: item.op,
        selector: item.selector,
        value: item.value,
        text: item.text,
        trace_id: 'trace-action',
        command_id: 'cmd-action',
        parent_span_id: 'span-root',
      });

      expect(result.ok).toBe(false);
      expect(result.error).toBe(item.error);
      expect(result.data.failed_check).toBe(item.check);
    }

    const detached = await handle(page, { op: 'click', selector: 'testid=detached-button' });
    expect(detached.ok).toBe(false);
    expect(detached.error).toBe('element_not_found');
  });

  test('trial mode creates no side effects and force bypasses checks', async ({ page }) => {
    const trial = await handle(page, {
      op: 'click',
      selector: 'testid=ready-button',
      options: { trial: true },
    });
    expect(trial.ok).toBe(true);
    expect(await page.evaluate(() => globalThis.__fixtureLog)).toEqual([]);

    const click = await handle(page, {
      op: 'click',
      selector: 'testid=ready-button',
    });
    expect(click.ok).toBe(true);
    expect(await page.evaluate(() => globalThis.__fixtureLog.includes('ready:click'))).toBe(true);

    const forceFill = await handle(page, {
      op: 'fill',
      selector: 'testid=readonly-input',
      value: 'forced',
      options: { force: true },
    });
    expect(forceFill.ok).toBe(true);
    expect(await page.locator('[data-testid="readonly-input"]').inputValue()).toBe('forced');
  });

  test('emits redacted actionability telemetry', async ({ page }) => {
    const result = await handle(page, {
      op: 'fill',
      selector: 'testid=readonly-input',
      value: 'password=abc',
      trace_id: 'trace-action',
      command_id: 'cmd-action',
      parent_span_id: 'span-root',
    });

    expect(result.ok).toBe(false);
    const span = result.telemetry.find((item) => item.name === 'automation.actionability.check');
    expect(span).toBeTruthy();
    expect(span.trace_id).toBe('trace-action');
    expect(span.command_id).toBe('cmd-action');
    expect(span.parent_span_id).toBe('span-root');
    expect(span.attributes['action.name']).toBe('fill');
    expect(span.attributes['actionability.check']).toBe('editable');
    expect(span.attributes['actionability.passed']).toBe('false');
    expect(span.attributes['actionability.failed_check']).toBe('editable');
    expect(span.attributes['bbox.width']).toBeGreaterThanOrEqual(0);
    expect(span.attributes['bbox.height']).toBeGreaterThanOrEqual(0);

    const serialized = JSON.stringify(span.attributes);
    expect(serialized).not.toContain('testid=readonly-input');
    expect(serialized).not.toContain('password=abc');
    expect(serialized).not.toContain('<input');
  });
});

test.describe('DOM actions and wait primitives', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(actionabilityFixtureUrl);
    await page.addScriptTag({ path: scriptPath });
  });

  async function handle(page, command) {
    return page.evaluate((payload) => globalThis.__zbAutomation.handle(payload), command);
  }

  test('click dispatches pointer and mouse events in order', async ({ page }) => {
    await page.evaluate(() => { globalThis.__fixtureLog = []; });

    const result = await handle(page, { op: 'click', selector: 'testid=ready-button' });

    expect(result.ok).toBe(true);
    expect(await page.evaluate(() => globalThis.__fixtureLog)).toEqual([
      'ready:pointerdown',
      'ready:mousedown',
      'ready:pointerup',
      'ready:mouseup',
      'ready:click',
    ]);
  });

  test('fill focuses, clears, sets value, and dispatches input/change', async ({ page }) => {
    await page.evaluate(() => { globalThis.__fixtureLog = []; });

    const result = await handle(page, { op: 'fill', selector: 'testid=editable-input', value: 'new value' });

    expect(result.ok).toBe(true);
    expect(await page.locator('[data-testid="editable-input"]').inputValue()).toBe('new value');
    expect(await page.evaluate(() => globalThis.__fixtureLog)).toEqual([
      'editable:focus',
      'editable:input:new value',
      'editable:change:new value',
    ]);
  });

  test('type dispatches keydown/input/keyup per character', async ({ page }) => {
    await page.evaluate(() => { globalThis.__fixtureLog = []; });

    const result = await handle(page, { op: 'type', selector: 'testid=type-input', text: 'ab' });

    expect(result.ok).toBe(true);
    expect(await page.locator('[data-testid="type-input"]').inputValue()).toBe('ab');
    expect(await page.evaluate(() => globalThis.__fixtureLog)).toEqual([
      'type:keydown:a',
      'type:input:a',
      'type:keyup:a',
      'type:keydown:b',
      'type:input:b',
      'type:keyup:b',
    ]);
  });

  test('waitFor resolves attached, visible, hidden, and detached states with cleanup', async ({ page }) => {
    await page.evaluate(() => {
      setTimeout(() => globalThis.__attachDynamic(), 25);
    });
    expect((await handle(page, { op: 'waitFor', selector: 'testid=dynamic-target', state: 'attached', timeout_ms: 500 })).ok).toBe(true);

    await page.evaluate(() => {
      setTimeout(() => globalThis.__showDynamic(), 25);
    });
    expect((await handle(page, { op: 'waitFor', selector: 'testid=dynamic-target', state: 'visible', timeout_ms: 500 })).ok).toBe(true);

    await page.evaluate(() => {
      setTimeout(() => globalThis.__hideDynamic(), 25);
    });
    expect((await handle(page, { op: 'waitFor', selector: 'testid=dynamic-target', state: 'hidden', timeout_ms: 500 })).ok).toBe(true);

    await page.evaluate(() => {
      setTimeout(() => globalThis.__detachDynamic(), 25);
    });
    expect((await handle(page, { op: 'waitFor', selector: 'testid=dynamic-target', state: 'detached', timeout_ms: 500 })).ok).toBe(true);

    expect(await page.evaluate(() => globalThis.__zbAutomation.debugOutstandingWaits())).toBe(0);
  });

  test('waitFor times out on a never-appearing selector and cleans up', async ({ page }) => {
    const result = await handle(page, {
      op: 'waitFor',
      selector: 'testid=never-appears',
      state: 'attached',
      timeout_ms: 50,
    });

    expect(result.ok).toBe(false);
    expect(result.error).toBe('element_not_found');
    expect(result.data.reason).toBe('timeout');
    expect(await page.evaluate(() => globalThis.__zbAutomation.debugOutstandingWaits())).toBe(0);
  });
});
