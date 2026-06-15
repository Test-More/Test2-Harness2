import { defineConfig, devices } from '@playwright/test';
import * as path from 'path';

// The Test2-Harness UI test suite boots a *real* yath server backed by an
// ephemeral SQLite database with a demo log imported into it, then drives the
// inlined front-end (jQuery + DataTables + Chart.js) with a headless browser.
//
// The fixed demo log is demo/simple-fail.jsonl.bz2: a small run with one
// passing job (simple.t), one failing job (fail.t, with a failing subtest),
// and the harness-internal job. The failing job/subtest lets us assert the
// "drill into a failing run -> jobs -> events -> subtests" path end to end.

const PORT = Number(process.env.YATH_UI_TEST_PORT || 8788);
const BASE_URL = `http://127.0.0.1:${PORT}`;

// Repo root is the parent of js-tests/. The yath server resolves share/ and
// demo/ relative to its cwd, so the webServer must run from the repo root.
const REPO_ROOT = path.resolve(__dirname, '..');

// Locate the yath launcher. Prefer an explicit override, else rely on PATH.
const YATH = process.env.YATH_BIN || 'yath';
const DEMO_LOG = process.env.YATH_UI_DEMO_LOG || 'demo/simple-fail.jsonl.bz2';

// NOTE: foreground (no --daemon) so Playwright owns the process lifecycle.
const SERVER_CMD = [
  'perl -Dlib "$(command -v',
  YATH + ')"',
  'server',
  '--ephemeral=SQLite',
  '--single-user',
  '--single-run',
  '--no-upload',
  `--port ${PORT}`,
  // Several Starman workers: the all-runs "/stream" endpoint stays open for
  // live updates and would otherwise tie up a single worker, starving the
  // page's other requests (CSS/JS/JSON) and wedging the suite.
  '--workers 5',
  DEMO_LOG,
].join(' ');

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never' }]],

  use: {
    baseURL: BASE_URL,
    headless: true,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  webServer: {
    command: SERVER_CMD,
    cwd: REPO_ROOT,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },
});
