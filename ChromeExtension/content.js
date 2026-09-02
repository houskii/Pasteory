let captureEnabled = false;

function currentHost() {
  return location.hostname.toLowerCase();
}

function refreshConfig() {
  chrome.runtime.sendMessage({ type: "get-config", host: currentHost() })
    .then((response) => { captureEnabled = Boolean(response?.hostEnabled); })
    .catch(() => { captureEnabled = false; });
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === "refresh-config") refreshConfig();
});

function clipped(value, limit) {
  const text = String(value || "");
  return text.length > limit ? text.slice(0, limit) : text;
}

function cleanText(value, limit = 2048) {
  return clipped(String(value || "").replace(/\s+/g, " ").trim(), limit);
}

function selectorHint(element) {
  if (!(element instanceof Element)) return "";
  const parts = [];
  let current = element;
  for (let depth = 0; current && depth < 5; depth += 1, current = current.parentElement) {
    let part = current.tagName.toLowerCase();
    if (current.id) part += `#${CSS.escape(current.id).slice(0, 80)}`;
    else if (current.classList.length) part += `.${[...current.classList].slice(0, 2).map((value) => CSS.escape(value)).join(".")}`;
    parts.unshift(part);
  }
  return clipped(parts.join(" > "), 512);
}

function elementSnapshot(element) {
  if (!(element instanceof Element)) return {};
  return {
    tag: element.tagName.toLowerCase(),
    selector: selectorHint(element),
    role: clipped(element.getAttribute("role"), 80),
    ariaLabel: clipped(element.getAttribute("aria-label"), 256),
    href: element instanceof HTMLAnchorElement ? clipped(element.href, 2048) : "",
    text: cleanText(element.innerText || element.textContent, 2048)
  };
}

function contextAround(element, selectedText) {
  let current = element instanceof Element ? element : element?.parentElement;
  const ancestors = [];
  for (let depth = 0; current && depth < 8; depth += 1, current = current.parentElement) {
    const text = cleanText(current.innerText || current.textContent, 2048);
    ancestors.push({
      depth,
      tag: current.tagName.toLowerCase(),
      selector: selectorHint(current),
      text
    });
    if (text.length >= Math.min(160, selectedText.length + 80)) break;
  }
  const parent = element?.parentElement;
  const siblings = parent ? [...parent.children] : [];
  const index = element instanceof Element ? siblings.indexOf(element) : -1;
  return {
    ancestors,
    before: index > 0 ? cleanText(siblings[index - 1].innerText || siblings[index - 1].textContent, 512) : "",
    after: index >= 0 && index + 1 < siblings.length
      ? cleanText(siblings[index + 1].innerText || siblings[index + 1].textContent, 512)
      : ""
  };
}

function bitsMetadata(url, selectedText, context) {
  if (url.hostname !== "bits.bytedance.net") return {};
  const match = url.pathname.match(/^\/devops\/(\d+)\/code\/detail\/(\d+)/);
  let repository = "";
  let targetBranch = "";
  for (const ancestor of context.ancestors) {
    const lines = ancestor.text.split(/\s+/).filter(Boolean);
    const selectedIndex = lines.findIndex((line) => line === selectedText);
    if (selectedIndex <= 0) continue;
    repository = clipped(lines[selectedIndex - 1], 160);
    if (selectedIndex + 1 < lines.length) targetBranch = clipped(lines[selectedIndex + 1], 256);
    break;
  }
  const looksLikeBranch = selectedText.includes("/") && !selectedText.includes(" ");
  return {
    siteName: "BITS",
    projectId: match?.[1] || "",
    mergeRequestId: match?.[2] || "",
    repository,
    branch: looksLikeBranch ? clipped(selectedText, 512) : "",
    targetBranch
  };
}

function captureSelection() {
  const active = document.activeElement;
  if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) {
    if (active instanceof HTMLInputElement && active.type === "password") return null;
    const start = active.selectionStart ?? 0;
    const end = active.selectionEnd ?? start;
    const selectedText = active.value.slice(start, end);
    if (!selectedText) return null;
    return { selectedText, selectedHTML: "", element: active };
  }
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
  const selectedText = selection.toString();
  if (!selectedText) return null;
  const range = selection.getRangeAt(0);
  const container = document.createElement("div");
  container.appendChild(range.cloneContents());
  const node = range.commonAncestorContainer;
  const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  return { selectedText, selectedHTML: clipped(container.innerHTML, 16384), element };
}

function buildPayload() {
  const selection = captureSelection();
  if (!selection) return null;
  const selectedText = clipped(selection.selectedText, 8192);
  const context = contextAround(selection.element, selectedText);
  const url = new URL(location.href);
  const adapter = bitsMetadata(url, selectedText, context);
  const siteName = adapter.siteName
    || document.querySelector('meta[property="og:site_name"]')?.content
    || url.hostname;
  const payload = {
    schemaVersion: 1,
    capturedAt: new Date().toISOString(),
    url: clipped(location.href, 8192),
    frameUrl: clipped(location.href, 8192),
    topFrame: window === window.top,
    hostname: currentHost(),
    siteName: clipped(siteName, 256),
    pageTitle: clipped(document.title, 1024),
    selectedText,
    selectedHTML: selection.selectedHTML,
    element: elementSnapshot(selection.element),
    context,
    adapter
  };
  if (JSON.stringify(payload).length > 32768) {
    payload.selectedHTML = clipped(payload.selectedHTML, 4096);
    payload.context.ancestors = payload.context.ancestors.slice(0, 5).map((item) => ({
      ...item,
      text: clipped(item.text, 512)
    }));
    payload.contextTruncated = true;
  }
  return payload;
}

document.addEventListener("copy", () => {
  if (!captureEnabled) return;
  const startedAt = performance.now();
  const payload = buildPayload();
  if (!payload) return;
  payload.captureDurationMs = Math.round((performance.now() - startedAt) * 100) / 100;
  chrome.runtime.sendMessage({ type: "capture-context", payload }).catch(() => {});
}, true);

refreshConfig();
window.addEventListener("focus", refreshConfig, { passive: true });
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refreshConfig();
}, { passive: true });
