import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const scriptPath = path.resolve(__dirname, '../src/automation_script/automation.js');
const selectorsFixtureUrl = pathToFileURL(
  path.resolve(__dirname, '../tests/fixtures/automation/selectors.html')
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
