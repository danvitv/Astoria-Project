// Only the app's loopback images can be retried with a cache-busting query.
export const LOCAL_IMAGE_RETRY_LIMIT = 2;
const LOCAL_IMAGE_RETRY_DELAY_MS = 350;
const LOOPBACK_FILE_URL = /^https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?\/__glaze_file__\b/i;

const imageSource = (img) => img?.dataset?.src || img?.getAttribute?.('src') || '';
export const isLocalServedImage = (img) => LOOPBACK_FILE_URL.test(imageSource(img));

export function scheduleLocalImageRetry(img) {
  if (!img || img.dataset.retryWired || !isLocalServedImage(img)) return;
  img.dataset.retryWired = '1';
  let pending = false;
  const retry = () => {
    if (pending) return;
    const original = imageSource(img);
    const attempt = Number(img.dataset.retryAttempt || '0') + 1;
    if (!isLocalServedImage(img) || attempt > LOCAL_IMAGE_RETRY_LIMIT) return;
    img.dataset.retryAttempt = String(attempt);
    pending = true;
    setTimeout(() => {
      pending = false;
      // Don't resurrect a removed image or replace a newer variation's URL.
      if (!img.isConnected || imageSource(img) !== original) return;
      const url = new URL(original);
      url.searchParams.set('__glaze_retry', String(attempt));
      img.src = url.href;
    }, LOCAL_IMAGE_RETRY_DELAY_MS * attempt);
  };
  img.addEventListener('error', retry);
  // Wiring sometimes happens after a cached failure, before DOM attachment.
  if (img.complete && img.naturalWidth === 0) retry();
}

export function retryFailedLocalImages(root) {
  for (const img of root?.querySelectorAll?.('img') || []) {
    scheduleLocalImageRetry(img);
  }
}
