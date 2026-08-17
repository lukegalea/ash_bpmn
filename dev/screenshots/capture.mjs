// SPDX-FileCopyrightText: 2026 Luke Galea
// SPDX-License-Identifier: MIT
//
// Captures the screenshots used in README.md and documentation/topics/*.
// Requires the demo app to be running:
//
//     mix dev.setup && mix dev.assets && mix dev.server
//     node dev/screenshots/capture.mjs
//
// Images are written to documentation/assets/. Regenerate them whenever the
// LiveViews change — a stale screenshot is worse than none.

import { chromium } from "playwright";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../documentation/assets");
const base = process.env.BASE_URL || "http://localhost:4008";

mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
});

const shot = async (name, target) =>
  (target || page).screenshot({ path: `${outDir}/${name}.png` });

const settle = async (ms = 1200) => page.waitForTimeout(ms);

// bpmn-js fits the diagram edge to edge, which slides the leftmost element
// under the palette overlay. One ctrl+wheel step out leaves a margin.
const zoomOut = async (steps = 1) => {
  const box = await page.locator(".djs-container").first().boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.keyboard.down("Control");
  for (let i = 0; i < steps; i++) await page.mouse.wheel(0, 120);
  await page.keyboard.up("Control");
  await settle(400);
};

// ── Designer ───────────────────────────────────────────────────────────────

await page.goto(`${base}/designer`, { waitUntil: "networkidle" });
// The canvas is drawn by bpmn-js after the LiveView hook mounts and imports
// the XML, so wait for a rendered shape rather than for load.
await page.waitForSelector(".djs-container svg", { timeout: 20_000 });
await settle();
await zoomOut();
await shot("designer", page.locator("#ash-bpmn-designer-root").first());

// With a user task selected, the server-rendered properties panel shows the
// candidate / exclusion / outcome / timer forms.
const userTask = page.locator('.djs-element[data-element-id="ManagerApproval"]').first();
await userTask.click();
await settle(800);
await shot("designer-user-task", page.locator("#ash-bpmn-designer-root").first());

// A service task selects down to a single field: the action reference.
const serviceTask = page.locator('.djs-element[data-element-id="Provision"]').first();
await serviceTask.click();
await settle(800);
await shot("designer-service-task", page.locator("#ash-bpmn-designer-root").first());

// ── Task list ──────────────────────────────────────────────────────────────

await page.goto(`${base}/tasks`, { waitUntil: "networkidle" });
await settle(800);
await shot("task-list", page.locator("#ash-bpmn-tasklist").first());

// ── Instance viewer ────────────────────────────────────────────────────────

// Pick instances by status rather than by row position: the seeds create one
// of each, and which row is which depends on insertion order.
const openInstance = async (status) => {
  await page.goto(`${base}/instances`, { waitUntil: "networkidle" });
  await settle(500);

  const row = page.locator("tr", { hasText: status }).first();
  if ((await row.count()) === 0) {
    throw new Error(`no ${status} instance seeded — run mix dev.reset`);
  }

  await row.locator('a[href^="/instances/"]').click();
  await page.waitForSelector(".djs-container svg", { timeout: 20_000 });
  await settle();
  await zoomOut();
};

// A finished run: every token consumed, the full audit trail in the events list.
await openInstance("completed");
await shot("viewer", page.locator("#ash-bpmn-viewer-root").first());

// A run still in flight, parked on a human task.
await openInstance("running");
await shot("viewer-running", page.locator("#ash-bpmn-viewer-root").first());

await browser.close();
console.log(`wrote screenshots to ${outDir}`);
