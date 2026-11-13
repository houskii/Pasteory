const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function element() {
  return { textContent: '', children: [], dataset: {},
    addEventListener() {}, append(...items) { this.children.push(...items); },
    replaceChildren() { this.children = []; } };
}
function popup(result) {
  const elements = Object.fromEntries(['site', 'enabled', 'status', 'blocked-section', 'blocked-list'].map(id => [id, element()]));
  const labels = ['title', 'allow', 'blocked', 'hint'].map(key => ({ ...element(), dataset: { i18n: key } }));
  const document = { documentElement: {}, getElementById: id => elements[id], querySelectorAll: () => labels, createElement: element };
  const config = { ...result };
  const context = vm.createContext({ document, URL, chrome: {
    tabs: { query: async () => [{ url: 'https://example.com/article' }] },
    runtime: { sendMessage: async () => config }
  } });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../ChromeExtension/popup.js'), 'utf8'), context);
  return { elements, labels, config, document, refresh: () => vm.runInContext('refresh()', context) };
}

test('defaults to English without a saved app language', async () => {
  const app = popup({ bridgeConnected: true, chromeEnabled: true, siteAllowed: true });
  await app.refresh();
  assert.equal(app.document.documentElement.lang, 'en');
  assert.equal(app.labels[0].textContent, 'Pasteory Web Context');
  assert.equal(app.elements.status.textContent, 'Connected to Pasteory.');
});

test('follows the app language across popup refreshes without translating hostnames', async () => {
  const app = popup({ language: 'zh-Hans', bridgeConnected: true, chromeEnabled: false, blockedHosts: ['example.org'] });
  await app.refresh();
  assert.equal(app.labels[0].textContent, 'Pasteory 网页来源');
  assert.equal(app.elements.site.textContent, 'example.com');
  assert.match(app.elements.status.textContent, /总开关/);
  const row = app.elements['blocked-list'].children[0];
  assert.equal(row.children[0].textContent, 'example.org');
  assert.equal(row.children[1].textContent, '重新允许');
  app.config.language = 'en';
  app.config.bridgeConnected = false;
  await app.refresh();
  assert.equal(app.document.documentElement.lang, 'en');
  assert.match(app.elements.status.textContent, /Not connected/);
  assert.equal(app.elements['blocked-list'].children[0].children[1].textContent, 'Allow Again');
});
