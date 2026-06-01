(function () {
  "use strict";

  var pending = new Map();
  var nextRequestId = 1;
  var webviewListenerInstalled = false;

  function safeErrorMessage(raw) {
    if (raw == null) return "UnknownError";
    if (typeof raw === "string") return raw;
    if (typeof raw.message === "string") return raw.message;
    try {
      return JSON.stringify(raw);
    } catch (_err) {
      return String(raw);
    }
  }

  function asError(raw) {
    if (raw instanceof Error) return raw;
    return new Error(safeErrorMessage(raw));
  }

  function sendViaGtk(payload) {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zbHost;
    if (!handler || typeof handler.postMessage !== "function") {
      return null;
    }

    var message = JSON.stringify(payload);
    return Promise.resolve(handler.postMessage(message)).catch(function (err) {
      throw asError(err);
    });
  }

  function onWebViewReply(event) {
    var data = event && event.data;
    if (typeof data === "string") {
      try {
        data = JSON.parse(data);
      } catch (_err) {
        return;
      }
    }

    if (!data || typeof data !== "object") {
      return;
    }

    var id = data.id;
    if (typeof id !== "number") {
      return;
    }

    var pendingEntry = pending.get(id);
    if (!pendingEntry) {
      return;
    }
    pending.delete(id);

    if (Object.prototype.hasOwnProperty.call(data, "error")) {
      pendingEntry.reject(asError(data.error));
      return;
    }

    pendingEntry.resolve(data.result);
  }

  function installWebViewListener(webview) {
    if (webviewListenerInstalled) {
      return true;
    }
    if (!webview || typeof webview.addEventListener !== "function") {
      return false;
    }

    webview.addEventListener("message", onWebViewReply);
    webviewListenerInstalled = true;
    return true;
  }

  function sendViaWebView2(payload) {
    var webview = window.chrome && window.chrome.webview;
    if (!webview || typeof webview.postMessage !== "function") {
      return null;
    }

    if (!installWebViewListener(webview)) {
      return Promise.reject(new Error("zbHost unavailable"));
    }

    var id = nextRequestId++;
    var envelope = {
      id: id,
      cmd: payload.cmd,
      args: payload.args,
    };

    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
      try {
        webview.postMessage(JSON.stringify(envelope));
      } catch (err) {
        pending.delete(id);
        reject(asError(err));
      }
    });
  }

  function zbHost(cmd, args) {
    if (typeof cmd !== "string" || cmd.length === 0) {
      return Promise.reject(new Error("BadArgs"));
    }

    var payload = {
      cmd: cmd,
      args: args === undefined ? {} : args,
    };

    var gtkResult = sendViaGtk(payload);
    if (gtkResult !== null) {
      return gtkResult;
    }

    var webview2Result = sendViaWebView2(payload);
    if (webview2Result !== null) {
      return webview2Result;
    }

    return Promise.reject(new Error("zbHost unavailable"));
  }

  window.zbHost = zbHost;
})();
