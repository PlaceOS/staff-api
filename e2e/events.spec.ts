import { expect, overflows, previewerErrors, renderCard, snapshot, test } from "./support/card";
import { ok } from "./support/fake-mcp";
import { EVENT, PEOPLE, ROOMS, at } from "./support/fixtures";

const SHOW = { id: EVENT.id };

test.describe("event card", () => {
  for (const viewport of ["desktop", "tablet", "mobile"] as const) {
    for (const theme of ["light", "dark"] as const) {
      test(`renders on ${viewport} in ${theme}`, async ({ page }) => {
        const { card } = await renderCard(page, "events_show", SHOW, { viewport, theme });
        await expect(card.locator("h1")).toHaveText("Design review");
        await expect(card.locator(".carousel img")).toBeVisible();
        if (viewport !== "mobile") await expect(card.locator(".map .canvas img")).toBeVisible();
        await expect(card.locator(".avatar img").first()).toBeVisible();
        expect(await overflows(card)).toBe(false);
        expect(await previewerErrors(page)).toEqual([]);
        await snapshot(page, `events-${viewport}-${theme}`);
      });
    }
  }

  test("shows when, the status and the room's response", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW);
    await expect(card.locator(".subtitle")).toHaveText("Today, Tue, 13 Oct · 4:00 – 4:30 pm AEDT");
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Confirmed", "Room accepted"]);
    await expect(card.locator(".details")).toContainText("Sydney Room 1");
    await expect(card.locator(".details")).toContainText("Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".details .chips .chip")).toHaveText(["4 seats", "Wireless presenter", "Zoom Room"]);
    await expect(card.locator("text=Check-in")).toHaveCount(0);
  });

  test("puts the photos and the map side by side on desktop", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW);
    const photos = await card.locator(".carousel").boundingBox();
    const map = await card.locator(".map").boundingBox();
    expect(photos && map).toBeTruthy();
    expect(Math.abs(photos!.y - map!.y)).toBeLessThan(2);
    expect(map!.x).toBeGreaterThan(photos!.x + photos!.width - 1);
    await expect(card.locator(".carousel .caption")).toHaveText("Sydney Room 1 · 4 seats");
    await expect(card.locator(".map .caption")).toHaveText("Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".map-toggle")).toBeHidden();
  });

  test("letterboxes the photos and pages through them", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "events_show", SHOW);
    const photo = card.locator(".carousel img");
    await expect(photo).toHaveCSS("object-fit", "contain");
    const first = await photo.getAttribute("src");
    await card.getByRole("button", { name: "Next photo" }).click();
    await expect(photo).not.toHaveAttribute("src", first!);
    await expect(card.getByRole("button", { name: "Photo 2" })).toHaveAttribute("aria-current", "true");
    await card.getByRole("button", { name: "Photo 1" }).click();
    await expect(photo).toHaveAttribute("src", first!);
    // each photo is fetched once
    expect(mcp.callsTo("spaces_image").map((args) => args.index)).toEqual([0, 1]);
  });

  test("zooms and recentres the map", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW);
    const map = card.locator(".map");
    await expect(map.locator(".pin")).toBeVisible();
    await expect(map).toHaveAttribute("data-scale", "2.00");
    await card.getByRole("button", { name: "Zoom in" }).click();
    await expect(map).toHaveAttribute("data-scale", "3.00");
    await card.getByRole("button", { name: "Zoom out" }).click();
    await card.getByRole("button", { name: "Zoom out" }).click();
    await expect(map).toHaveAttribute("data-scale", "1.33");
    await card.getByRole("button", { name: "Recenter" }).click();
    await expect(map).toHaveAttribute("data-scale", "2.00");

    // dragging pans the map
    const canvas = map.locator(".canvas");
    const before = await canvas.evaluate((node) => getComputedStyle(node).transform);
    const box = (await map.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    // the pin is near the map's top left corner, so there's only room to pan the other way
    await page.mouse.move(box.x + box.width / 2 - 60, box.y + box.height / 2 - 30, { steps: 4 });
    await page.mouse.up();
    expect(await canvas.evaluate((node) => getComputedStyle(node).transform)).not.toEqual(before);
  });

  test("hides the map under the photos on mobile until asked for", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "events_show", SHOW, { viewport: "mobile" });
    await expect(card.locator(".carousel img")).toBeVisible();
    await expect(card.locator(".map")).toBeHidden();
    expect(mcp.callsTo("spaces_map")).toEqual([]);

    await card.getByRole("button", { name: "Show map" }).click();
    await expect(card.locator(".map .canvas img")).toBeVisible();
    const photos = (await card.locator(".carousel").boundingBox())!;
    const map = (await card.locator(".map").boundingBox())!;
    expect(map.y).toBeGreaterThan(photos.y + photos.height - 1);
    await expect(card.locator(".details")).toContainText("Level 1 · PlaceOS Sydney Dev");
    await snapshot(page, "events-mobile-map-open");

    await card.getByRole("button", { name: "Hide map" }).click();
    await expect(card.locator(".map")).toBeHidden();
    expect(mcp.callsTo("spaces_map")).toHaveLength(1);
  });

  test("shows the host and attendees with photos, initials when there's none", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW);
    const people = card.locator(".people li");
    await expect(people).toHaveCount(3);
    await expect(people.nth(0)).toContainText("Johanna Lorenz");
    await expect(people.nth(0)).toContainText("Accepted");
    await expect(people.nth(0).locator(".avatar img")).toBeVisible();
    await expect(people.nth(1)).toContainText("Tentative");
    await expect(people.nth(1).locator(".avatar")).toHaveText("BJ");
    await expect(people.nth(1).locator(".avatar img")).toHaveCount(0);
    await expect(people.nth(2)).toContainText("Not responded");
    await expect(card.locator(".details")).toContainText("Steve Takach");
  });

  test("lists a large meeting's first attendees and the rest on request", async ({ page }) => {
    const crowd = Array.from({ length: 12 }, (_, n) => ({ name: `Guest ${n + 1}`, email: `guest${n + 1}@acme.com`, response_status: "accepted", resource: false }));
    const { card } = await renderCard(page, "events_show", SHOW, { tools: { events_show: () => ok({ ...EVENT, attendees: [...EVENT.attendees, ...crowd] }) } });
    await expect(card.locator(".people li")).toHaveCount(8);
    await card.getByRole("button", { name: "+7 more" }).click();
    await expect(card.locator(".people li")).toHaveCount(15);
  });

  test("joins and copies the online meeting", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW);
    await expect(card.locator(".online")).toContainText("Microsoft Teams");
    await expect(card.locator(".online")).toContainText("ID 435 269 110 526 74");
    await card.getByRole("button", { name: "Copy details" }).click();
    await expect(card.locator("#status")).toHaveText("Meeting details copied");

    await page.context().route("https://teams.microsoft.com/**", (route) => route.fulfill({ body: "Teams" }));
    const popup = page.waitForEvent("popup");
    await card.getByRole("button", { name: "Join Teams" }).click();
    expect((await popup).url()).toContain("teams.microsoft.com");
  });

  test("edits the meeting", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "events_show", SHOW);
    await card.getByRole("button", { name: "Edit" }).click();
    await card.locator("input[name=title]").fill("Design review v2");
    await card.locator("input[name=start]").fill("16:30");
    await card.locator("input[name=end]").fill("17:00");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("Meeting updated");
    expect(mcp.callsTo("events_edit")).toEqual([{ id: EVENT.id, system_id: ROOMS[0].id, title: "Design review v2", event_start: at("16:30"), event_end: at("17:00") }]);
    await expect(card.locator("h1")).toHaveText("Design review v2");
  });

  test("adds people from the attendees", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "events_show", SHOW);
    await card.getByRole("button", { name: "+ Add people" }).click();
    const attendees = card.locator("textarea[name=attendees]");
    await expect(attendees).toBeFocused();
    await attendees.fill(`${await attendees.inputValue()}, new@acme.com`);
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("Meeting updated");
    expect(mcp.callsTo("events_edit")[0].attendees).toEqual([PEOPLE.johanna.email, PEOPLE.bob.email, PEOPLE.priya.email, "new@acme.com"]);
  });

  test("cancels the meeting once confirmed", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "events_show", SHOW);
    await card.getByRole("button", { name: "Cancel meeting" }).click();
    await expect(card.locator(".footer")).toContainText("Cancel this meeting and notify the attendees?");
    await card.getByRole("button", { name: "Keep it" }).click();
    expect(mcp.callsTo("events_destroy")).toEqual([]);

    await card.getByRole("button", { name: "Cancel meeting" }).click();
    await card.getByRole("button", { name: "Yes, cancel it" }).click();
    await expect(card.locator("#status")).toHaveText("Meeting cancelled");
    await expect(card.locator(".chips[aria-label=Status] .chip").first()).toHaveText("Cancelled");
    await expect(card.getByRole("button", { name: "Edit" })).toHaveCount(0);
    expect(mcp.callsTo("events_destroy")).toEqual([{ id: EVENT.id, system_id: ROOMS[0].id }]);
  });

  test("only offers changes to the host", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW, { tools: { users_current: () => ok(PEOPLE.bob) } });
    await expect(card.getByRole("button", { name: "Join Teams" })).toBeVisible();
    await expect(card.getByRole("button", { name: "Edit" })).toHaveCount(0);
    await expect(card.getByRole("button", { name: "Cancel meeting" })).toHaveCount(0);
    await expect(card.getByRole("button", { name: "+ Add people" })).toHaveCount(0);
  });

  test("shows a meeting without a room, online or guests", async ({ page }) => {
    const bare = { ...EVENT, system: null, system_id: null, location: "Café", online_meeting_url: null, online_meeting_id: null, online_meeting_provider: null, attendees: [EVENT.attendees[0]] };
    const { card, mcp } = await renderCard(page, "events_show", SHOW, { tools: { events_show: () => ok(bare) } });
    await expect(card.locator(".media")).toHaveCount(0);
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Confirmed"]);
    await expect(card.locator(".details")).toContainText("Café");
    await expect(card.locator(".details")).toContainText("No other guests · host only");
    expect(mcp.callsTo("spaces_map")).toEqual([]);
    await snapshot(page, "events-desktop-bare");
  });

  test("shows the photos alone when the room isn't on a map", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW, { tools: { spaces_map: () => ({ status: 404, body: { error: "not on a map" } }) } });
    await expect(card.locator(".carousel")).toHaveClass(/solo/);
    await expect(card.locator(".map")).toHaveCount(0);
  });

  test("renders the meeting booked by events_book", async ({ page }) => {
    const { card } = await renderCard(page, "events_book", { title: "Catch up", event_start: at("17:00"), event_end: at("17:30"), attendees: JSON.stringify([PEOPLE.johanna.email]), system_id: ROOMS[1].id });
    await expect(card.locator("h1")).toHaveText("Catch up");
    await expect(card.locator(".details")).toContainText("Sydney Room 2");
  });

  test("shows an error when the meeting can't be loaded", async ({ page }) => {
    const { card } = await renderCard(page, "events_show", SHOW, { tools: { events_show: () => ({ status: 404, body: { error: "not found" } }) } });
    await expect(card.locator(".status.error")).toHaveText("Unable to load the meeting: not found");
  });
});
