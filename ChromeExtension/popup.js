const site = document.getElementById("site");
const enabled = document.getElementById("enabled");
const status = document.getElementById("status");
const blockedSection = document.getElementById("blocked-section");
const blockedList = document.getElementById("blocked-list");
let hostname = "";
let language = "en";
const messages = {
  en: {
    title: "Pasteory Web Context", allow: "Allow capture on this website", blocked: "Blocked Websites",
    hint: "Nearby page elements are read on copy only when Chrome capture in Pasteory and this website’s switch are both on.",
    unsupported: "Capture isn’t available on this page", disconnected: "Not connected to Pasteory. Prepare the extension in Settings → Link Resolution.",
    disabled: "Connected. Turn on Chrome capture in Pasteory to enable it.", connected: "Connected to Pasteory.", reallow: "Allow Again"
  },
  "zh-Hans": {
    title: "Pasteory 网页来源", allow: "允许采集此网站", blocked: "已关闭的网站",
    hint: "只有 Pasteory 中的 Chrome 总开关和此网站开关同时打开，复制时才会读取选区附近的网页元素。",
    unsupported: "当前页面不支持采集", disconnected: "未连接 Pasteory，请先在设置 → 链接解析中准备插件。",
    disabled: "原生桥接正常；Pasteory 中的 Chrome 总开关尚未打开。", connected: "原生桥接正常。", reallow: "重新允许"
  }
};
function localize() {
  document.documentElement.lang = language;
  document.querySelectorAll("[data-i18n]").forEach(element => {
    element.textContent = messages[language][element.dataset.i18n];
  });
}

async function refresh() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  try { hostname = new URL(tab.url).hostname.toLowerCase(); } catch (_) { hostname = ""; }
  enabled.disabled = !hostname;
  const result = await chrome.runtime.sendMessage({ type: "popup-status", host: hostname });
  language = result?.language === "zh-Hans" ? "zh-Hans" : "en";
  localize();
  site.textContent = hostname || messages[language].unsupported;
  enabled.checked = Boolean(result?.siteAllowed);
  renderBlockedHosts(result?.blockedHosts || []);
  if (!result?.bridgeConnected) {
    status.textContent = messages[language].disconnected;
    status.className = "status error";
  } else if (!result?.chromeEnabled) {
    status.textContent = messages[language].disabled;
    status.className = "status";
  } else {
    status.textContent = messages[language].connected;
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
    button.textContent = messages[language].reallow;
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
