// SPDX-License-Identifier: MIT
// The web UI as a user drives it, against runs the e2e's ui check made (tools/e2e.zig):
//   run 1: the bank example, seed 3, finished, failing "total balance is conserved";
//   run 2: the bank example, seed 4, finished;
//   run 3: the bank example, running while these run;
//   run 4: the bank example, flat, running: stopped and resumed from its page.
const { test, expect } = require("@playwright/test");

const property = "total balance is conserved";

async function propertyOpen(page) {
  const element = page.locator(`.property[data-message="${property}"]`);
  await element.locator(".row").first().click();
  await expect(element.locator(".examples td.fail-text").first()).toBeVisible();
  return element;
}

test("a run opens by its URL, and another when the URL changes", async ({ page }) => {
  await page.goto("/#1");
  await expect(page.locator("#main h2")).toContainText("Run 1");
  await page.evaluate(() => { location.hash = "#2"; });
  await expect(page.locator("#main h2")).toContainText("Run 2");
  await expect(page).toHaveURL(/#2$/);
});

test("a failing property's causality analysis, to its end, and again after a reload", async ({ page, request }) => {
  await page.goto("/#1");
  const element = await propertyOpen(page);
  const button = element.locator(".examples button.causality").first();
  const branch = Number(await button.getAttribute("data-branch"));
  await button.click();
  const result = element.locator(".causality-result");
  // The analysis's own heading (once done, the faults that make the failure likelier get theirs).
  const title = result.locator(".group-title").first();
  await expect(title).toContainText(`branch ${branch}`);
  // Running until every moment's futures are in (the refinements inside jumps too).
  await expect(title).not.toContainText("running", { timeout: 15 * 60 * 1000 });
  const analyses = await (await request.get("/runs/1/causality")).json();
  const latest = analyses[analyses.length - 1];
  expect(latest.done).toBe(true);
  expect(latest.of.branch).toBe(branch);
  expect(latest.of.property).toBe(property);
  expect(latest.points.length).toBeGreaterThanOrEqual(8);
  for (const point of latest.points) {
    expect(point.low).toBeLessThanOrEqual(point.probability);
    expect(point.probability).toBeLessThanOrEqual(point.high);
  }
  // Certain at the failure.
  const last = latest.points.reduce((a, b) => (b.vtime_ms > a.vtime_ms ? b : a));
  expect(last.probability).toBe(1);
  // Every point drawn, with its interval.
  await expect(result.locator("circle")).toHaveCount(latest.points.length);
  await expect(result.locator("polygon")).toHaveCount(1);
  // A point opens the logs up to its moment, in the Logs explorer.
  await result.locator("circle").first().click();
  await expect(page).toHaveURL(/#1\/explorer$/);
  await expect(page.locator("#logs .summary")).toContainText(`branch ${branch}`);
  // After a reload of the report the analysis is there, without another.
  await page.goto("/#1");
  await page.reload();
  const again = await propertyOpen(page);
  await expect(again.locator(".causality-result circle")).toHaveCount(latest.points.length);
  const after = await (await request.get("/runs/1/causality")).json();
  expect(after.length).toBe(analyses.length);
});

test("the map marks the run's failures", async ({ page }) => {
  await page.goto("/#1/explorer");
  await expect(page.locator("#map-body circle.mark").first()).toBeVisible();
});

test("a run's views are pages of their own, each drawing only itself", async ({ page }) => {
  await page.goto("/#1");
  await expect(page.locator("section#properties")).toBeVisible();
  await expect(page.locator("section#map")).toHaveCount(0);
  await page.locator('.view-tabs button[data-view="explorer"]').click();
  await expect(page).toHaveURL(/#1\/explorer$/);
  await expect(page.locator("section#map")).toBeVisible();
  await expect(page.locator("section#properties")).toHaveCount(0);
  await page.locator('.view-tabs button[data-view="output"]').click();
  await expect(page).toHaveURL(/#1\/output$/);
  await expect(page.locator("#output-body")).toContainText("[determinismo]");
  // A view's URL opens it.
  await page.goto("/#2/explorer");
  await expect(page.locator("#main h2")).toContainText("Run 2");
  await expect(page.locator("section#map")).toBeVisible();
});

test("the tree's timelines: a row's tooltip under the pointer, its logs on a click", async ({ page }) => {
  await page.goto("/#1/explorer");
  const tree = page.locator("#map-body .tree");
  await expect(tree.locator("svg")).toBeVisible();
  // The timelines are a few paths, not an element each.
  expect(await tree.locator("svg path").count()).toBeLessThan(50);
  const box = await tree.boundingBox();
  // The first row, near the right of the plot (inside every timeline's line).
  const y = box.y + 34 + 3;
  await page.mouse.move(box.x + box.width * 0.6, y);
  await expect(page.locator("#tip")).toContainText("Timeline #");
  await page.mouse.click(box.x + box.width * 0.6, y);
  await expect(page.locator("#logs .summary")).toContainText("branch");
});

test("a running run's page asks only for the timelines it does not have", async ({ page }) => {
  const asked = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (url.pathname === "/runs/3/timelines") asked.push(url.search);
  });
  await page.goto("/#3");
  await expect(page.locator("#main h2")).toContainText("Run 3");
  await page.waitForTimeout(8000); // A few refreshes (every 2 seconds while running).
  expect(asked.filter((search) => search === "").length).toBe(1);
  expect(asked.filter((search) => search.startsWith("?offset=")).length).toBeGreaterThanOrEqual(2);
});


test("the run's timelines replayed as it ran show among determinismo's own properties", async ({ page }) => {
  // Run 1's 16 timelines: the verifier replays timeline 15 as the run ends.
  await page.goto("/#1");
  const element = page.locator('.property[data-message="timelines replay to their recorded history"]');
  await expect(element).toBeVisible();
  await expect(element.locator(".badge")).toHaveText("passed");
  await expect(element.locator(".counts")).toContainText("hit in 1");
  const group = element.locator('xpath=preceding-sibling::div[contains(@class, "group-title")][1]');
  await expect(group).toHaveText("determinismo");
  // Opened: the timelines replayed, each the same or where it parted.
  await element.locator(".row").first().click();
  const row = element.locator(".examples tr.clickable").first();
  await expect(row.locator("td").first()).toHaveText("15");
  await expect(row.locator("td.pass-text")).toHaveText("the same");
  await expect(element.locator(".examples .muted")).toContainText("1 timelines replayed, 0 parted");
});

test("a run stopped from its page resumes from it, and runs on", async ({ page, request }) => {
  await page.goto("/#4");
  const badge = page.locator("#main .badge").first();
  await expect(badge).toHaveText("running");
  await page.locator("#run-stop").click();
  await expect(badge).toHaveText("stopped");
  const stopped = await (await request.get("/runs/4")).json();
  expect(stopped.state).toBe("stopped");
  // A tree run would not offer it: this one is flat.
  await page.locator("#run-resume").click();
  await expect(badge).toHaveText("running");
  await expect(page.locator("#run-stop")).toBeVisible();
  const resumed = await (await request.get("/runs/4")).json();
  expect(resumed.state).toBe("running");
  // Its output says what it skipped.
  await expect.poll(async () => (await request.get("/runs/4/output")).text(), { timeout: 120 * 1000 })
    .toContain("timelines recorded, skipped");
});
