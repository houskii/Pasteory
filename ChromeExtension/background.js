const HOST_NAME = "app.pasteory.web_context";
let nativePort = null;
let config = { chromeEnabled: false, bridgeConnected: false, language: "en" };
let blockedHosts = new Set();
let lastConfigRequestAt = 0;
let idleTimer = null;
const pending = new Map();

function connectNative() {
  if (nativePort) return nativePort;
  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
    config.bridgeConnected = true;
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      config = { ...config, bridgeConnected: false };
      for (const resolve of pending.values()) resolve({ ok: false, error: "bridge_disconnected" });
      pending.clear();
      broadcastConfig();
    });
    requestConfig();
  } catch (_) {
    nativePort = null;
    config = { ...config, bridgeConnected: false };
  }
  return nativePort;
}

function keepWarm() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    nativePort?.disconnect();
    nativePort = null;
  }, 60000);
}

function handleNativeMessage(message) {
  keepWarm();
  if (message.type === "config") {
    config = {
      chromeEnabled: Boolean(message.chromeEnabled),
      language: message.language === "zh-Hans" ? "zh-Hans" : "en",
      bridgeConnected: true
    };
    lastConfigRequestAt = Date.now();
    broadcastConfig();
  }
  if (message.requestId && pending.has(message.requestId)) {
    pending.get(message.requestId)(message);
    pending.delete(message.requestId);
  }
}

function requestNative(message) {
  return new Promise((resolve) => {
    const port = connectNative();
    if (!port) return resolve({ ok: false, error: "bridge_unavailable" });
    const requestId = crypto.randomUUID();
    pending.set(requestId, resolve);
    port.postMessage({ ...message, requestId });
    keepWarm();
    setTimeout(() => {
      if (!pending.has(requestId)) return;
      pending.delete(requestId);
      resolve({ ok: false, error: "bridge_timeout" });
    }, 1500);
  });
}

function requestConfig() {
  lastConfigRequestAt = Date.now();
  return requestNative({ type: "getConfig" });
}

function isHostEnabled(host) {
  const normalized = String(host || "").toLowerCase();
  return config.chromeEnabled && normalized.length > 0 && !blockedHosts.has(normalized);
}

async function loadSitePolicy() {
  const stored = await chrome.storage.local.get("blockedHosts");
  blockedHosts = new Set(Array.isArray(stored.blockedHosts) ? stored.blockedHosts : []);
  broadcastConfig();
}

async function setSiteEnabled(host, enabled) {
  const normalized = String(host || "").toLowerCase();
  if (!normalized) return { ok: false, error: "invalid_host" };
  if (enabled) blockedHosts.delete(normalized);
  else blockedHosts.add(normalized);
  await chrome.storage.local.set({ blockedHosts: [...blockedHosts].sort() });
  broadcastConfig();
  return { ok: true, siteAllowed: !blockedHosts.has(normalized), hostEnabled: isHostEnabled(normalized) };
}

async function broadcastConfig() {
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (!tab.id) continue;
    chrome.tabs.sendMessage(tab.id, { type: "refresh-config" }).catch(() => {});
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === "get-config") {
    if (Date.now() - lastConfigRequestAt > 10000) requestConfig();
    sitePolicyReady.then(() => {
      let host = message.host;
      try { host = new URL(sender.tab?.url || "").hostname; } catch (_) {}
      sendResponse({ ...config, hostEnabled: isHostEnabled(host) });
    });
    return true;
  }
  if (message.type === "capture-context") {
    sitePolicyReady.then(() => {
      const payload = { ...message.payload };
      if (sender.tab?.url) {
        try {
          const topURL = new URL(sender.tab.url);
          payload.url = sender.tab.url;
          payload.hostname = topURL.hostname.toLowerCase();
          if (sender.tab.title) payload.pageTitle = sender.tab.title;
        } catch (_) {}
      }
      const host = String(payload.hostname || "").toLowerCase();
      if (!isHostEnabled(host)) {
        sendResponse({ ok: false, error: "site_disabled" });
        return;
      }
      requestNative({ type: "capture", payload }).then(sendResponse);
    });
    return true;
  }
  if (message.type === "popup-status") {
    Promise.all([sitePolicyReady, requestConfig()]).then(() => {
      const host = String(message.host || "").toLowerCase();
      sendResponse({
        ...config,
        siteAllowed: !blockedHosts.has(host),
        hostEnabled: isHostEnabled(host),
        blockedHosts: [...blockedHosts].sort()
      });
    });
    return true;
  }
  if (message.type === "set-site-enabled") {
    setSiteEnabled(message.host, Boolean(message.enabled)).then(sendResponse);
    return true;
  }
  return false;
});

chrome.runtime.onInstalled.addListener(() => requestConfig());
chrome.runtime.onStartup.addListener(() => requestConfig());
chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes.blockedHosts) loadSitePolicy();
});
const sitePolicyReady = loadSitePolicy();
