// T1 (chat-drawer plan section 9): what a hostile page can reach. Every
// agent, drawer or secrets handler name must be absent from the page world,
// and zbHost (the page bridge) must know no agent, drawer, secrets or
// broker command. The result lands in window.__result (read by the E2E
// through the automation socket) and, in a frame, is posted to the top page.
(function () {
  "use strict";
  var NAMES = ["zbAgent", "zbDrawer", "zbSecrets", "zbAuth", "zbBroker"];
  var COMMANDS = ["agent.ping", "agent.prompt", "drawer.open", "drawer.minimize", "secrets.get", "secrets.set",
                  "broker.call"];
  async function probe() {
    var handlers = (window.webkit && window.webkit.messageHandlers) || {};
    var out = { handlers: {}, zbhost: {} };
    NAMES.forEach(function (n) { out.handlers[n] = typeof handlers[n]; });
    for (var i = 0; i < COMMANDS.length; i++) {
      var cmd = COMMANDS[i];
      if (!handlers.zbHost) { out.zbhost[cmd] = "no-zbHost"; continue; }
      try {
        var reply = await handlers.zbHost.postMessage(JSON.stringify({ cmd: cmd, args: {} }));
        out.zbhost[cmd] = "resolved:" + JSON.stringify(reply);
      } catch (err) {
        out.zbhost[cmd] = "rejected:" + (err && err.message ? err.message : String(err));
      }
    }
    return out;
  }
  probe().then(function (out) {
    window.__result = out;
    if (window.parent !== window) window.parent.postMessage({ zbProbe: location.href, result: out }, "*");
  });
})();
