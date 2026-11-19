import { test, expect } from '@playwright/test';
import { studioSwipes } from '../corpus/studio_swipes.js';

const switcher = '.agent-switcher';

async function boot(page, index = 0, extra = {}, studioEnabled = true) {
  await page.goto('/assets/chat_webview/index.html');
  await page.waitForFunction(() => !!window.bridge);
  await page.evaluate(({ fixture, index, extra, studioEnabled }) => {
    window.bridge.setMessageSettings({ studioEnabled });
    window.bridge.setMessages(JSON.stringify([{
      id: 'studio', role: 'assistant', displayName: 'Alice',
      text: index === 0 ? fixture.original : fixture.cleaned,
      swipeIndex: 0, swipeTotal: 2,
      agentSwipeIndex: index, agentSwipeTotal: 2,
      agentSwipeKinds: fixture.kinds,
      ...extra,
    }]));
  }, { fixture: studioSwipes, index, extra, studioEnabled });
}

async function update(page, fields) {
  await page.evaluate((fields) => {
    window.bridge.updateMessage(JSON.stringify({ id: 'studio', ...fields }));
    window.bridge.flush();
  }, fields);
}

test('the original is neutral white and the cleaned version is blue', async ({ page }) => {
  await boot(page);
  await expect(page.locator(switcher)).toHaveAttribute('data-agent-swipe-kind', 'final');
  await expect(page.locator(switcher)).toHaveCSS('color', 'rgb(224, 224, 224)');
  await update(page, {
    text: studioSwipes.cleaned, agentSwipeIndex: 1,
    agentSwipeTotal: 2, agentSwipeKinds: studioSwipes.kinds,
  });
  await expect(page.locator(switcher)).toHaveAttribute('data-agent-swipe-kind', 'cleaned');
  await expect(page.locator(`${switcher} .msg-switcher-count`)).toHaveText('2/2');
  await expect(page.locator(switcher)).toHaveCSS('color', 'rgb(120, 180, 255)');
  await update(page, { text: studioSwipes.original, agentSwipeIndex: 0 });
  await expect(page.locator(switcher)).toHaveCSS('color', 'rgb(224, 224, 224)');
  await expect(page.locator('[data-kind="swipe"] .msg-switcher-count')).toHaveText('1/2');
});

test('a cleaned version also starts blue after reopening the chat', async ({ page }) => {
  await boot(page, 1);
  await expect(page.locator(switcher)).toHaveAttribute('data-agent-swipe-kind', 'cleaned');
  await expect(page.locator(switcher)).toHaveCSS('color', 'rgb(120, 180, 255)');
});

test('partial updates preserve nested navigation and its color', async ({ page }) => {
  await boot(page, 1);
  await update(page, { tokens: 42 });
  await expect(page.locator(switcher)).toBeVisible();
  await expect(page.locator(switcher)).toHaveAttribute('data-agent-swipe-kind', 'cleaned');
  await expect(page.locator(`${switcher} .msg-switcher-count`)).toHaveText('2/2');
});

test('one remaining version hides the switcher without leaking old kinds', async ({ page }) => {
  await boot(page, 1);
  await update(page, { agentSwipeIndex: 0, agentSwipeTotal: 1 });
  await expect(page.locator(switcher)).toHaveCount(0);
  // A different outer variation with legacy data has no kind list.
  await update(page, { agentSwipeIndex: 1, agentSwipeTotal: 2 });
  await expect(page.locator(switcher)).toHaveAttribute('data-agent-swipe-kind', 'final');
});

test('single-version replies never show a nested switcher', async ({ page }) => {
  await boot(page, 0, { agentSwipeTotal: 1, agentSwipeKinds: undefined });
  await expect(page.locator(switcher)).toHaveCount(0);
});

test('the original stays readable with a light theme', async ({ page }) => {
  await boot(page);
  await page.evaluate(() => document.documentElement.style.setProperty('--text-color', '#202020'));
  await expect(page.locator(switcher)).toHaveCSS('color', 'rgb(32, 32, 32)');
});

