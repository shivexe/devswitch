// Browsers live in node_modules (installed with PLAYWRIGHT_BROWSERS_PATH=0), not the global cache.
process.env.PLAYWRIGHT_BROWSERS_PATH ??= '0';
module.exports = { testDir: '.', testMatch: '*.spec.js', workers: 1, timeout: 20000, reporter: 'list' };
