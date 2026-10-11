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
  const FILES_SETTLE_MS = 2000;

  // Trusted-input acknowledgement: native (GDK) events reach the page
  // asynchronously, so callers compare these counts before and after sending
  // events to know the page has handled them. Counted in this isolated world.
  // Only trusted (real input) events count, so a page dispatching synthetic
  // keyup/mouseup cannot make a wait finish early.
  // `doc` identifies this document: input that navigates lands in a new
  // document whose counters start again at zero, which callers must treat as
  // delivered rather than wait for counts that will never come.
  const inputAck = { doc: randomDocumentId(), mouseup: 0, keyup: 0, click: 0, wheel: 0, moveX: -1, moveY: -1, scrolls: 0, lastScrollAt: -1, navigations: 0, pending: null };
  function randomDocumentId() {
    const bytes = new Uint8Array(8);
    globalScope.crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  }
  globalScope.addEventListener('mouseup', (event) => { if (event.isTrusted) inputAck.mouseup += 1; }, true);
  globalScope.addEventListener('keyup', (event) => { if (event.isTrusted) inputAck.keyup += 1; }, true);
  // A form submission starts its navigation only in a later task (WebKit
  // fires 'navigate' after its policy step), so a reader could see the
  // Enter's keyup before the navigation. The trusted 'submit' event fires
  // inside the key's own default action, before its keyup: counting it as a
  // navigation makes native text stop right after that key. Only the count:
  // whether a navigation really follows (the page may prevent it, retarget
  // it or the shell may block it) is left to the 'navigate' event below,
  // which alone makes the document leaving.
  globalScope.addEventListener('submit', (event) => { if (event.isTrusted) inputAck.navigations += 1; }, true);
  globalScope.addEventListener('wheel', (event) => { if (event.isTrusted) inputAck.wheel += 1; }, { capture: true, passive: true });
  // A native move is settled once a trusted mousemove reached its position (PagePort v3.7).
  globalScope.addEventListener('mousemove', (event) => { if (event.isTrusted) { inputAck.moveX = event.clientX; inputAck.moveY = event.clientY; } }, { capture: true, passive: true });
  // Scrolling (page or any element: capture sees non-bubbling scroll
  // events) for native scroll completion: a wheel is done once its
  // scrolling has gone quiet.
  globalScope.addEventListener('scroll', () => {
    inputAck.scrolls += 1;
    inputAck.lastScrollAt = globalScope.performance.now();
  }, { capture: true, passive: true });
  // Counted when the click starts dispatching: a reader's eval cannot run in
  // the middle of that synchronous dispatch, so once it observes the count
  // every listener (and the default action) of that click has run.
  globalScope.addEventListener('click', (event) => {
    if (event.isTrusted) inputAck.click += 1;
  }, true);
  // A cross-document navigation (form submission, link, location change)
  // fires 'navigate' in this document synchronously when it starts, before
  // later input is handled. `navigations` counts those starts: native text
  // stops as soon as it changes during a sequence, instead of typing into
  // the document that replaces this one (conservative: one the page cancels
  // stops that sequence too). `pending` is the navigation still in flight,
  // so a new sequence does not start into a document that is going away.
  // It ends without a new document when it is cancelled, stopped or
  // superseded (its own signal aborts), or when the response replaces
  // nothing (204, download, policy block). For those the browser cannot
  // tell which navigation it was, so each navigation reports its
  // destination as it starts (zbNavigation, a GTK-shell handler in this
  // world) and keeps the arrival number the shell answers, on its own
  // object; the answer also says whether the shell's policy refuses that
  // destination, which ends the navigation at once. The shell's
  // navigationEnded(seq) then names everything it had heard of when the
  // load ended: it clears this document's pending navigation only if that
  // one had arrived by then. A navigation started later arrives later, and
  // one whose number is not back yet is never cleared this way
  // (conservative: refuse, never a wrong clear). The abort is bound to its
  // object too, so an older navigation's end never clears a newer one.
  if (globalScope.navigation && typeof globalScope.navigation.addEventListener === 'function') {
    globalScope.navigation.addEventListener('navigate', (event) => {
      if (event.destination && event.destination.sameDocument) return;
      const started = {};
      inputAck.navigations += 1;
      inputAck.pending = started;
      const ended = () => { if (inputAck.pending === started) inputAck.pending = null; };
      if (event.signal) {
        if (event.signal.aborted) ended();
        else event.signal.addEventListener('abort', ended);
      }
      const shell = globalScope.webkit && globalScope.webkit.messageHandlers &&
        globalScope.webkit.messageHandlers.zbNavigation;
      if (shell) {
        const destination = event.destination ? String(event.destination.url) : '';
        Promise.resolve(shell.postMessage(destination)).then((answer) => {
          if (answer && typeof answer.seq === 'number') started.seq = answer.seq;
          // The shell refuses this destination: nothing will replace us.
          if (answer && answer.blocked === true) ended();
        }, () => {});
      }
    });
  }

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
      case 'press':
        return press(command);
      case 'selectOption':
        return selectOption(command);
      case 'chooseFiles':
        return chooseFiles(command);
      case 'hover':
        return hover(command);
      case 'scroll':
        return scroll(command);
      case 'locate':
        return locate(command);
      case 'measure':
        return measure(command);
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
      // The receives-events check hit-tests the element's centre, which
      // fails outside the viewport: bring the target into view first.
      if (typeof element.scrollIntoView === 'function') element.scrollIntoView({ block: 'nearest' });
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
    if (action === 'press') synthesizePress(element, command.key, command.modifiers || []);
    return success({ ok: true }, telemetry);
  }

  // Native input (N7): resolve, scroll into view and check the target exactly
  // as the action would, optionally focus it, and return its centre in
  // viewport CSS px for the shim's real GDK events.
  function locate(command) {
    const action = typeof command.action === 'string' ? command.action : 'click';
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);

    const element = resolved.elements[0];
    const telemetry = resolved.telemetry.slice();
    const options = command.options || {};
    const force = options.force === true || command.force === true;
    if (typeof element.scrollIntoView === 'function') element.scrollIntoView({ block: 'nearest' });
    if (!force) {
      const check = runActionabilityChecks(element, action);
      telemetry.push(actionabilitySpan(command, action, check));
      if (!check.passed) return actionFailure(check.error, check.check, telemetry);
    } else {
      telemetry.push(actionabilitySpan(command, action, {
        check: 'force', passed: true, error: null, bbox: element.getBoundingClientRect()
      }));
    }

    if (command.focus === true) focusForInput(element, action);
    const rect = element.getBoundingClientRect();
    // `document` binds the native dispatch to this document (PagePort v3.1).
    // viewport lets the engine pick an in-view start for humanized paths (N8).
    return success({
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2,
      document: inputAck.doc,
      viewport: { width: globalScope.innerWidth, height: globalScope.innerHeight }
    }, telemetry);
  }

  // Native scroll (N18): where the target is now, without moving anything.
  // Unlike locate it never scrolls (scrollIntoView would do the scroll
  // synthetically before the real wheel) and runs no actionability checks:
  // the target may be far off screen. Without a selector, x/y is the
  // viewport centre. no_match is retryable.
  function measure(command) {
    const viewport = { width: globalScope.innerWidth, height: globalScope.innerHeight };
    const answer = (x, y, telemetry) => success({
      x, y, document: inputAck.doc, viewport,
      scroll: { x: globalScope.scrollX, y: globalScope.scrollY }
    }, telemetry);
    if (command.selector === undefined || command.selector === null) {
      return answer(viewport.width / 2, viewport.height / 2, []);
    }
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
    const rect = resolved.elements[0].getBoundingClientRect();
    return answer(rect.left + rect.width / 2, rect.top + rect.height / 2, resolved.telemetry);
  }

  // Focus as the synthetic action would leave it: for typing, the caret goes
  // to the end of the existing text (input/textarea selection, or a
  // collapsed range at the end of a contenteditable).
  function focusForInput(element, action) {
    if (typeof element.focus === 'function') element.focus();
    if (action !== 'type') return;
    if (element.isContentEditable) {
      selectContents(element, true);
    } else if (typeof element.setSelectionRange === 'function' && typeof element.value === 'string') {
      try { element.setSelectionRange(element.value.length, element.value.length); } catch (_) {}
    }
  }

  // dom.press: with a selector the element is resolved, checked and focused
  // like any action; without one the key goes to the focused element.
  function press(command) {
    if (typeof command.key !== 'string' || command.key.length === 0) {
      return failure('malformed_command', command, [], false);
    }
    if (command.selector !== undefined && command.selector !== null) {
      return runAction(command, 'press');
    }
    const doc = globalScope.document;
    const target = deepActiveElement(doc) || doc.body || doc.documentElement;
    synthesizePress(target, command.key, command.modifiers || []);
    return success({ ok: true }, []);
  }

  // dom.selectOption: a native <select> gets the option set plus input and
  // change; an ARIA combobox is clicked open and its matching role=option
  // clicked; an ARIA listbox has its matching option clicked. Exactly one of
  // value / label / index identifies the option. No match fails retryably as
  // element_not_found / no_option; a disabled option fails as
  // element_disabled / option_disabled. Every attempt is synchronous: options
  // that render later are picked up by the engine's deadline-aware retry, so
  // nothing can click after the command has returned.
  function selectOption(command) {
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);

    const element = resolved.elements[0];
    const telemetry = resolved.telemetry.slice();
    // The receives-events check hit-tests the element's centre, which fails
    // for anything outside the viewport: bring the control into view first.
    if (typeof element.scrollIntoView === 'function') element.scrollIntoView({ block: 'nearest' });
    const check = runActionabilityChecks(element, 'select');
    telemetry.push(actionabilitySpan(command, 'select', check));
    if (!check.passed) return actionFailure(check.error, check.check, telemetry);

    if (element.tagName.toLowerCase() === 'select') return selectNative(element, command, telemetry);

    const role = elementRole(element);
    if (role === 'listbox') return clickAriaOption(element, command, telemetry);
    if (role === 'combobox' || element.getAttribute('aria-haspopup') === 'listbox') {
      if (element.getAttribute('aria-expanded') !== 'true') synthesizeClick(element);
      const listbox = popupListbox(element);
      if (!listbox) return failure('no_option', command, telemetry, true);
      return clickAriaOption(listbox, command, telemetry);
    }
    return failure('not_selectable', command, telemetry, false);
  }

  // dom.hover (synthetic): pointer and mouse events at the element's
  // centre, after the actionability checks a click gets (except enabled).
  // Event-only: script events do not move the browser's pointer, so CSS
  // :hover (menus, tooltips styled with it) does not apply. A real hover is
  // the native one (options.input "native"), a real pointer move.
  function hover(command) {
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
    const element = resolved.elements[0];
    const telemetry = resolved.telemetry.slice();
    if (typeof element.scrollIntoView === 'function') element.scrollIntoView({ block: 'nearest' });
    const check = runActionabilityChecks(element, 'hover');
    telemetry.push(actionabilitySpan(command, 'hover', check));
    if (!check.passed) return actionFailure(check.error, check.check, telemetry);
    const rect = element.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: globalScope,
      clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
    const enter = Object.assign({}, at, { bubbles: false, cancelable: false });
    element.dispatchEvent(new PointerEvent('pointerover', Object.assign({ pointerType: 'mouse', isPrimary: true }, at)));
    element.dispatchEvent(new PointerEvent('pointerenter', Object.assign({ pointerType: 'mouse', isPrimary: true }, enter)));
    element.dispatchEvent(new MouseEvent('mouseover', at));
    element.dispatchEvent(new MouseEvent('mouseenter', enter));
    element.dispatchEvent(new PointerEvent('pointermove', Object.assign({ pointerType: 'mouse', isPrimary: true }, at)));
    element.dispatchEvent(new MouseEvent('mousemove', at));
    return success({}, telemetry);
  }

  // dom.scroll (synthetic): a selector is scrolled into the middle of the
  // view; {x, y} scrolls the page by that many CSS px.
  function scroll(command) {
    if (command.selector !== undefined && command.selector !== null) {
      const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
      if (!resolved.ok) return resolved.response;
      if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
      resolved.elements[0].scrollIntoView({ block: 'center', inline: 'center' });
      return success({ scrollX: globalScope.scrollX, scrollY: globalScope.scrollY }, resolved.telemetry);
    }
    const x = Number(command.x || 0);
    const y = Number(command.y || 0);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return failure('malformed_command', command, [], false);
    globalScope.scrollBy(x, y);
    return success({ scrollX: globalScope.scrollX, scrollY: globalScope.scrollY }, []);
  }

  // dom.setInputFiles: click the file input so the browser opens its file
  // chooser, which the shell answers with the files. Hidden file inputs are
  // the usual case (sites style a button instead), so there is no
  // visibility or hit-test check: a script click from this world opens the
  // chooser anyway. Refuses before clicking when the input cannot take
  // `count` files.
  function chooseFiles(command) {
    const resolved = resolveForCommand(Object.assign({}, command, { strict: command.strict !== false }));
    if (!resolved.ok) return resolved.response;
    if (resolved.elements.length === 0) return failure('no_match', command, resolved.telemetry, true);
    const element = resolved.elements[0];
    const telemetry = resolved.telemetry.slice();
    if (element.tagName.toLowerCase() !== 'input' || String(element.type).toLowerCase() !== 'file') {
      return failure('not_file_input', command, telemetry, false);
    }
    if (isDisabled(element)) return actionFailure('element_disabled', 'enabled', telemetry);
    const count = Number(command.count);
    if (!Number.isInteger(count) || count < 1) return failure('malformed_command', command, telemetry, false);
    if (count > 1 && !element.multiple) return failure('not_multiple', command, telemetry, false);
    // Tell the shell which chooser is ours: the post and the click run in
    // this one task, so the next chooser it sees is the one opened here.
    // Without that channel nothing is clicked (no stray native dialog).
    const shell = globalScope.webkit && globalScope.webkit.messageHandlers &&
      globalScope.webkit.messageHandlers.zbFiles;
    if (!shell || typeof command.token !== 'string' || command.token.length === 0) {
      return failure('files_unavailable', command, telemetry, false);
    }
    // Answer once the input took the files (its change event) or the
    // chooser was cancelled; choosing the same files again may fire neither.
    const settled = new Promise((resolve) => {
      let timer = null;
      const finish = (changed) => {
        element.removeEventListener('change', onChange, true);
        element.removeEventListener('cancel', onCancel, true);
        clearTimeout(timer);
        resolve(changed);
      };
      const onChange = () => finish(true);
      const onCancel = () => finish(false);
      element.addEventListener('change', onChange, true);
      element.addEventListener('cancel', onCancel, true);
      timer = setTimeout(() => finish(false), FILES_SETTLE_MS);
    });
    Promise.resolve(shell.postMessage(command.token)).catch(() => {});
    element.click();
    return settled.then((changed) => success({ multiple: element.multiple, changed }, telemetry));
  }

  function selectNative(select, command, telemetry) {
    const options = Array.from(select.options);
    const option = options.find((candidate, index) => optionMatches(command, index,
      candidate.value, normalizeText(candidate.label || candidate.textContent || '')));
    if (!option) return failure('no_option', command, telemetry, true);
    // :disabled also covers options inside a disabled <optgroup>.
    if (option.matches(':disabled')) return optionDisabled(telemetry);

    select.focus();
    // Select this exact option: assigning select.value would pick the first
    // option with the same value when values repeat.
    for (const candidate of options) candidate.selected = candidate === option;
    select.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    select.dispatchEvent(new Event('change', { bubbles: true }));
    return success({ value: option.value }, telemetry);
  }

  function optionMatches(command, index, value, label) {
    if (typeof command.value === 'string') return value === command.value;
    if (typeof command.label === 'string') return label === normalizeText(command.label);
    if (typeof command.index === 'number') return index === command.index;
    return false;
  }

  function ariaOptionValue(option) {
    return option.getAttribute('data-value') || option.getAttribute('value') || accessibleName(option);
  }

  function ariaOptions(container) {
    return Array.from(container.querySelectorAll('[role="option"]'));
  }

  // The popup a combobox controls: aria-controls / aria-owns, else a listbox
  // inside the combobox. Never a document-wide search: an unrelated listbox
  // with the same option names must not be clicked.
  function popupListbox(combobox) {
    const doc = combobox.ownerDocument;
    for (const attr of ['aria-controls', 'aria-owns']) {
      const ids = (combobox.getAttribute(attr) || '').split(/\s+/).filter(Boolean);
      for (const id of ids) {
        const target = doc.getElementById(id);
        if (target) return target;
      }
    }
    return combobox.querySelector('[role="listbox"]');
  }

  function findAriaOption(container, command) {
    const options = ariaOptions(container);
    return options.find((option, index) => optionMatches(command, index, ariaOptionValue(option),
      accessibleName(option))) || null;
  }

  function optionDisabled(telemetry) {
    return {
      ok: false,
      error: 'element_disabled',
      retryable: false,
      data: { reason: 'option_disabled' },
      telemetry
    };
  }

  function clickAriaOption(container, command, telemetry) {
    const option = findAriaOption(container, command);
    if (!option || !isElementVisibleEnough(option)) return failure('no_option', command, telemetry, true);
    if (option.getAttribute('aria-disabled') === 'true') return optionDisabled(telemetry);
    // The option is clicked, so it must pass the same checks as dom.click.
    if (typeof option.scrollIntoView === 'function') option.scrollIntoView({ block: 'nearest' });
    const check = runActionabilityChecks(option, 'click');
    telemetry.push(actionabilitySpan(command, 'click', check));
    if (!check.passed) return actionFailure(check.error, check.check, telemetry);
    const value = ariaOptionValue(option);
    synthesizeClick(option);
    return success({ value }, telemetry);
  }

  const MODIFIER_KEYS = {
    Shift: { code: 'ShiftLeft', keyCode: 16, flag: 'shiftKey' },
    Control: { code: 'ControlLeft', keyCode: 17, flag: 'ctrlKey' },
    Alt: { code: 'AltLeft', keyCode: 18, flag: 'altKey' },
    Meta: { code: 'MetaLeft', keyCode: 91, flag: 'metaKey' }
  };

  const NAMED_KEYS = {
    Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, Space: 32,
    ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
    Home: 36, End: 35, PageUp: 33, PageDown: 34, Insert: 45,
    Shift: 16, Control: 17, Alt: 18, Meta: 91
  };

  const PUNCTUATION_CODES = {
    ' ': ['Space', 32], '-': ['Minus', 189], '=': ['Equal', 187], '[': ['BracketLeft', 219],
    ']': ['BracketRight', 221], '\\': ['Backslash', 220], ';': ['Semicolon', 186],
    "'": ['Quote', 222], ',': ['Comma', 188], '.': ['Period', 190], '/': ['Slash', 191],
    '`': ['Backquote', 192]
  };

  // DOM key -> { code, keyCode } as a US keyboard reports them.
  function keyDescriptor(key) {
    if (MODIFIER_KEYS[key]) return { code: MODIFIER_KEYS[key].code, keyCode: MODIFIER_KEYS[key].keyCode };
    if (NAMED_KEYS[key] !== undefined) return { code: key === 'Space' ? 'Space' : key, keyCode: NAMED_KEYS[key] };
    if (/^F([1-9]|1[0-2])$/.test(key)) return { code: key, keyCode: 111 + Number(key.slice(1)) };
    if (key.length === 1) {
      if (/[a-z]/i.test(key)) return { code: 'Key' + key.toUpperCase(), keyCode: key.toUpperCase().charCodeAt(0) };
      if (/[0-9]/.test(key)) return { code: 'Digit' + key, keyCode: key.charCodeAt(0) };
      const punct = PUNCTUATION_CODES[key];
      if (punct) return { code: punct[0], keyCode: punct[1] };
    }
    return { code: '', keyCode: 0 };
  }

  function keyboardEvent(type, key, descriptor, flags, cancelable) {
    const init = Object.assign({
      bubbles: true, cancelable, composed: true, key, code: descriptor.code,
      keyCode: descriptor.keyCode, which: descriptor.keyCode,
      charCode: type === 'keypress' ? key.charCodeAt(0) : 0,
      view: globalScope
    }, flags);
    const event = new KeyboardEvent(type, init);
    // Older engines ignore keyCode/which/charCode in the init dictionary.
    for (const field of ['keyCode', 'which', 'charCode']) {
      if (event[field] !== init[field]) {
        try { Object.defineProperty(event, field, { get: () => init[field] }); } catch (_) {}
      }
    }
    return event;
  }

  // The focused element, inside open shadow roots too (the document's
  // activeElement is then the host).
  function deepActiveElement(doc) {
    let active = doc.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active;
  }

  function synthesizePress(target, key, modifiers) {
    // Focus first, so every key event (modifiers included) reaches a focused target.
    if (target !== deepActiveElement(target.ownerDocument) && typeof target.focus === 'function') target.focus();

    const flags = { shiftKey: false, ctrlKey: false, altKey: false, metaKey: false };
    const held = [];
    for (const name of modifiers) {
      const modifier = MODIFIER_KEYS[name];
      if (!modifier || held.includes(name)) continue;
      flags[modifier.flag] = true;
      held.push(name);
      target.dispatchEvent(keyboardEvent('keydown', name, keyDescriptor(name), Object.assign({}, flags), true));
    }

    const descriptor = keyDescriptor(key);
    const proceed = target.dispatchEvent(keyboardEvent('keydown', key, descriptor, Object.assign({}, flags), true));
    const noCommand = !flags.ctrlKey && !flags.metaKey && !flags.altKey;
    const printable = key.length === 1 && noCommand;
    // keypress follows an uncancelled keydown for character keys and Enter,
    // and its own cancellation suppresses the default action too.
    if (proceed && (printable || (key === 'Enter' && noCommand))) {
      const pressOk = target.dispatchEvent(keyboardEvent('keypress', key, descriptor, Object.assign({}, flags), true));
      if (pressOk && printable) insertPrintable(target, key);
      if (pressOk && !printable) runKeyDefault(target, key, flags);
    } else if (proceed) {
      runKeyDefault(target, key, flags);
    }
    // keyup goes to whatever holds focus now (Tab may have moved it).
    const upTarget = deepActiveElement(target.ownerDocument) || target;
    upTarget.dispatchEvent(keyboardEvent('keyup', key, descriptor, Object.assign({}, flags), true));

    for (const name of held.reverse()) {
      flags[MODIFIER_KEYS[name].flag] = false;
      upTarget.dispatchEvent(keyboardEvent('keyup', name, keyDescriptor(name), Object.assign({}, flags), true));
    }
  }

  // Input types whose value is free text with a caret/selection.
  const TEXT_INPUT_TYPES = ['text', 'search', 'url', 'tel', 'password'];
  // Text-like types without the selection API: the character is appended.
  const APPEND_INPUT_TYPES = ['email', 'number'];

  function insertPrintable(target, char) {
    if (target.isContentEditable) {
      editableInsert(target, char, 'insertText');
      return;
    }
    const tag = target.tagName ? target.tagName.toLowerCase() : '';
    const type = tag === 'input' ? (target.type || 'text').toLowerCase() : '';
    const caretField = tag === 'textarea' || TEXT_INPUT_TYPES.includes(type);
    if (!caretField && !APPEND_INPUT_TYPES.includes(type)) return;
    if (target.readOnly || isDisabled(target)) return;

    const proceed = target.dispatchEvent(new InputEvent('beforeinput', {
      bubbles: true, cancelable: true, composed: true, inputType: 'insertText', data: char
    }));
    if (!proceed) return;

    const value = target.value || '';
    if (caretField && typeof target.selectionStart === 'number') {
      const start = target.selectionStart;
      const end = typeof target.selectionEnd === 'number' ? target.selectionEnd : start;
      target.value = value.slice(0, start) + char + value.slice(end);
      target.setSelectionRange(start + char.length, start + char.length);
    } else {
      target.value = value + char;
    }
    target.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: char }));
  }

  // Browser default actions for the non-printable keys dom.press supports.
  function runKeyDefault(target, key, flags) {
    if (key === 'Enter') {
      const tag = target.tagName ? target.tagName.toLowerCase() : '';
      if (tag === 'input' && target.form) implicitSubmit(target.form);
    } else if (key === 'Tab') {
      moveFocus(target, flags.shiftKey ? -1 : 1);
    }
  }

  // HTML implicit submission (Enter in a form field), as a real browser does
  // it: activate the form's default button; with no default button, submit
  // only when exactly one field blocks implicit submission.
  const BLOCKING_INPUT_TYPES = ['text', 'search', 'url', 'tel', 'email', 'password', 'date', 'month',
    'week', 'time', 'datetime-local', 'number'];

  function implicitSubmit(form) {
    const controls = Array.from(form.elements);
    // Reflected .type: HTML normalizes a missing or invalid button type to
    // 'submit'.
    const defaultButton = controls.find((el) => {
      const tag = el.tagName.toLowerCase();
      const type = (el.type || '').toLowerCase();
      return (tag === 'button' && type === 'submit') ||
        (tag === 'input' && (type === 'submit' || type === 'image'));
    });
    if (defaultButton) {
      if (!isDisabled(defaultButton)) defaultButton.click();
      return;
    }
    const blocking = controls.filter((el) => el.tagName.toLowerCase() === 'input' &&
      BLOCKING_INPUT_TYPES.includes((el.type || 'text').toLowerCase()));
    if (blocking.length !== 1) return;
    if (typeof form.requestSubmit === 'function') form.requestSubmit();
    else form.submit();
  }

  function tabbableElements(doc) {
    const candidates = Array.from(doc.querySelectorAll(
      'a[href], button, input, select, textarea, iframe, [tabindex], [contenteditable="true"], [contenteditable=""]'
    ));
    const usable = candidates.filter((el) => el.tabIndex >= 0 && !isDisabled(el) &&
      !(el.tagName.toLowerCase() === 'input' && el.type === 'hidden') && isElementVisibleEnough(el));
    const positive = usable.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
    return positive.concat(usable.filter((el) => el.tabIndex === 0));
  }

  function moveFocus(from, direction) {
    const order = tabbableElements(from.ownerDocument);
    if (order.length === 0) return;
    const index = order.indexOf(from);
    const next = index < 0
      ? order[direction > 0 ? 0 : order.length - 1]
      : order[(index + direction + order.length) % order.length];
    next.focus();
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

  // Platform-specific rate-limit, challenge and block signals (N20). Each
  // check looks at what the platform shows the user; text is reported only
  // as a hash. A platform given in options wins over the hostname; with
  // neither, every platform's checks run.
  const PLATFORM_HOSTS = [
    ['x', /(^|\.)(x|twitter)\.com$/i],
    ['linkedin', /(^|\.)linkedin\.com$/i],
    ['instagram', /(^|\.)instagram\.com$/i]
  ];
  const X_TOAST_PATTERN = /something went wrong|rate limit|over the daily limit|try again later/i;
  const LINKEDIN_INVITATION_PATTERN = /weekly invitation limit|invitation limit/i;
  const INSTAGRAM_TRY_LATER_PATTERN = /try again later|we restrict certain activity/i;
  const PLATFORM_SIGNAL_CONFIDENCE = { toast: 0.85, challenge: 0.95, authwall: 0.9, invitation_limit: 0.9, action_blocked: 0.9 };

  function scanPlatform(command) {
    const given = command.options && command.options.platform;
    if (typeof given === 'string' && given.length > 0 && given !== 'unknown') return given;
    const host = document.location.hostname;
    for (const [name, pattern] of PLATFORM_HOSTS) if (pattern.test(host)) return name;
    return 'unknown';
  }

  function textSignal(kind, element, seen) {
    seen.add(element);
    const text = (element.textContent || '').trim().substring(0, RATE_LIMIT_TEXT_HASH_LIMIT);
    return { kind, text_hash: sha256Hex(text), confidence: PLATFORM_SIGNAL_CONFIDENCE[kind] };
  }

  function visibleMatches(selector, pattern) {
    return Array.from(document.querySelectorAll(selector))
      .filter((element) => isElementVisibleEnough(element) && pattern.test(element.textContent || ''));
  }

  function platformSignals(platform, seen) {
    const all = platform === 'unknown';
    const path = document.location.pathname;
    const signals = [];
    if (all || platform === 'x') {
      for (const toast of visibleMatches('[data-testid="toast"], [role="alert"]', X_TOAST_PATTERN)) {
        signals.push(textSignal('toast', toast, seen));
      }
      const arkose = Array.from(document.querySelectorAll('iframe[src*="arkoselabs" i], iframe[id*="arkose" i], iframe[title*="arkose" i]'))
        .some(isElementVisibleEnough);
      if (arkose) signals.push({ kind: 'challenge', text_hash: '', confidence: PLATFORM_SIGNAL_CONFIDENCE.challenge });
    }
    if (all || platform === 'linkedin') {
      if (/\/checkpoint\//i.test(path)) signals.push({ kind: 'challenge', text_hash: '', confidence: PLATFORM_SIGNAL_CONFIDENCE.challenge });
      const authwall = Array.from(document.querySelectorAll('[data-test-id="authwall"], .authwall-join-form'))
        .some(isElementVisibleEnough);
      if (/^\/authwall/i.test(path) || authwall) {
        signals.push({ kind: 'authwall', text_hash: '', confidence: PLATFORM_SIGNAL_CONFIDENCE.authwall });
      }
      for (const modal of visibleMatches('.artdeco-modal, [role="dialog"], [role="alertdialog"]', LINKEDIN_INVITATION_PATTERN)) {
        signals.push(textSignal('invitation_limit', modal, seen));
      }
    }
    if (all || platform === 'instagram') {
      if (/\/challenge\//i.test(path)) signals.push({ kind: 'challenge', text_hash: '', confidence: PLATFORM_SIGNAL_CONFIDENCE.challenge });
      for (const dialog of visibleMatches('[role="dialog"], [role="alertdialog"]', INSTAGRAM_TRY_LATER_PATTERN)) {
        signals.push(textSignal('action_blocked', dialog, seen));
      }
    }
    return signals;
  }

  function rateLimitScan(command) {
    const platform = scanPlatform(command);
    const seen = new Set();
    const signals = platformSignals(platform, seen);
    for (let i = 0; i < RATE_LIMIT_MODAL_SELECTORS.length; i++) {
      const modal = document.querySelector(RATE_LIMIT_MODAL_SELECTORS[i]);
      if (modal && !seen.has(modal)) {
        const text = modal.textContent || '';
        if (RATE_LIMIT_TEXT_PATTERN.test(text)) {
          seen.add(modal);
          signals.push({
            kind: 'modal',
            text_hash: sha256Hex(text.trim().substring(0, RATE_LIMIT_TEXT_HASH_LIMIT)),
            confidence: RATE_LIMIT_MODAL_CONFIDENCE
          });
        }
      }
    }
    if (RATE_LIMIT_PATH_PATTERN.test(document.location.pathname) && !signals.some((signal) => signal.kind === 'challenge')) {
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
    // Hovering a disabled control is fine (tooltips explain why it is off).
    if (action !== 'hover' && isDisabled(element)) return failedCheck(element, 'enabled', 'element_disabled');
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

  // The topmost element at the centre must be the element or inside it. In
  // an open shadow root the document answers with the host, so the hit test
  // descends through shadow roots, and "inside" is the composed tree.
  function receivesEvents(element) {
    const rect = element.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    let top = document.elementFromPoint(x, y);
    while (top && top !== element && top.shadowRoot) {
      const inner = top.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === top) break;
      top = inner;
    }
    return composedContains(element, top);
  }

  function composedContains(element, node) {
    for (let current = node; current; current = current instanceof ShadowRoot ? current.host : current.parentNode) {
      if (current === element) return true;
    }
    return false;
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
      element.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, view: globalScope }));
    }
  }

  function synthesizeFill(element, value) {
    if (element.isContentEditable) {
      element.focus();
      selectContents(element, false);
      editableInsert(element, value, value === '' ? 'deleteContentBackward' : 'insertText');
      return;
    }
    element.focus();
    element.value = value;
    element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function synthesizeType(element, text) {
    if (element.isContentEditable) {
      element.focus();
      selectContents(element, true);
      for (const char of text) {
        element.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, composed: true, key: char }));
        editableInsert(element, char, 'insertText');
        element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, composed: true, key: char }));
      }
      return;
    }
    element.focus();
    for (const char of text) {
      element.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, composed: true, key: char }));
      element.value = (element.value || '') + char;
      element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: char }));
      element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, composed: true, key: char }));
    }
  }

  // Select the element's contents, or (collapseToEnd) put the caret after them.
  function selectContents(element, collapseToEnd) {
    const selection = element.ownerDocument.getSelection();
    const range = element.ownerDocument.createRange();
    range.selectNodeContents(element);
    if (collapseToEnd) range.collapse(false);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // Insert `text` at the selection the way an editor sees real typing:
  // a cancelable beforeinput first. If the page cancels it (editors such as
  // Draft.js apply the edit to their own model), the browser inserts nothing
  // and fires no input event, so neither do we. Otherwise execCommand performs
  // a native edit (undo stack, input event); when it is unavailable, a Range
  // insert stands in and we fire input ourselves.
  function editableInsert(element, text, inputType) {
    const doc = element.ownerDocument;
    const data = inputType === 'insertText' ? text : null;
    const proceed = element.dispatchEvent(new InputEvent('beforeinput', {
      bubbles: true, cancelable: true, composed: true, inputType, data
    }));
    if (!proceed) return;

    let nativeInput = false;
    const sawInput = () => { nativeInput = true; };
    element.addEventListener('input', sawInput, true);
    let done = false;
    try {
      done = inputType === 'insertText'
        ? doc.execCommand('insertText', false, text)
        : doc.execCommand('delete', false);
    } catch (_) {
      done = false;
    } finally {
      element.removeEventListener('input', sawInput, true);
    }

    if (!done) rangeInsert(element, text);
    if (!done || !nativeInput) {
      element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType, data }));
    }
  }

  function rangeInsert(element, text) {
    const doc = element.ownerDocument;
    const selection = doc.getSelection();
    if (selection.rangeCount === 0 || !element.contains(selection.getRangeAt(0).commonAncestorContainer)) {
      selectContents(element, true);
    }
    const range = selection.getRangeAt(0);
    range.deleteContents();
    if (text.length === 0) return;
    const node = doc.createTextNode(text);
    range.insertNode(node);
    range.setStartAfter(node);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
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

  // `pierce=<selector>` is an ordinary css=, role=, text= or testid= selector
  // that also searches open shadow roots (XPath cannot enter them; closed
  // roots stay out of reach).
  const PIERCING_KINDS = ['role', 'testid', 'text', 'css'];

  function parseSelector(selector) {
    if (typeof selector !== 'string') return { ok: false };
    const index = selector.indexOf('=');
    if (index <= 0) return { ok: false };
    const kind = selector.slice(0, index);
    const body = selector.slice(index + 1);
    if (!['role', 'testid', 'text', 'css', 'xpath', 'pierce'].includes(kind) || body.length === 0) {
      return { ok: false };
    }
    if (kind === 'pierce') {
      const inner = parseSelector(body);
      if (!inner.ok || !PIERCING_KINDS.includes(inner.kind)) return { ok: false };
    }
    return { ok: true, kind, body };
  }

  function resolveSelector(kind, body) {
    switch (kind) {
      case 'xpath':
        return resolveXPath(body);
      case 'pierce': {
        const inner = parseSelector(body);
        return resolveIn(inner.kind, inner.body, searchRoots());
      }
      default:
        return resolveIn(kind, body, [document]);
    }
  }

  function resolveIn(kind, body, roots) {
    switch (kind) {
      case 'role':
        return resolveRole(body, roots);
      case 'testid':
        return queryAll(roots, '[data-testid="' + cssEscape(body) + '"]');
      case 'text':
        return candidateElements(roots).filter((element) => elementText(element) === body);
      case 'css':
        return queryAll(roots, body);
      default:
        return [];
    }
  }

  // The document, then every open shadow root, in the order found (a root
  // inside a root comes after it).
  function searchRoots() {
    const roots = [document];
    for (let i = 0; i < roots.length; i += 1) {
      for (const element of roots[i].querySelectorAll('*')) {
        if (element.shadowRoot) roots.push(element.shadowRoot);
      }
    }
    return roots;
  }

  function queryAll(roots, selector) {
    return unique(roots.map((root) => root.querySelectorAll(selector)));
  }

  // Each element once, in order (a slotted node is a child of its host only,
  // but a match is never counted twice).
  function unique(lists) {
    const seen = new Set();
    const results = [];
    for (const list of lists) {
      for (const element of list) {
        if (seen.has(element)) continue;
        seen.add(element);
        results.push(element);
      }
    }
    return results;
  }

  function resolveRole(body, roots) {
    const match = body.match(/^([a-zA-Z0-9_-]+)(?:\[name=(?:"([^"]*)"|'([^']*)'|([^\]]+))\])?$/);
    if (!match) throw new Error('malformed role selector');
    const role = match[1];
    const name = match[2] || match[3] || match[4] || null;
    return candidateElements(roots).filter((element) => {
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

  // Elements in the document's body, then in each given shadow root.
  function candidateElements(roots) {
    return unique(roots.map((root) => root.querySelectorAll(root === document ? 'body *' : '*')));
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

  // SHA-256 (FIPS 180-4) of the UTF-8 bytes of `text`, as 64 lowercase hex.
  // Synchronous and context-independent (crypto.subtle needs a secure
  // context and is async); rate-limit signals report page text only as this.
  const SHA256_K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  function sha256Hex(text) {
    const bytes = new TextEncoder().encode(String(text));
    const bitLength = bytes.length * 8;
    const padded = new Uint8Array(((bytes.length + 9 + 63) >> 6) << 6);
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, Math.floor(bitLength / 0x100000000));
    view.setUint32(padded.length - 4, bitLength >>> 0);
    const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const w = new Uint32Array(64);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let offset = 0; offset < padded.length; offset += 64) {
      for (let i = 0; i < 16; i += 1) w[i] = view.getUint32(offset + i * 4);
      for (let i = 16; i < 64; i += 1) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let i = 0; i < 64; i += 1) {
        const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + SHA256_K[i] + w[i]) >>> 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
        hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
      h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
    }
    return h.map((word) => word.toString(16).padStart(8, '0')).join('');
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
      inputAck() {
        return {
          doc: inputAck.doc, mouseup: inputAck.mouseup, keyup: inputAck.keyup, click: inputAck.click, wheel: inputAck.wheel, moveX: inputAck.moveX, moveY: inputAck.moveY, scrolls: inputAck.scrolls,
          scrollQuietMs: inputAck.lastScrollAt < 0 ? -1 : globalScope.performance.now() - inputAck.lastScrollAt,
          navigations: inputAck.navigations, leaving: inputAck.pending !== null
        };
      },
      // Shell side: a load ended without a new document after the shell
      // had heard of navigations up to number `seq`.
      navigationEnded(seq) {
        const pending = inputAck.pending;
        if (pending !== null && pending.seq !== undefined && pending.seq <= seq) inputAck.pending = null;
      },
      debugPendingNavigation() {
        const pending = inputAck.pending;
        return pending === null ? null : { seq: pending.seq === undefined ? null : pending.seq };
      },
      documentToken: inputAck.doc,
      debugOutstandingWaits() {
        return outstandingWaits;
      }
    }
  });
})(globalThis);