test('a writer error with no nested swipes offers localized Final only alongside full regeneration', async ({ page }) => {
  await boot(page, 0, {
    text: studioSwipes.failed, isLast: true, isError: true,
    agentSwipeTotal: 0, agentSwipeKinds: undefined, studioFinalOnly: studioSwipes.finalOnly,
  });
  await page.evaluate(() => {
    window.regenerations = [];
    window.flutter_inappwebview = {
      callHandler: (name, ...args) => {
        if (name === 'onRegenerate') window.regenerations.push(args);
      },
    };
  });
  await expect(page.locator(switcher)).toHaveCount(0);
  await expect(page.locator('.msg-rerun-cleaner')).toHaveCount(0);
  const button = page.getByRole('button', { name: studioSwipes.finalOnly.label });
  await expect(button).toHaveAttribute('title', studioSwipes.finalOnly.title);
  expect(await button.evaluate(el => el.tabIndex)).toBe(0);
  await button.focus();
  await expect(button).toBeFocused();
  await page.keyboard.press('Enter');
  await page.locator('.msg-regenerate[data-mode="magic"]').click();
  expect(await page.evaluate(() => window.regenerations)).toEqual([
    ['studio', 'final'], ['studio', 'magic'],
  ]);
});

test('Final only follows the active outer variation, not the selected nested swipe', async ({ page }) => {
  await boot(page, 1, { isLast: true, studioFinalOnly: studioSwipes.finalOnly });
  const button = page.getByRole('button', { name: studioSwipes.finalOnly.label });
  await expect(button).toBeVisible();
  await expect(page.locator('.msg-regenerate[data-mode="magic"]')).toBeVisible();
  await update(page, { text: studioSwipes.original, agentSwipeIndex: 0 });
  await expect(button).toBeVisible();
  await update(page, { swipeIndex: 1, agentSwipeIndex: 0, agentSwipeTotal: 0, studioFinalOnly: null });
  await expect(button).toHaveCount(0);
  await expect(page.locator(switcher)).toHaveCount(0);
  await expect(page.locator('.msg-regenerate[data-mode="magic"]')).toHaveCount(0);
});

test('Final only requires Studio and the trailing reply, and hides while editing or sending', async ({ page }) => {
  await boot(page, 0, { isLast: true, studioFinalOnly: studioSwipes.finalOnly }, false);
  const button = page.getByRole('button', { name: studioSwipes.finalOnly.label });
  await expect(button).toBeHidden();
  await page.evaluate(() => window.bridge.setMessageSettings({ studioEnabled: true }));
  await expect(button).toBeVisible();
  await page.evaluate(() => window.bridge.setSendPending(true));
  await expect(button).toBeHidden();
  await page.evaluate(() => window.bridge.setSendPending(false));
  await expect(button).toBeVisible();
  await page.evaluate(() => window.bridge.startEdit('studio'));
  await expect(button).toBeHidden();
  await page.evaluate(() => window.bridge.setLastMessage(null));
  await page.evaluate(() => window.bridge.stopEdit('studio'));
  await expect(button).toBeHidden();
  await page.evaluate(() => window.bridge.setLastMessage('studio'));
  await expect(button).toBeVisible();
});

test('the Studio footer fits both switchers and Final only at mobile width', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 640 });
  await boot(page, 1, { isLast: true, studioFinalOnly: studioSwipes.finalOnly });
  const button = page.getByRole('button', { name: studioSwipes.finalOnly.label });
  for (const layout of ['default', 'bubble']) {
    await page.evaluate(layout => window.bridge.applyLayout(layout), layout);
    await expect(button).toBeInViewport({ ratio: 1 });
    await expect(page.locator('[data-kind="swipe"]')).toBeInViewport({ ratio: 1 });
    await expect(page.locator(switcher)).toBeInViewport({ ratio: 1 });
    await expect(page.locator('.msg-actions-btn')).toBeInViewport({ ratio: 1 });
  }
});
