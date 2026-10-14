import { test, expect } from '@playwright/test';

async function boot(page) {
  await page.setViewportSize({ width: 400, height: 700 });
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(() => {
    window.__M = (id, text) => ({ id, text, role: 'assistant', timestamp: 1767225600000,
      isAssistant: true, isUser: false, isHidden: false, isError: false,
      isGenerating: false, isPostGenRunning: false, displayName: 'Alice' });
    window.bridge.setMessages(JSON.stringify(Array.from({ length: 30 }, (_, i) =>
      window.__M('m' + i, 'message ' + i + ' lorem ipsum '.repeat(8)))));
  });
  await page.waitForTimeout(600);
}

test('empty context boundary stays after newest message through rerender', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => window.bridge.setContextWindowStart('m29', true));
  await expect(page.locator('.message-section[data-message-id="m29"] > :last-child')).toHaveClass('context-limit-marker');
  await page.evaluate(() => window.bridge.setMessages(JSON.stringify([
    window.__M('m29', 'rerendered'),
  ])));
  await expect(page.locator('.message-section[data-message-id="m29"] > :last-child')).toHaveClass('context-limit-marker');
});

test('failed loopback images retry twice; remote URLs are not modified', async ({ page }) => {
  await boot(page);
  await page.route('**/__glaze_file__/**', route => route.fulfill({ status: 404, body: 'missing' }));
  await page.evaluate(async () => {
    const { retryFailedLocalImages } = await import('/assets/chat_webview/renderer/local_image_retry.js');
    const root = document.createElement('div');
    root.id = 'retry-test';
    root.innerHTML = '<img id="local-test" src="http://127.0.0.1:4176/__glaze_file__/missing.png"><img id="remote-test" src="https://example.invalid/image.png">';
    document.body.appendChild(root);
    retryFailedLocalImages(root);
  });
  await expect(page.locator('#local-test')).toHaveAttribute('data-retry-attempt', '2');
  await page.waitForTimeout(1200);
  expect(await page.locator('#local-test').getAttribute('src')).toContain('__glaze_retry=2');
  expect(await page.locator('#remote-test').getAttribute('data-retry-attempt')).toBeNull();
});

test('prepend preserves the reader anchor and mounts older rows immediately', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => { window.bridge.virtualList.container.scrollTop = 1000; });
  await page.waitForTimeout(400);
  const anchor = () => page.evaluate(() => {
    const c = window.bridge.virtualList.container;
    const row = [...c.querySelectorAll('.message-section')].find(r => r.getBoundingClientRect().bottom > c.getBoundingClientRect().top + 1);
    return { id: row.dataset.messageId, top: row.getBoundingClientRect().top };
  });
  const before = await anchor();
  await page.evaluate(() => window.bridge.prependMessages(JSON.stringify(Array.from({length: 10}, (_, i) =>
    window.__M('older' + i, 'older '.repeat(20))))));
  await page.waitForTimeout(500);
  const after = await anchor();
  expect(after.id).toBe(before.id);
  expect(Math.abs(after.top - before.top)).toBeLessThan(5);
});

test('edit retains attachment nodes and metadata on cancel and save', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => {
    const section = document.querySelector('.message-section[data-message-id="m29"]');
    const body = section.querySelector('.msg-body');
    body.insertAdjacentHTML('beforeend', '<div class="msg-image-attachment"><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></div><div class="bubble-meta">metadata</div>');
    window.bridge.startEdit('m29');
  });
  const row = page.locator('.message-section[data-message-id="m29"]');
  await expect(row.locator('.msg-image-attachment')).toHaveCount(1);
  await expect(row.locator('.bubble-meta')).toHaveCount(1);
  await expect(row.locator('.msg-image-attachment')).toBeHidden();
  await row.locator('[data-action="edit-cancel"]').click();
  // Native host acknowledges Cancel/Save by stopping the editor.
  await page.evaluate(() => window.bridge.stopEdit('m29'));
  await expect(row.locator('.msg-image-attachment')).toBeVisible();
  await page.evaluate(() => window.bridge.startEdit('m29'));
  await row.locator('.edit-textarea').fill('edited text');
  await row.locator('[data-action="edit-save"]').click();
  await page.evaluate(() => window.bridge.stopEdit('m29'));
  await expect(row.locator('.msg-image-attachment')).toBeVisible();
  await expect(row.locator('.bubble-meta')).toHaveText('metadata');
});
