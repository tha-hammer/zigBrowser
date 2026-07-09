import { expect, test } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const scriptPath = path.resolve(__dirname, '../src/automation_script/automation.js');

test('automation injected script source is wired into the Playwright harness', async () => {
  const source = await readFile(scriptPath, 'utf8');

  expect(source).toContain('__zbAutomation');
});

test.skip('selector behavior is implemented in Behavior M3', async () => {
  // Behavior M3 replaces this scope guard with DOM selector assertions.
});
