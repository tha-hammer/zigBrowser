(function installZigBrowserAutomation(globalScope) {
  const automation = {
    version: 'phase1-m0-harness',
    handle(command) {
      return {
        ok: false,
        error: 'element_not_found',
        retryable: false,
        data: {
          phase: 'm0-harness',
          commandType: typeof command
        }
      };
    }
  };

  Object.defineProperty(globalScope, '__zbAutomation', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: automation
  });
})(globalThis);
