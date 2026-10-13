import { expect, overflows, previewerErrors, renderCard, snapshot, test } from "./support/card";
import { failure, ok } from "./support/fake-mcp";
import { PEOPLE, ROOMS, TIMEZONE, at, spaceSchedule } from "./support/fixtures";

const SHOW = { id: ROOMS[0].id };

test.describe("space card", () => {
  for (const viewport of ["desktop", "tablet", "mobile"] as const) {
    for (const theme of ["light", "dark"] as const) {
      test(`renders on ${viewport} in ${theme}`, async ({ page }) => {
        const { card } = await renderCard(page, "spaces_show", SHOW, { viewport, theme });
        await expect(card.locator("h1")).toHaveText("Sydney Room 1");
        await expect(card.locator(".carousel img")).toBeVisible();
        if (viewport !== "mobile") await expect(card.locator(".map .canvas img")).toBeVisible();
        await expect(card.locator(".timeline .bar")).toBeVisible();
        await expect(card.getByRole("button", { name: "Book room" })).toBeVisible();
        expect(await overflows(card)).toBe(false);
        expect(await previewerErrors(page)).toEqual([]);
        await snapshot(page, `spaces-${viewport}-${theme}`);
      });
    }
  }

  test("shows the room, where it is, its seats and features", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    await expect(card.locator(".head .subtitle")).toHaveText("Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".chips[aria-label=Space] .chip")).toHaveText(["4 seats"]);
    await expect(card.locator(".chips[aria-label=Features] .chip")).toHaveText(["Wireless presenter", "Zoom Room"]);
    await expect(card.getByRole("button", { name: "All rooms" })).toHaveCount(0);
  });

  test("flags rooms that need approval", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", { id: ROOMS[2].id });
    await expect(card.locator(".chips[aria-label=Space] .chip")).toHaveText(["10 seats", "Needs approval"]);
    // no photos: the map takes the row
    await expect(card.locator(".carousel")).toHaveCount(0);
    await expect(card.locator(".map")).toHaveClass(/solo/);
    await expect(card.locator(".map .canvas img")).toBeVisible();
  });

  test("takes the location from the map when the zones are unknown", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: (args) => ok({ ...spaceSchedule(args.id), zones: [] }) } });
    await expect(card.locator(".head .subtitle")).toHaveText("Level 1 · PlaceOS Sydney Dev");
  });

  test("puts the photos and the map side by side on desktop", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    const photos = (await card.locator(".carousel").boundingBox())!;
    const map = (await card.locator(".map").boundingBox())!;
    expect(Math.abs(photos.y - map.y)).toBeLessThan(2);
    expect(Math.abs(photos.height - map.height)).toBeLessThan(2);
    expect(map.x).toBeGreaterThan(photos.x + photos.width - 1);
    await expect(card.locator(".carousel .caption")).toHaveText("Sydney Room 1 · 4 seats");
    await expect(card.locator(".map .caption")).toHaveText("Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".map-toggle")).toBeHidden();
  });

  test("letterboxes the photos and pages through them", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "spaces_show", SHOW);
    const photo = card.locator(".carousel img");
    await expect(photo).toHaveCSS("object-fit", "contain");
    const first = await photo.getAttribute("src");
    await card.getByRole("button", { name: "Next photo" }).click();
    await expect(photo).not.toHaveAttribute("src", first!);
    await expect(card.getByRole("button", { name: "Photo 2" })).toHaveAttribute("aria-current", "true");
    await card.getByRole("button", { name: "Previous photo" }).click();
    await expect(photo).toHaveAttribute("src", first!);
    await expect(card.getByRole("button", { name: "Photo 1" })).toHaveAttribute("aria-current", "true");
    expect(mcp.callsTo("spaces_image")).toEqual([{ id: ROOMS[0].id, index: 0 }, { id: ROOMS[0].id, index: 1 }]);
  });

  test("zooms and recentres the map", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
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
  });

  test("hides the map under the photos on mobile until asked for", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "spaces_show", SHOW, { viewport: "mobile" });
    await expect(card.locator(".carousel img")).toBeVisible();
    await expect(card.locator(".map")).toBeHidden();
    expect(mcp.callsTo("spaces_map")).toEqual([]);

    await card.getByRole("button", { name: "Show map" }).click();
    await expect(card.locator(".map .canvas img")).toBeVisible();
    const photos = (await card.locator(".carousel").boundingBox())!;
    const map = (await card.locator(".map").boundingBox())!;
    expect(map.y).toBeGreaterThan(photos.y + photos.height - 1);
    await snapshot(page, "spaces-mobile-map-open");

    await card.getByRole("button", { name: "Hide map" }).click();
    await expect(card.locator(".map")).toBeHidden();
    expect(mcp.callsTo("spaces_map")).toEqual([{ id: ROOMS[0].id }]);
  });

  test("leaves out the media row when there are no photos or map", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", { id: ROOMS[2].id }, { tools: { spaces_map: () => failure(404, "not on a map") } });
    await expect(card.locator(".chips[aria-label=Space] .chip").first()).toHaveText("10 seats");
    await expect(card.locator(".timeline .bar")).toBeVisible();
    await expect(card.locator(".media")).toHaveCount(0);
  });

  test("shows the day's meetings on the timeline and in a list", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    await expect(card.locator(".day h2")).toHaveText("Today, Tue, 13 Oct");
    const busy = card.locator(".timeline .seg.kind-busy");
    await expect(busy).toHaveCount(3);
    await expect(busy.nth(0)).toHaveAttribute("title", /^9:00\s–\s9:30\sam Standup$/);
    await expect(busy.nth(1)).toHaveAttribute("title", /^1:00\s–\s2:00\spm Private meeting$/);
    await expect(card.locator(".timeline .seg.kind-past")).toHaveCount(1);
    await expect(card.locator(".timeline .legend")).toHaveText(["FreeBookedPast"]);
    await expect(card.locator(".timeline .ticks span").first()).toHaveText("7 am");

    // the busy segments are where the meetings are on a 7am to 7pm bar
    const bar = (await card.locator(".timeline .bar").boundingBox())!;
    const standup = (await busy.nth(0).boundingBox())!;
    expect(Math.abs(standup.x - (bar.x + (bar.width * 2) / 12))).toBeLessThan(2);
    expect(Math.abs(standup.width - bar.width / 24)).toBeLessThan(2);

    const rows = card.locator(".meetings li");
    await expect(rows).toHaveCount(3);
    await expect(rows.nth(0)).toHaveText(/9:00\s–\s9:30\sam\s*Standup\s*bob@acme.com/);
    await expect(rows.nth(0)).toHaveClass(/past/);
    await expect(rows.nth(1)).toContainText("Private meeting");
    await expect(rows.nth(2)).toContainText("Design review");
    await expect(rows.nth(2)).not.toHaveClass(/past/);
  });

  test("stretches the timeline to meetings outside the working day and lists all day events", async ({ page }) => {
    const schedule = spaceSchedule(ROOMS[0].id);
    const events = [
      { id: "all", title: "Office closed for cleaning", host: null, event_start: at("00:00"), event_end: at("00:00", 1), all_day: true, private: false },
      { id: "early", title: "Early call", host: PEOPLE.johanna.email, event_start: at("06:00"), event_end: at("06:30"), all_day: false, private: false },
      ...schedule.events,
      { id: "late", title: "Late call", host: null, event_start: at("20:00"), event_end: at("20:30"), all_day: false, private: false },
    ];
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: () => ok({ ...schedule, events }) } });
    await expect(card.locator(".timeline .ticks span").first()).toHaveText("6 am");
    const bar = (await card.locator(".timeline .bar").boundingBox())!;
    const late = (await card.locator(".timeline .seg.kind-busy").last().boundingBox())!;
    // 6am to 9pm, the late call is 14 to 14.5 hours in
    expect(Math.abs(late.x - (bar.x + (bar.width * 14) / 15))).toBeLessThan(2);
    await expect(card.locator(".meetings li").first()).toHaveText(/All day\s*Office closed for cleaning/);
    await expect(card.locator(".meetings li")).toHaveCount(6);
  });

  test("starts the booking at the next free time and outlines it", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    const form = card.locator("form#book");
    // 3:50pm now, 4:00 is booked until 4:30
    await expect(form.locator("input[name=start]")).toHaveValue("16:30");
    await expect(form.locator("select[name=duration]")).toHaveValue("30");
    await expect(form.locator("input[name=title]")).toHaveValue("Meeting");
    await expect(card.locator("#clash")).toBeHidden();
    await expect(card.locator(".footer .summary")).toHaveText("Sydney Room 1 · Today, Tue, 13 Oct · 4:30 – 5:00 pm");
    await expect(card.getByRole("button", { name: "Book room" })).toBeEnabled();

    const bar = (await card.locator(".timeline .bar").boundingBox())!;
    const selected = (await card.locator(".timeline .selected").boundingBox())!;
    // 4:30pm is 9.5 hours into the 12 hour bar
    expect(Math.abs(selected.x + selected.width / 2 - (bar.x + (bar.width * 9.75) / 12))).toBeLessThan(3);
  });

  test("sets the start from a click on the timeline", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    const bar = card.locator(".timeline .bar");
    const box = (await bar.boundingBox())!;
    // 5pm is 10 hours into the bar
    await bar.click({ position: { x: (box.width * 10) / 12 + 2, y: box.height / 2 } });
    await expect(card.locator("input[name=start]")).toHaveValue("17:00");
    await expect(card.locator(".footer .summary")).toHaveText("Sydney Room 1 · Today, Tue, 13 Oct · 5:00 – 5:30 pm");

    // the elapsed part of the day picks the next quarter hour, which is booked
    await card.locator(".timeline .bar").click({ position: { x: (box.width * 3) / 12, y: box.height / 2 } });
    await expect(card.locator("input[name=start]")).toHaveValue("16:00");
    await expect(card.locator("#clash")).toBeVisible();
  });

  test("warns about a clash, blocks booking and offers the next free time", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "spaces_show", SHOW);
    await card.locator("input[name=start]").fill("16:00");
    const banner = card.locator("#clash");
    await expect(banner.locator(".grow")).toHaveText("Booked 4:00 – 4:30 pm. Next free at 4:30 pm.");
    await expect(card.getByRole("button", { name: "Book room" })).toBeDisabled();
    await expect(card.locator(".meetings li.clash")).toContainText("Design review");
    await snapshot(page, "spaces-desktop-clash");

    // a time earlier today has passed, the next free time is after the 4pm meeting
    await card.locator("input[name=start]").fill("12:30");
    await card.locator("select[name=duration]").selectOption("60");
    await expect(banner.locator(".grow")).toHaveText("That time has already passed. Next free at 4:30 pm.");

    await card.getByRole("button", { name: "Use 4:30 pm" }).click();
    await expect(card.locator("input[name=start]")).toHaveValue("16:30");
    await expect(banner).toBeHidden();
    await expect(card.locator(".meetings li.clash")).toHaveCount(0);
    await expect(card.getByRole("button", { name: "Book room" })).toBeEnabled();
    await expect(card.locator(".footer .summary")).toHaveText("Sydney Room 1 · Today, Tue, 13 Oct · 4:30 – 5:30 pm");
    expect(mcp.callsTo("events_book")).toEqual([]);
  });

  test("starts another day's booking at 9am", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    await card.getByRole("button", { name: "Next day" }).click();
    await expect(card.locator(".day h2")).toHaveText("Tomorrow, Wed, 14 Oct");
    // nothing booked tomorrow, the form starts at 9am
    await expect(card.locator("input[name=start]")).toHaveValue("09:00");
    await expect(card.locator("#clash")).toBeHidden();
  });

  test("books the room", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "spaces_show", SHOW);
    await card.locator("input[name=title]").fill("Catch up");
    await card.locator("input[name=start]").fill("17:00");
    await card.locator("select[name=duration]").selectOption("60");
    await expect(card.locator(".footer .summary")).toHaveText("Sydney Room 1 · Today, Tue, 13 Oct · 5:00 – 6:00 pm");
    await card.getByRole("button", { name: "Book room" }).click();
    await expect(card.locator("#status")).toHaveText('Booked "Catch up" in Sydney Room 1, Today, Tue, 13 Oct · 5:00 – 6:00 pm.');
    await expect(card.locator("#status")).toHaveClass(/ok/);
    expect(mcp.callsTo("events_book")).toEqual([{ title: "Catch up", event_start: at("17:00"), event_end: at("18:00"), timezone: TIMEZONE, system_id: ROOMS[0].id }]);
    // the day is reloaded to show the new meeting
    expect(mcp.callsTo("spaces_show")).toEqual([SHOW, { id: ROOMS[0].id, period_start: at("00:00") }]);
    // and the model is told
    const told = await page.evaluate(() => JSON.stringify((window as any).cardPreviewer.log));
    expect(told).toContain("ui/update-model-context");
    await snapshot(page, "spaces-desktop-booked");
  });

  test("shows why a booking failed", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { events_book: () => failure(409, "the room declined") } });
    await card.getByRole("button", { name: "Book room" }).click();
    await expect(card.locator("#status")).toHaveText("The booking failed: the room declined");
    await expect(card.locator("#status")).toHaveClass(/error/);
    await expect(card.getByRole("button", { name: "Book room" })).toBeEnabled();
  });

  test("moves between days", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "spaces_show", SHOW);
    await card.getByRole("button", { name: "Next day" }).click();
    await expect(card.locator(".day h2")).toHaveText("Tomorrow, Wed, 14 Oct");
    expect(mcp.callsTo("spaces_show").at(-1)).toEqual({ id: ROOMS[0].id, period_start: at("00:00", 1) });
    await expect(card.locator(".meetings li")).toHaveText(["No meetings, it's free all day"]);
    await expect(card.locator(".timeline .seg")).toHaveCount(0);

    await card.getByRole("button", { name: "Previous day" }).click();
    await expect(card.locator(".day h2")).toHaveText("Today, Tue, 13 Oct");
    expect(mcp.callsTo("spaces_show").at(-1)).toEqual({ id: ROOMS[0].id, period_start: at("00:00") });

    await card.getByRole("button", { name: "Previous day" }).click();
    await expect(card.locator(".day h2")).toHaveText("Mon, 12 Oct");
    expect(mcp.callsTo("spaces_show").at(-1)).toEqual({ id: ROOMS[0].id, period_start: at("00:00", -1) });
    // the whole day has passed
    await expect(card.locator("#clash")).toContainText("That time has already passed.");
    await expect(card.getByRole("button", { name: "Book room" })).toBeDisabled();
    // the media isn't reloaded for another day
    expect(mcp.callsTo("spaces_map")).toHaveLength(1);
  });

  test("keeps the title when changing days", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW);
    await card.locator("input[name=title]").fill("Planning");
    await card.getByRole("button", { name: "Next day" }).click();
    await expect(card.locator(".day h2")).toHaveText("Tomorrow, Wed, 14 Oct");
    await expect(card.locator("input[name=title]")).toHaveValue("Planning");
  });

  test("explains a room without a calendar can't be booked", async ({ page }) => {
    const schedule = spaceSchedule(ROOMS[0].id);
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: () => ok({ ...schedule, space: { ...schedule.space, email: null }, events: null }) } });
    await expect(card.locator(".note")).toHaveText("This space has no calendar, so it can't be booked here.");
    await expect(card.locator("form#book")).toHaveCount(0);
    await expect(card.getByRole("button", { name: "Book room" })).toHaveCount(0);
  });

  test("shows the calendar error", async ({ page }) => {
    const schedule = spaceSchedule(ROOMS[0].id);
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: () => ok({ ...schedule, events: null, events_error: "Calendar access denied" }) } });
    await expect(card.locator("#day .status.error")).toHaveText("Calendar access denied");
    await expect(card.locator(".timeline .bar")).toHaveCount(0);
    await expect(card.locator(".day h2")).toHaveText("Today, Tue, 13 Oct");
    // the room's calendar still decides, so it can be booked
    await expect(card.getByRole("button", { name: "Book room" })).toBeEnabled();
  });

  test("falls back to a generic message when the calendar is unavailable", async ({ page }) => {
    const schedule = spaceSchedule(ROOMS[0].id);
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: () => ok({ ...schedule, events: null }) } });
    await expect(card.locator("#day .status.error")).toHaveText("The calendar is unavailable");
  });

  test("shows an error when the space can't be loaded", async ({ page }) => {
    const { card } = await renderCard(page, "spaces_show", SHOW, { tools: { spaces_show: () => failure(404, "not found") } });
    await expect(card.locator(".status.error")).toHaveText("Unable to load the space: not found");
  });

  test.describe("room listings", () => {
    for (const viewport of ["desktop", "mobile"] as const) {
      test(`lists the rooms from spaces_index on ${viewport} and opens one`, async ({ page }) => {
        const { card, mcp } = await renderCard(page, "spaces_index", {}, { viewport, theme: viewport === "mobile" ? "dark" : "light" });
        await expect(card.locator("h1")).toHaveText("4 rooms");
        const tiles = card.locator(".tiles .tile");
        await expect(tiles).toHaveCount(4);
        await expect(tiles.nth(0)).toHaveText(/Sydney Room 1\s*4 seats · Wireless presenter · Zoom Room/);
        await expect(tiles.nth(2)).toHaveText(/Sydney Room 3\s*10 seats · WebEx\s*Needs approval/);
        await expect(tiles.nth(3)).toHaveText(/Sydney Room 4\s*4 seats$/);
        await expect(card.locator(".tile .free")).toHaveCount(0);
        expect(await overflows(card)).toBe(false);
        await snapshot(page, `spaces-${viewport}-list`);

        await tiles.nth(1).click();
        await expect(card.locator("h1")).toHaveText("Sydney Room 2");
        expect(mcp.callsTo("spaces_show")).toEqual([{ id: ROOMS[1].id }]);
        await card.getByRole("button", { name: "All rooms" }).click();
        await expect(card.locator("h1")).toHaveText("4 rooms");
        await expect(tiles).toHaveCount(4);
      });
    }

    test("lists the free rooms from calendars_availability and opens one at the searched time", async ({ page }) => {
      const search = { period_start: at("17:00"), period_end: at("18:00") };
      const { card, mcp } = await renderCard(page, "calendars_availability", search);
      await expect(card.locator("h1")).toHaveText("3 rooms");
      await expect(card.locator(".head .subtitle")).toHaveText("Today, Tue, 13 Oct · 5:00 – 6:00 pm AEDT");
      await expect(card.locator(".tile .free")).toHaveText(["Free", "Free", "Free"]);
      await expect(card.locator("main > p.muted")).toHaveText(`Also free: ${PEOPLE.bob.email}`);
      await snapshot(page, "spaces-desktop-availability");

      await card.getByRole("button", { name: /Sydney Room 3/ }).click();
      await expect(card.locator("h1")).toHaveText("Sydney Room 3");
      expect(mcp.callsTo("spaces_show")).toEqual([{ id: ROOMS[2].id, period_start: at("17:00") }]);
      // the booking starts at the searched time, for the searched length
      await expect(card.locator("input[name=start]")).toHaveValue("17:00");
      await expect(card.locator("select[name=duration]")).toHaveValue("60");
      // the bar starts at the searched time, the calendar wasn't read before it
      await expect(card.locator(".timeline .ticks span")).toHaveText(["5 pm", "7 pm", "9 pm"]);
      await expect(card.getByRole("button", { name: "All rooms" })).toBeVisible();
      await snapshot(page, "spaces-desktop-from-list");

      await card.getByRole("button", { name: "All rooms" }).click();
      await expect(card.locator(".tile")).toHaveCount(3);
    });

    test("opens the only room found", async ({ page }) => {
      const { card, mcp } = await renderCard(page, "spaces_index", {}, { tools: { spaces_index: () => ok([ROOMS[1]]) } });
      await expect(card.locator("h1")).toHaveText("Sydney Room 2");
      expect(mcp.callsTo("spaces_show")).toEqual([{ id: ROOMS[1].id }]);
      await expect(card.getByRole("button", { name: "All rooms" })).toHaveCount(0);
    });

    test("opens the only free room at the searched time", async ({ page }) => {
      const search = { period_start: at("17:00"), period_end: at("17:30") };
      const { card, mcp } = await renderCard(page, "calendars_availability", search, {
        tools: { calendars_availability: () => ok([{ id: ROOMS[0].email, system: ROOMS[0] }, { id: PEOPLE.bob.email }]) },
      });
      await expect(card.locator("h1")).toHaveText("Sydney Room 1");
      expect(mcp.callsTo("spaces_show")).toEqual([{ id: ROOMS[0].id, period_start: at("17:00") }]);
      await expect(card.locator("input[name=start]")).toHaveValue("17:00");
      await expect(card.locator("select[name=duration]")).toHaveValue("30");
    });

    test("lists free people when no rooms were searched", async ({ page }) => {
      const { card } = await renderCard(page, "calendars_availability", { period_start: at("17:00"), period_end: at("18:00") }, {
        tools: { calendars_availability: () => ok([{ id: PEOPLE.bob.email }, { id: PEOPLE.priya.email }]) },
      });
      await expect(card.locator(".empty")).toHaveText(`Free: ${PEOPLE.bob.email}, ${PEOPLE.priya.email}`);
    });

    test("says when no rooms were found", async ({ page }) => {
      const { card } = await renderCard(page, "spaces_index", {}, { tools: { spaces_index: () => ok([]) } });
      await expect(card.locator(".empty")).toHaveText("No rooms found");
    });

    test("goes back to the list when a room can't be loaded", async ({ page }) => {
      const { card } = await renderCard(page, "spaces_index", {}, { tools: { spaces_show: () => failure(500, "calendar down") } });
      await card.getByRole("button", { name: /Sydney Room 2/ }).click();
      await expect(card.locator(".status.error")).toHaveText("Unable to load the space: calendar down");
      await card.getByRole("button", { name: "All rooms" }).click();
      await expect(card.locator(".tile")).toHaveCount(4);
    });
  });
});
