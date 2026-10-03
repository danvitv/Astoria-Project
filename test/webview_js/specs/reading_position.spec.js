import { test, expect } from '@playwright/test';

async function openMidChat(page, count = 60) {
  await page.setViewportSize({ width: 400, height: 700 });
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate((count) => {
    window.__M = (id, text) => ({
      id, role: 'assistant', text, timestamp: 1767225600000,
      isUser: false, isAssistant: true, isSystem: false,
      displayName: 'Alice', isError: false, isHidden: false,
      isGenerating: false, isPostGenRunning: false,
    });
    window.bridge.setMessages(JSON.stringify(Array.from({ length: count }, (_, i) =>
      window.__M('m' + i, 'Message ' + i + '. ' + 'lorem ipsum dolor sit amet '.repeat(4)))));
  }, count);
  await page.waitForTimeout(600);
  await page.evaluate(() => { window.bridge.virtualList.container.scrollTop = 1500; });
  await page.waitForTimeout(400);
}

async function anchor(page) {
  return page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const view = c.getBoundingClientRect();
    const rows = [...document.querySelectorAll('#chat-container .message-section')];
    const el = rows.find((r) => r.getBoundingClientRect().bottom > view.top + 1);
    if (!el) return null;
    const above = rows.filter((r) => r.getBoundingClientRect().bottom <= view.top + 1);
    return {
      id: el.dataset.messageId, offset: el.getBoundingClientRect().top - view.top,
      aboveId: above.at(-1)?.dataset.messageId, scrollTop: c.scrollTop,
    };
  });
}

test('late growth and shrink above the reader preserve the visible anchor', async ({ page }) => {
  await openMidChat(page);
  const before = await anchor(page);
  expect(before).not.toBeNull();
  expect(before.aboveId).toBeTruthy();
  await page.evaluate((id) => window.bridge.updateMessage(JSON.stringify(
    window.__M(id, 'HUGE ' + 'lorem ipsum dolor sit amet '.repeat(120)))), before.aboveId);
  await page.waitForTimeout(800);
  const grown = await anchor(page);
  expect(grown.id).toBe(before.id);
  expect(Math.abs(grown.offset - before.offset)).toBeLessThan(4);
  expect(grown.scrollTop).toBeGreaterThan(before.scrollTop);
  await page.evaluate((id) => window.bridge.updateMessage(JSON.stringify(window.__M(id, 'short'))), before.aboveId);
  await page.waitForTimeout(800);
  const shrunk = await anchor(page);
  expect(shrunk.id).toBe(before.id);
  expect(Math.abs(shrunk.offset - before.offset)).toBeLessThan(4);
  expect(shrunk.scrollTop).toBeLessThan(grown.scrollTop);
});

test('a bottom-pinned reader follows late growth above them', async ({ page }) => {
  await openMidChat(page, 30);
  await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    c.scrollTop = c.scrollHeight;
  });
  await page.waitForTimeout(300);
  await page.evaluate(() => window.bridge.updateMessage(JSON.stringify(
    window.__M('m20', 'mid ' + 'lorem ipsum dolor sit amet '.repeat(60)))));
  await page.waitForTimeout(800);
  expect(await page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    return Math.abs(c.scrollTop + c.clientHeight - c.scrollHeight) <= 2;
  })).toBe(true);
});
