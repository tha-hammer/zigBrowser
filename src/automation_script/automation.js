(function installZigBrowserAutomation(globalScope) {
  const DEFAULT_WAIT_TIMEOUT_MS = 30000;
  const WAIT_POLL_INTERVAL_MS = 16;
  const VALID_WAIT_STATES = ['attached', 'visible', 'hidden', 'detached'];
  const RATE_LIMIT_MODAL_SELECTORS = [
    '[role="dialog"][aria-modal="true"]',
    '.artdeco-modal',
    '[role="alertdialog"]'
  ];
  const RATE_LIMIT_TEXT_PATTERN = /limit|restrict|block|captcha|verify/i;
  const RATE_LIMIT_PATH_PATTERN = /challenge|captcha|checkpoint/i;
  const RATE_LIMIT_TEXT_HASH_LIMIT = 200;
  const RATE_LIMIT_MODAL_CONFIDENCE = 0.9;
  const RATE_LIMIT_CHALLENGE_CONFIDENCE = 0.95;
  const FNV_OFFSET_BASIS_32 = 2166136261;
  const FNV_PRIME_32 = 16777619;
  const BBOX_DECIMAL_SCALE = 100;
  const MAX_ATTEMPT_INDEX = 0xffffffff; // engine sends a u32

  let nextElementId = 1;
  let nextSpanId = 1;
  let outstandingWaits = 0;
  const elementIds = new WeakMap();

  function handle(input) {
    const command = typeof input === 'string' ? JSON.parse(input) : input;
    if (!command || typeof command !== 'object') {
      return failure('malformed_command', {}, [], true);
    }

    switch (command.op) {
      case 'query':
        return query(command);
      case 'getText':
        return getText(command);
      case 'getAttribute':
        return getAttribute(command);
      case 'click':
        return runAction(command, 'click');
      case 'fill':
        return runAction(command, 'fill');
      case 'type':
        return runAction(command, 'type');
      case 'waitFor':
        return waitFor(command);
      case 'rateLimitScan':
        return rateLimitScan(command);
      default:
        return failure('unknown_op', command, [], false);
    }
  }

  function query(command) {
    const resolved = resolveForCommand(command);
    if (!resolved.ok) return resolved.response;
    return success({ elements: resolved.elements.map(summarizeElement) }, resolved.telemetry);
  }

  function getText(command) {
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
    return success({ text: elementText(resolved.elements[0]) }, resolved.telemetry);
  }

  function getAttribute(command) {
    if (typeof command.name !== 'string' || command.name.length === 0) {
      return failure('missing_attribute_name', command, [], false);
    }
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
    return success({ value: resolved.elements[0].getAttribute(command.name) }, resolved.telemetry);
  }

  function runAction(command, action) {
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);

    const element = resolved.elements[0];
    const options = command.options || {};
    const force = options.force === true || command.force === true;
    const trial = options.trial === true || command.trial === true;
    const telemetry = resolved.telemetry.slice();

    if (!force) {
      const check = runActionabilityChecks(element, action);
      telemetry.push(actionabilitySpan(command, action, check));
      if (!check.passed) {
        return actionFailure(check.error, check.check, telemetry);
      }
    } else {
      telemetry.push(actionabilitySpan(command, action, {
        check: 'force',
        passed: true,
        error: null,
        bbox: element.getBoundingClientRect()
      }));
    }

    if (trial) return success({ ok: true }, telemetry);

    if (action === 'click') synthesizeClick(element);
    if (action === 'fill') synthesizeFill(element, command.value || '');
    if (action === 'type') synthesizeType(element, command.text || '');
    return success({ ok: true }, telemetry);
  }

  function waitFor(command) {
    const parsed = parseSelector(command.selector);
    const strict = command.strict === true;
    const state = command.state || 'visible';
    const timeoutMs = typeof command.timeout_ms === 'number' ? command.timeout_ms : DEFAULT_WAIT_TIMEOUT_MS;
    const started = nowMs();

    if (!parsed.ok || !VALID_WAIT_STATES.includes(state)) {
      const telemetry = [selectorSpan(command, parsed.ok ? parsed.kind : 'unknown', strict, 0, started, 'error')];
      return failure('malformed_selector', command, telemetry, true);
    }

    outstandingWaits += 1;
    return new Promise((resolve) => {
      let settled = false;
      let intervalId = null;
      let timeoutId = null;
      const observer = new MutationObserver(check);

      function cleanup() {
        if (intervalId !== null) clearInterval(intervalId);
        if (timeoutId !== null) clearTimeout(timeoutId);
        observer.disconnect();
        outstandingWaits -= 1;
      }

      function finish(response) {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(response);
      }

      function check() {
        let elements;
        try {
          elements = resolveSelector(parsed.kind, parsed.body);
        } catch (_) {
          const telemetry = [selectorSpan(command, parsed.kind, strict, 0, started, 'error')];
          finish(failure('malformed_selector', command, telemetry, true));
          return;
        }

        if (strict && elements.length > 1) {
          const telemetry = [selectorSpan(command, parsed.kind, strict, elements.length, started, 'error')];
          finish(failure('strict_multiple', command, telemetry, true));
          return;
        }

        if (waitStateSatisfied(elements, state)) {
          const telemetry = [selectorSpan(command, parsed.kind, strict, elements.length, started, 'ok')];
          finish(success({ ok: true }, telemetry));
        }
      }

      observer.observe(document.documentElement, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ['class', 'hidden', 'style']
      });
      intervalId = setInterval(check, WAIT_POLL_INTERVAL_MS);
      timeoutId = setTimeout(() => {
        const telemetry = [selectorSpan(command, parsed.kind, strict, 0, started, 'error')];
        finish(failure('timeout', command, telemetry, true));
      }, timeoutMs);
      check();
    });
  }

  function rateLimitScan(command) {
    const platform = (command.options && command.options.platform) || 'unknown';
    const signals = [];
    for (let i = 0; i < RATE_LIMIT_MODAL_SELECTORS.length; i++) {
      const modal = document.querySelector(RATE_LIMIT_MODAL_SELECTORS[i]);
      if (modal) {
        const text = modal.textContent || '';
        if (RATE_LIMIT_TEXT_PATTERN.test(text)) {
          signals.push({
            kind: 'modal',
            text_hash: hashText(text.trim().substring(0, RATE_LIMIT_TEXT_HASH_LIMIT)),
            confidence: RATE_LIMIT_MODAL_CONFIDENCE
          });
        }
      }
    }
    if (RATE_LIMIT_PATH_PATTERN.test(document.location.pathname)) {
      signals.push({ kind: 'challenge', text_hash: '', confidence: RATE_LIMIT_CHALLENGE_CONFIDENCE });
    }
    if (signals.length > 0) {
      return { ok: false, error: 'platform_rate_limited', retryable: false, data: { signal: signals[0].kind, platform: platform, signals: signals } };
    }
    return { ok: true, value: { signals: [] }, telemetry: [] };
  }

  function waitStateSatisfied(elements, state) {
    if (state === 'attached') return elements.length > 0;
    if (state === 'detached') return elements.length === 0;
    if (state === 'visible') return elements.some(isElementVisibleEnough);
    if (state === 'hidden') return elements.length === 0 || elements.every((element) => !isElementVisibleEnough(element));
    return false;
  }

  function runActionabilityChecks(element, action) {
    if (!element || !element.isConnected) return failedCheck(element, 'attached', 'element_not_found');
    if (!isElementVisibleEnough(element)) return failedCheck(element, 'visible', 'element_not_visible');
    if (element.getAttribute('data-moving') === 'true') return failedCheck(element, 'stable', 'element_not_stable');
    if (!receivesEvents(element)) return failedCheck(element, 'receives-events', 'element_obscured');
    if (isDisabled(element)) return failedCheck(element, 'enabled', 'element_disabled');
    if ((action === 'fill' || action === 'type') && !isEditable(element)) {
      return failedCheck(element, 'editable', 'element_not_editable');
    }
    return { check: 'all', passed: true, error: null, bbox: element.getBoundingClientRect() };
  }

  function failedCheck(element, check, error) {
    return {
      check,
      passed: false,
      error,
      bbox: element ? element.getBoundingClientRect() : emptyRect()
    };
  }

  function receivesEvents(element) {
    const rect = element.getBoundingClientRect();
    const top = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
    return top === element || (top && element.contains(top));
  }

  function isDisabled(element) {
    return element.disabled === true || element.getAttribute('aria-disabled') === 'true';
  }

  function isEditable(element) {
    if (element.isContentEditable) return true;
    const tag = element.tagName.toLowerCase();
    if (tag !== 'input' && tag !== 'textarea') return false;
    if (isDisabled(element)) return false;
    return element.readOnly !== true;
  }

  function synthesizeClick(element) {
    for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
      element.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: globalScope }));
    }
  }

  function synthesizeFill(element, value) {
    element.focus();
    element.value = value;
    element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function synthesizeType(element, text) {
    element.focus();
    for (const char of text) {
      element.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: char }));
      element.value = (element.value || '') + char;
      element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: char }));
      element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: char }));
    }
  }

  function resolveForCommand(command) {
    const started = nowMs();
    const strict = command.strict === true;
    const parsed = parseSelector(command.selector);
    if (!parsed.ok) {
      const telemetry = [selectorSpan(command, 'unknown', strict, 0, started, 'error')];
      return { ok: false, response: failure('malformed_selector', command, telemetry, true) };
    }

    let elements;
    try {
      elements = resolveSelector(parsed.kind, parsed.body);
    } catch (_) {
      const telemetry = [selectorSpan(command, parsed.kind, strict, 0, started, 'error')];
      return { ok: false, response: failure('malformed_selector', command, telemetry, true) };
    }

    const telemetry = [selectorSpan(command, parsed.kind, strict, elements.length, started, 'ok')];
    if (strict && elements.length === 0) {
      return { ok: false, response: failure('strict_zero', command, telemetry, true) };
    }
    if (strict && elements.length > 1) {
      return { ok: false, response: failure('strict_multiple', command, telemetry, true) };
    }

    return { ok: true, elements, telemetry };
  }

  function parseSelector(selector) {
    if (typeof selector !== 'string') return { ok: false };
    const index = selector.indexOf('=');
    if (index <= 0) return { ok: false };
    const kind = selector.slice(0, index);
    const body = selector.slice(index + 1);
    if (!['role', 'testid', 'text', 'css', 'xpath'].includes(kind) || body.length === 0) {
      return { ok: false };
    }
    return { ok: true, kind, body };
  }

  function resolveSelector(kind, body) {
    switch (kind) {
      case 'role':
        return resolveRole(body);
      case 'testid':
        return Array.from(document.querySelectorAll('[data-testid="' + cssEscape(body) + '"]'));
      case 'text':
        return allCandidateElements().filter((element) => elementText(element) === body);
      case 'css':
        return Array.from(document.querySelectorAll(body));
      case 'xpath':
        return resolveXPath(body);
      default:
        return [];
    }
  }

  function resolveRole(body) {
    const match = body.match(/^([a-zA-Z0-9_-]+)(?:\[name=(?:"([^"]*)"|'([^']*)'|([^\]]+))\])?$/);
    if (!match) throw new Error('malformed role selector');
    const role = match[1];
    const name = match[2] || match[3] || match[4] || null;
    return allCandidateElements().filter((element) => {
      if (elementRole(element) !== role) return false;
      if (name == null) return true;
      return accessibleName(element) === name;
    });
  }

  function resolveXPath(body) {
    const snapshot = document.evaluate(
      body,
      document,
      null,
      XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
      null
    );
    const results = [];
    for (let i = 0; i < snapshot.snapshotLength; i += 1) {
      const node = snapshot.snapshotItem(i);
      if (node && node.nodeType === Node.ELEMENT_NODE) results.push(node);
    }
    return results;
  }

  function allCandidateElements() {
    return Array.from(document.querySelectorAll('body *'));
  }

  function elementRole(element) {
    const explicit = element.getAttribute('role');
    if (explicit) return explicit;
    const tag = element.tagName.toLowerCase();
    if (tag === 'button') return 'button';
    if (tag === 'a' && element.hasAttribute('href')) return 'link';
    if (tag === 'input') return 'textbox';
    return tag;
  }

  function accessibleName(element) {
    return normalizeText(element.getAttribute('aria-label') || element.textContent || '');
  }

  function elementText(element) {
    return accessibleName(element);
  }

  function summarizeElement(element) {
    const rect = element.getBoundingClientRect();
    return {
      id: elementId(element),
      tag: element.tagName.toLowerCase(),
      text: elementText(element),
      bbox: {
        x: round(rect.x),
        y: round(rect.y),
        width: round(rect.width),
        height: round(rect.height)
      }
    };
  }

  function elementId(element) {
    const existing = elementIds.get(element);
    if (existing) return existing;
    const id = 'zb-auto-' + nextElementId++;
    elementIds.set(element, id);
    return id;
  }

  function isElementVisibleEnough(element) {
    if (element.hidden === true) return false;
    const rect = element.getBoundingClientRect();
    const style = globalScope.getComputedStyle(element);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none';
  }

  function success(value, telemetry) {
    return { ok: true, value, telemetry };
  }

  function failure(reason, command, telemetry, retryable) {
    return {
      ok: false,
      error: 'element_not_found',
      retryable,
      data: { reason },
      telemetry
    };
  }

  function actionFailure(error, failedCheckName, telemetry) {
    return {
      ok: false,
      error,
      retryable: true,
      data: {
        reason: failedCheckName,
        failed_check: failedCheckName
      },
      telemetry
    };
  }

  function selectorSpan(command, kind, strict, matchCount, started, status) {
    return {
      name: 'automation.selector.resolve',
      trace_id: command.trace_id || '',
      span_id: 'script-span-' + nextSpanId++,
      parent_span_id: command.parent_span_id || '',
      command_id: command.command_id || '',
      attributes: {
        'selector.kind': kind,
        'selector.hash': hashText(command.selector || ''),
        'selector.strict': strict ? 'true' : 'false',
        'selector.match_count': String(matchCount),
        'dom.frame_depth': '0',
        'attempt.index': attemptIndex(command),
        'script.world': 'automation',
        'result.status': status,
        duration_ms: Math.max(0, nowMs() - started)
      }
    };
  }

  function actionabilitySpan(command, action, check) {
    const rect = check.bbox || emptyRect();
    return {
      name: 'automation.actionability.check',
      trace_id: command.trace_id || '',
      span_id: 'script-span-' + nextSpanId++,
      parent_span_id: command.parent_span_id || '',
      command_id: command.command_id || '',
      attributes: {
        'action.name': action,
        'action.force': String((command.options && command.options.force === true) || command.force === true),
        'action.trial': String((command.options && command.options.trial === true) || command.trial === true),
        'actionability.check': check.check,
        'attempt.index': attemptIndex(command),
        'actionability.required_checks': requiredChecks(action).join(','),
        'actionability.passed': check.passed ? 'true' : 'false',
        'actionability.failed_check': check.passed ? '' : check.check,
        'bbox.width': round(rect.width),
        'bbox.height': round(rect.height),
        'result.status': check.passed ? 'ok' : 'error',
        'automation.error': check.error || ''
      }
    };
  }

  function attemptIndex(command) {
    const index = command.attempt_index;
    return Number.isInteger(index) && index >= 0 && index <= MAX_ATTEMPT_INDEX ? String(index) : '0';
  }

  function requiredChecks(action) {
    const checks = ['attached', 'visible', 'stable', 'receives-events', 'enabled'];
    if (action === 'fill' || action === 'type') checks.push('editable');
    return checks;
  }

  function hashText(text) {
    let hash = FNV_OFFSET_BASIS_32;
    for (let i = 0; i < text.length; i += 1) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, FNV_PRIME_32);
    }
    return (hash >>> 0).toString(16);
  }

  function normalizeText(text) {
    return text.replace(/\s+/g, ' ').trim();
  }

  function cssEscape(text) {
    if (globalScope.CSS && typeof globalScope.CSS.escape === 'function') {
      return globalScope.CSS.escape(text);
    }
    return text.replace(/["\\]/g, '\\$&');
  }

  function round(value) {
    return Math.round(value * BBOX_DECIMAL_SCALE) / BBOX_DECIMAL_SCALE;
  }

  function emptyRect() {
    return { width: 0, height: 0, left: 0, top: 0, x: 0, y: 0 };
  }

  function nowMs() {
    return Math.round(performance.now());
  }

  Object.defineProperty(globalScope, '__zbAutomation', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: {
      version: 'phase1-m4-actionability',
      handle,
      debugOutstandingWaits() {
        return outstandingWaits;
      }
    }
  });
})(globalThis);
