/* Small client-side probe used by the stress harness. */
(() => {
  const start = performance.now();
  addEventListener('load', () => {
    const total = Math.round(performance.now() - start);
    document.documentElement.dataset.loadMs = String(total);
  });
})();
