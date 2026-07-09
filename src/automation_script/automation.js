(function installZigBrowserAutomation(globalScope) {
  let nextElementId = 1;
  let nextSpanId = 1;
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
    return success({ text: elementText(resolved.elements[0]) }, resolved.telemetry);
  }

  function getAttribute(command) {
    if (typeof command.name !== 'string' || command.name.length === 0) {
      return failure('missing_attribute_name', command, [], false);
    }
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    return success({ value: resolved.elements[0].getAttribute(command.name) }, resolved.telemetry);
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
      elements = resolveSelector(parsed.kind, parsed.body).filter(isElementVisibleEnough);
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
        'attempt.index': '0',
        'script.world': 'automation',
        'result.status': status,
        duration_ms: Math.max(0, nowMs() - started)
      }
    };
  }

  function hashText(text) {
    let hash = 2166136261;
    for (let i = 0; i < text.length; i += 1) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
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
    return Math.round(value * 100) / 100;
  }

  function nowMs() {
    return Math.round(performance.now());
  }

  Object.defineProperty(globalScope, '__zbAutomation', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: {
      version: 'phase1-m3-selector-engine',
      handle
    }
  });
})(globalThis);
