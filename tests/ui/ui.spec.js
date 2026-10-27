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
  await expect(result.locator(".group-title")).toContainText(`branch ${branch}`);
  // Running until every moment's futures are in (the refinements inside jumps too).
  await expect(result.locator(".group-title")).not.toContainText("running", { timeout: 15 * 60 * 1000 });
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
  // A point opens the logs up to its moment.
  await result.locator("circle").first().click();
  await expect(page.locator("#logs .summary")).toContainText(`branch ${branch}`);
  // After a reload the analysis is there, without another.
  await page.reload();
  const again = await propertyOpen(page);
  await expect(again.locator(".causality-result circle")).toHaveCount(latest.points.length);
  const after = await (await request.get("/runs/1/causality")).json();
  expect(after.length).toBe(analyses.length);
});

test("the map marks the run's failures", async ({ page }) => {
  await page.goto("/#1");
  await expect(page.locator("#map-body circle.mark").first()).toBeVisible();
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
