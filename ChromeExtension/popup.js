const site = document.getElementById("site");
const enabled = document.getElementById("enabled");
const status = document.getElementById("status");
const blockedSection = document.getElementById("blocked-section");
const blockedList = document.getElementById("blocked-list");
let hostname = "";

async function refresh() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  try { hostname = new URL(tab.url).hostname.toLowerCase(); } catch (_) { hostname = ""; }
  site.textContent = hostname || "当前页面不支持采集";
  enabled.disabled = !hostname;
  const result = await chrome.runtime.sendMessage({ type: "popup-status", host: hostname });
  enabled.checked = Boolean(result?.siteAllowed);
  renderBlockedHosts(result?.blockedHosts || []);
  if (!result?.bridgeConnected) {
    status.textContent = "未连接 Pasteory，请先在高级诊断中准备插件。";
    status.className = "status error";
  } else if (!result?.chromeEnabled) {
    status.textContent = "原生桥接正常；Pasteory 中的 Chrome 总开关尚未打开。";
    status.className = "status";
  } else {
    status.textContent = "原生桥接正常。";
    status.className = "status";
  }
}

function renderBlockedHosts(hosts) {
  blockedList.replaceChildren();
  blockedSection.hidden = hosts.length === 0;
  for (const host of hosts) {
    const row = document.createElement("div");
    row.className = "blocked-row";
    const label = document.createElement("span");
    label.textContent = host;
    const button = document.createElement("button");
    button.textContent = "重新允许";
    button.addEventListener("click", async () => {
      button.disabled = true;
      await chrome.runtime.sendMessage({ type: "set-site-enabled", host, enabled: true });
      await refresh();
    });
    row.append(label, button);
    blockedList.append(row);
  }
}

enabled.addEventListener("change", async () => {
  enabled.disabled = true;
  await chrome.runtime.sendMessage({ type: "set-site-enabled", host: hostname, enabled: enabled.checked });
  enabled.disabled = false;
  await refresh();
});

refresh();
