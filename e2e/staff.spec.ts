import type { FrameLocator, Page } from "@playwright/test";
import { expect, overflows, previewerErrors, renderCard, snapshot, test, type RenderOptions } from "./support/card";
import { failure, ok } from "./support/fake-mcp";
import { BUILDING, DESKS, ME, PEOPLE, ROOMS, TIMEZONE, at } from "./support/fixtures";

const SHOW = { id: PEOPLE.johanna.email };
const OTHER_BUILDING = { id: "zone-bld-2", name: "PlaceOS Melbourne", display_name: "PlaceOS Melbourne", tags: ["building"], parent_id: "zone-org" };
const MELBOURNE_ROOM = { ...ROOMS[1], id: "sys-mel-1", name: "Melbourne Room 1", display_name: "Melbourne Room 1", capacity: 6, features: ["Whiteboard"] };

// busy periods for staff_free_busy: Johanna's and mine
const freeBusy = (theirs: [string, string][], mine: [string, string][] = []) => (args: Record<string, any>) => ok([
  { email: args.id, busy: theirs.map(([start, end]) => ({ start: at(start), end: at(end) })) },
  { email: ME.email, busy: mine.map(([start, end]) => ({ start: at(start), end: at(end) })) },
]);

// renders Johanna's card with the calendars loaded
async function showJohanna(page: Page, options: RenderOptions = {}) {
  const rendered = await renderCard(page, "staff_show", SHOW, options);
  await expect(rendered.card.locator("#timeline .bar:not(.loading)")).toBeVisible();
  return rendered;
}

// what the card asked the host to do: open links or tell the model
async function hostRequests(page: Page, method: string): Promise<any[]> {
  const log = await page.evaluate(() => (window as any).cardPreviewer.log);
  return log.filter((entry: { dir: string; summary: string }) => entry.dir === "card → host" && entry.summary === method).map((entry: { data: unknown }) => entry.data);
}

// Intl writes times with thin and narrow no-break spaces
const spaces = (text: string | null) => String(text).replace(/\s+/g, " ");

// what the card told the model
const toldModel = async (page: Page) => (await hostRequests(page, "ui/update-model-context")).map((data) => spaces(data.content[0].text));

// clicks the timeline at a time of the test day
async function clickTimeline(card: FrameLocator, time: string) {
  const bar = card.locator("#timeline .bar");
  const box = (await bar.boundingBox())!;
  const [hours, minutes] = time.split(":").map(Number);
  // a few minutes past the time, so it rounds down to it
  const fraction = (hours + (minutes + 5) / 60 - 7) / 12;
  await bar.click({ position: { x: box.width * fraction, y: box.height / 2 } });
}

test.describe("staff card", () => {
  for (const viewport of ["desktop", "tablet", "mobile"] as const) {
    for (const theme of ["light", "dark"] as const) {
      test(`renders on ${viewport} in ${theme}`, async ({ page }) => {
        const { card } = await showJohanna(page, { viewport, theme });
        await expect(card.locator("h1")).toHaveText("Johanna Lorenz");
        await expect(card.locator(".avatar.large img")).toBeVisible();
        await expect(card.locator(".banner.warn")).toBeVisible();
        await expect(card.locator("#desks .tile")).toHaveCount(4);
        expect(await overflows(card)).toBe(false);
        expect(await previewerErrors(page)).toEqual([]);
        await snapshot(page, `staff-${viewport}-${theme}`);

        // with a room
        await card.getByLabel("Add a room").check();
        await expect(card.locator("#rooms .tile")).toHaveCount(4);
        expect(await overflows(card)).toBe(false);
        await snapshot(page, `staff-${viewport}-${theme}-room`);
      });
    }

    test(`lists the people found on ${viewport}`, async ({ page }) => {
      const { card } = await renderCard(page, "staff_index", { q: "acme" }, { viewport });
      await expect(card.locator(".person-tile")).toHaveCount(3);
      await expect(card.locator(".person-tile .avatar img").first()).toBeVisible();
      expect(await overflows(card)).toBe(false);
      await snapshot(page, `staff-${viewport}-people`);
    });
  }

  test("shows the person's title, office, photo and contact buttons", async ({ page }) => {
    const { card } = await showJohanna(page);
    await expect(card.locator(".head .subtitle")).toHaveText("Senior Engineer · Office 23/2102");
    await expect(card.locator(".avatar.large img")).toBeVisible();
    await expect(card.locator(".head h2, .head").getByRole("button")).toHaveText(["Email", "Call"]);
    await expect(card.getByRole("button", { name: "Email" }).locator("svg")).toHaveCount(1);
    await expect(card.locator("h2").first()).toHaveText("Book a meeting with Johanna");
  });

  test("puts the contact buttons beside the name on desktop and under it on mobile", async ({ page }) => {
    const { card } = await showJohanna(page);
    const name = (await card.locator("h1").boundingBox())!;
    const email = (await card.getByRole("button", { name: "Email" }).boundingBox())!;
    expect(email.x).toBeGreaterThan(name.x + name.width);
    expect(email.y).toBeLessThan(name.y + name.height);

    const mobile = await showJohanna(page, { viewport: "mobile" });
    const mobileName = (await mobile.card.locator("h1").boundingBox())!;
    const mobileEmail = (await mobile.card.getByRole("button", { name: "Email" }).boundingBox())!;
    expect(mobileEmail.y).toBeGreaterThan(mobileName.y + mobileName.height);
    expect(mobileEmail.height).toBeGreaterThanOrEqual(44);
  });

  test("emails and calls the person", async ({ page }) => {
    const { card } = await showJohanna(page);
    // the previewer opens mailto: links and refuses tel: ones, the card then opens it itself
    await card.getByRole("button", { name: "Email" }).click();
    await card.getByRole("button", { name: "Call" }).click();
    await expect.poll(() => hostRequests(page, "ui/open-link")).toEqual([{ url: `mailto:${PEOPLE.johanna.email}` }, { url: "tel:+61290001234" }]);
  });

  test("shows initials without a photo, and no call button without a phone", async ({ page }) => {
    const { card } = await renderCard(page, "staff_show", { id: PEOPLE.bob.email }, { tools: { staff_show: () => ok(PEOPLE.bob) } });
    await expect(card.locator("h1")).toHaveText("Bob Jones");
    await expect(card.locator(".avatar.large")).toHaveText("BJ");
    await expect(card.locator(".avatar.large img")).toHaveCount(0);
    await expect(card.locator(".head .subtitle")).toHaveText("Account Manager · Sales");
    await expect(card.getByRole("button", { name: "Email" })).toBeVisible();
    await expect(card.getByRole("button", { name: "Call" })).toHaveCount(0);
    // Bob hasn't booked a desk
    await expect(card.locator("#desks")).toBeEmpty();
  });

  test("shows both calendars on the timeline", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    expect(mcp.callsTo("staff_free_busy")).toEqual([{ id: PEOPLE.johanna.email, period_start: at("00:00"), period_end: at("00:00", 1) }]);
    const timeline = card.locator("#timeline");
    await expect(timeline.locator(".row strong")).toHaveText("Availability today");
    await expect(timeline.locator(".legend span")).toHaveText(["Both free", "Johanna busy", "You busy", "Both busy"]);
    await expect(timeline.locator(".seg.kind-them")).toHaveCount(2);
    await expect(timeline.locator(".seg.kind-me")).toHaveCount(2);
    await expect(timeline.locator(".seg.kind-both")).toHaveCount(0);
    expect(spaces(await timeline.locator(".seg.kind-them").first().getAttribute("title"))).toBe("Johanna is busy 10:00 – 11:00 am");
    await expect(timeline.locator(".seg.kind-past")).toHaveCount(1);
    await expect(timeline.locator(".ticks span").first()).toHaveText("7 am");

    // the selected meeting, 4:00 to 4:30 of the 7am to 7pm bar
    const bar = (await timeline.locator(".bar").boundingBox())!;
    const selected = (await timeline.locator(".selected").boundingBox())!;
    expect(Math.abs(selected.x - (bar.x + bar.width * (9 / 12)))).toBeLessThan(3);
    expect(Math.abs(selected.width - bar.width / 24)).toBeLessThan(3);
  });

  test("shows overlapping busy times as both busy", async ({ page }) => {
    const { card } = await showJohanna(page, { tools: { staff_free_busy: freeBusy([["16:00", "17:00"]], [["16:30", "17:30"]]) } });
    await expect(card.locator("#timeline .seg.kind-them")).toHaveCount(1);
    await expect(card.locator("#timeline .seg.kind-both")).toHaveCount(1);
    await expect(card.locator("#timeline .seg.kind-me")).toHaveCount(1);
    await expect(card.locator(".banner.warn")).toContainText("Johanna is busy 4:00 – 5:00 pm. Next time you're both free is 5:30 pm.");
  });

  test("shows the loading state while calendars are checked", async ({ page }) => {
    let release = () => {};
    const waiting = new Promise<void>((resolve) => { release = resolve; });
    const { card } = await renderCard(page, "staff_show", SHOW, { tools: { staff_free_busy: async (args) => { await waiting; return freeBusy([["10:00", "11:00"]])(args); } } });
    await expect(card.locator("#timeline .bar.loading")).toBeVisible();
    await expect(card.locator("#availability")).toContainText("Checking calendars…");
    release();
    await expect(card.locator("#timeline .bar:not(.loading)")).toBeVisible();
    await expect(card.locator("#timeline .seg.kind-them")).toHaveCount(1);
  });

  test("sets the start from a click on the timeline", async ({ page }) => {
    const { card } = await showJohanna(page);
    await clickTimeline(card, "17:00");
    await expect(card.locator("input[name=start]")).toHaveValue("17:00");
    await expect(card.locator(".banner.warn")).toHaveCount(0);
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Today, Tue, 13 Oct · 5:00 – 5:30 pm");

    // the past isn't offered
    await clickTimeline(card, "10:00");
    await expect(card.locator("input[name=start]")).toHaveValue("16:00");
  });

  test("warns when I'm busy and uses the next time we're both free", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    const banner = card.locator(".banner.warn");
    await expect(banner).toContainText("You're busy 3:30 – 4:30 pm. Next time you're both free is 4:30 pm.");
    const submit = card.locator(".footer button[type=submit]");
    await expect(submit).toHaveText("Book anyway");
    await expect(submit).toHaveClass(/caution/);

    await banner.getByRole("button", { name: "Use 4:30 pm" }).click();
    await expect(card.locator("input[name=start]")).toHaveValue("16:30");
    await expect(banner).toHaveCount(0);
    await expect(submit).toHaveText("Book meeting");
    await expect(submit).not.toHaveClass(/caution/);
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Today, Tue, 13 Oct · 4:30 – 5:00 pm");
    // the calendars aren't asked again for the same day
    expect(mcp.callsTo("staff_free_busy")).toHaveLength(1);
  });

  test("names who's busy and finds a slot long enough for the meeting", async ({ page }) => {
    const { card } = await showJohanna(page, { tools: { staff_free_busy: freeBusy([["16:00", "17:00"], ["17:30", "18:00"]], [["16:00", "16:45"]]) } });
    const banner = card.locator(".banner.warn");
    await expect(banner).toContainText("You're both busy 4:00 – 5:00 pm. Next time you're both free is 5:00 pm.");

    // an hour doesn't fit between 5:00 and 5:30
    await card.locator("select[name=duration]").selectOption("60");
    await expect(banner).toContainText("Next time you're both free is 6:00 pm.");
    await banner.getByRole("button", { name: "Use 6:00 pm" }).click();
    await expect(card.locator("input[name=start]")).toHaveValue("18:00");
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Today, Tue, 13 Oct · 6:00 – 7:00 pm");
  });

  test("says when there's no time we're both free", async ({ page }) => {
    const { card } = await showJohanna(page, { tools: { staff_free_busy: freeBusy([["15:00", "19:00"]]) } });
    const banner = card.locator(".banner.warn");
    await expect(banner).toHaveText("Johanna is busy 3:00 – 7:00 pm. There's no later time you're both free today.");
    await expect(banner.getByRole("button")).toHaveCount(0);
  });

  test("checks the calendars of another day", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await card.locator("input[name=date]").fill("2026-10-15");
    await expect(card.locator("#timeline .row strong")).toHaveText("Availability Thu, 15 Oct");
    await expect.poll(() => mcp.callsTo("staff_free_busy").at(-1)).toEqual({ id: PEOPLE.johanna.email, period_start: at("00:00", 2), period_end: at("00:00", 3) });
    // the fixture's busy times are on the 13th
    await expect(card.locator("#timeline .seg")).toHaveCount(0);
    await expect(card.locator(".banner.warn")).toHaveCount(0);
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Thu, 15 Oct · 4:00 – 4:30 pm");
    await card.locator("input[name=date]").fill("2026-10-14");
    await expect(card.locator("#timeline .row strong")).toHaveText("Availability tomorrow");
  });

  test("shows an error when the calendars can't be read", async ({ page }) => {
    const { card } = await renderCard(page, "staff_show", SHOW, { tools: { staff_free_busy: () => failure(503, "calendar unavailable") } });
    await expect(card.locator("#availability .status.error")).toHaveText("Unable to check calendars: calendar unavailable");
    await expect(card.locator(".footer button[type=submit]")).toHaveText("Book meeting");
  });

  test("books a meeting anyway when I'm busy", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await card.locator("input[name=title]").fill("Roadmap chat");
    await card.getByRole("button", { name: "Book anyway" }).click();
    await expect(card.locator("#status")).toHaveText('Booked "Roadmap chat" with Johanna Lorenz, Today, Tue, 13 Oct · 4:00 – 4:30 pm.');
    await expect(card.locator("#status")).toHaveClass(/ok/);
    expect(mcp.callsTo("events_book")).toEqual([{ title: "Roadmap chat", event_start: at("16:00"), event_end: at("16:30"), attendees: [PEOPLE.johanna.email], timezone: TIMEZONE }]);
    await expect.poll(() => toldModel(page)).toEqual(['Booked "Roadmap chat" with Johanna Lorenz, Today, Tue, 13 Oct · 4:00 – 4:30 pm.']);
    // the calendars are read again
    await expect.poll(() => mcp.callsTo("staff_free_busy").length).toBe(2);
  });

  test("books a meeting when we're both free", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await card.locator("input[name=start]").fill("17:00");
    await card.locator("select[name=duration]").selectOption("45");
    await card.getByRole("button", { name: "Book meeting" }).click();
    await expect(card.locator("#status")).toContainText("Booked");
    expect(mcp.callsTo("events_book")).toEqual([{ title: "Meeting with Johanna", event_start: at("17:00"), event_end: at("17:45"), attendees: [PEOPLE.johanna.email], timezone: TIMEZONE }]);
  });

  test("shows why a meeting couldn't be booked", async ({ page }) => {
    const { card } = await showJohanna(page, { tools: { events_book: () => failure(409, "calendar conflict") } });
    await card.getByRole("button", { name: "Book anyway" }).click();
    await expect(card.locator("#status.error")).toHaveText("The meeting couldn't be booked: calendar conflict");
    await expect(card.getByRole("button", { name: "Book anyway" })).toBeEnabled();
  });

  test("doesn't book a time that's passed", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await card.locator("input[name=start]").fill("09:00");
    await card.locator(".footer button[type=submit]").click();
    await expect(card.locator("#status.error")).toHaveText("That time has already passed");
    expect(mcp.callsTo("events_book")).toEqual([]);
  });

  test("adds a free room, the smallest first", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await expect(card.locator("#rooms")).toBeEmpty();
    expect(mcp.callsTo("spaces_free")).toEqual([]);

    await card.getByLabel("Add a room").check();
    const tiles = card.locator("#rooms .tile");
    await expect(tiles).toHaveCount(4);
    expect(mcp.callsTo("spaces_free")).toEqual([{ period_start: at("16:00"), period_end: at("16:30"), capacity: 2 }]);
    await expect(card.locator(".rooms-head")).toHaveText("Room · PlaceOS Sydney Dev, free at this time");
    await expect(card.getByRole("button", { name: "Change building" })).toHaveCount(0);
    await expect(tiles.locator(".title")).toHaveText(["Sydney Room 1", "Sydney Room 4", "Sydney Room 2", "Sydney Room 3"]);
    await expect(tiles.nth(0)).toHaveAttribute("aria-pressed", "true");
    await expect(tiles.nth(0).locator(".sub")).toHaveText("4 seats · Wireless presenter · Zoom Room");
    await expect(tiles.nth(0).locator(".free")).toHaveText("Free");
    await expect(tiles.nth(3).locator(".approval")).toHaveText("Needs approval");
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Sydney Room 1 · Today, Tue, 13 Oct · 4:00 – 4:30 pm");

    await tiles.nth(2).click();
    await expect(tiles.nth(2)).toHaveAttribute("aria-pressed", "true");
    await expect(tiles.nth(0)).toHaveAttribute("aria-pressed", "false");
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Sydney Room 2 · Today, Tue, 13 Oct · 4:00 – 4:30 pm");

    await card.getByRole("button", { name: "Book anyway" }).click();
    await expect(card.locator("#status")).toHaveText('Booked "Meeting with Johanna" with Johanna Lorenz in Sydney Room 2, Today, Tue, 13 Oct · 4:00 – 4:30 pm.');
    expect(mcp.callsTo("events_book")).toEqual([{ title: "Meeting with Johanna", event_start: at("16:00"), event_end: at("16:30"), attendees: [PEOPLE.johanna.email], timezone: TIMEZONE, system_id: ROOMS[1].id }]);
    // the free rooms are looked up again
    await expect.poll(() => mcp.callsTo("spaces_free").length).toBe(2);
  });

  test("looks for rooms again when the time changes, keeping the chosen room", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    await card.getByLabel("Add a room").check();
    await card.locator("#rooms .tile").nth(1).click();
    await card.getByRole("button", { name: "Use 4:30 pm" }).click();
    await expect.poll(() => mcp.callsTo("spaces_free").at(-1)).toEqual({ period_start: at("16:30"), period_end: at("17:00"), capacity: 2, zone_id: BUILDING.id });
    await expect(card.locator("#rooms .tile").nth(1)).toHaveAttribute("aria-pressed", "true");
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Sydney Room 4 · Today, Tue, 13 Oct · 4:30 – 5:00 pm");

    await card.getByLabel("Add a room").uncheck();
    await expect(card.locator("#rooms")).toBeEmpty();
    await expect(card.locator(".footer .summary")).toHaveText("Johanna Lorenz · Today, Tue, 13 Oct · 4:30 – 5:00 pm");
    await card.getByRole("button", { name: "Book meeting" }).click();
    await expect(card.locator("#status")).toContainText("Booked");
    expect(mcp.callsTo("events_book")[0].system_id).toBeUndefined();
  });

  test("says when no rooms are free", async ({ page }) => {
    const { card, mcp } = await showJohanna(page, { tools: { spaces_free: () => ok({ buildings: [BUILDING], zone_id: BUILDING.id, spaces: [] }) } });
    await card.getByLabel("Add a room").check();
    await expect(card.locator("#rooms")).toContainText("No rooms are free then, try another time.");
    await card.getByRole("button", { name: "Book anyway" }).click();
    await expect(card.locator("#status.error")).toHaveText("Pick a free room, or untick Add a room");
    expect(mcp.callsTo("events_book")).toEqual([]);
  });

  // the previewer's sandbox has no localStorage, so remembering the building isn't tested here
  test("changes the building", async ({ page }) => {
    const spaces_free = (args: Record<string, any>) => {
      const zone = args.zone_id ?? BUILDING.id;
      return ok({ buildings: [BUILDING, OTHER_BUILDING], zone_id: zone, spaces: zone === OTHER_BUILDING.id ? [MELBOURNE_ROOM] : ROOMS.slice(0, 2) });
    };
    const { card, mcp } = await showJohanna(page, { tools: { spaces_free } });
    await card.getByLabel("Add a room").check();
    await expect(card.locator("#rooms .tile")).toHaveCount(2);
    await expect(card.locator("select[name=building]")).toHaveCount(0);

    await card.getByRole("button", { name: "Change building" }).click();
    await card.locator("select[name=building]").selectOption(OTHER_BUILDING.id);
    await expect(card.locator("#rooms .tile .title")).toHaveText(["Melbourne Room 1"]);
    await expect(card.locator(".rooms-head")).toContainText("PlaceOS Melbourne, free at this time");
    await expect(card.locator("select[name=building]")).toHaveCount(0);
    expect(mcp.callsTo("spaces_free").at(-1)).toEqual({ period_start: at("16:00"), period_end: at("16:30"), capacity: 2, zone_id: OTHER_BUILDING.id });
    await expect(card.locator(".footer .summary")).toContainText("Melbourne Room 1");
    await snapshot(page, "staff-desktop-light-building");

    await card.getByRole("button", { name: "Book anyway" }).click();
    await expect(card.locator("#status")).toContainText("in Melbourne Room 1");
    expect(mcp.callsTo("events_book")[0].system_id).toBe(MELBOURNE_ROOM.id);
  });

  test("asks for a building when spaces_free doesn't pick one", async ({ page }) => {
    const spaces_free = (args: Record<string, any>) => ok({ buildings: [BUILDING, OTHER_BUILDING], zone_id: args.zone_id ?? null, spaces: args.zone_id ? [MELBOURNE_ROOM] : [] });
    const { card } = await showJohanna(page, { tools: { spaces_free } });
    await card.getByLabel("Add a room").check();
    await expect(card.locator("select[name=building]")).toHaveValue("");
    await card.locator("select[name=building]").selectOption(OTHER_BUILDING.id);
    await expect(card.locator("#rooms .tile .title")).toHaveText(["Melbourne Room 1"]);
  });

  test("books a desk near the person", async ({ page }) => {
    const { card, mcp } = await showJohanna(page);
    const desks = card.locator("#desks");
    await expect(desks.locator("h2")).toHaveText("Sit near Johanna");
    await expect(desks.locator("p.muted")).toHaveText("Johanna is at Desk 1.01, Level 1, Today, Tue, 13 Oct · 9:00 am – 5:00 pm");
    await expect(desks.locator(".tile .title")).toHaveText(["Desk 1.02", "Desk 1.03", "Desk 1.04", "Desk 1.05"]);
    await expect(desks.locator(".tile .sub").first()).toHaveText("Closest · Dual monitors");
    expect(mcp.callsTo("desks_nearby")).toEqual([{ email: PEOPLE.johanna.email, limit: 5 }]);

    await desks.getByRole("button", { name: "Book Desk 1.03" }).click();
    const booked = "Booked Desk 1.03 near Johanna Lorenz, Today, Tue, 13 Oct · 9:00 am – 5:00 pm.";
    await expect(card.locator("#desk-status")).toHaveText(booked);
    await expect(desks.locator(".tile")).toHaveCount(0);
    expect(mcp.callsTo("bookings_book")).toEqual([{ asset_id: DESKS[2].id, booking_type: "desk", booking_start: at("09:00"), booking_end: at("17:00"), title: "Desk near Johanna", timezone: TIMEZONE }]);
    await expect.poll(() => toldModel(page)).toEqual([booked]);
  });

  test("shows why a desk couldn't be booked", async ({ page }) => {
    const { card } = await showJohanna(page, { tools: { bookings_book: () => failure(409, "already booked") } });
    await card.getByRole("button", { name: "Book Desk 1.02" }).click();
    await expect(card.locator("#desk-status.error")).toHaveText("The desk couldn't be booked: already booked");
    await expect(card.getByRole("button", { name: "Book Desk 1.02" })).toBeEnabled();
  });

  test("doesn't offer desks near myself", async ({ page }) => {
    const { card, mcp } = await showJohanna(page, { tools: { staff_show: () => ok(ME) } });
    await expect(card.locator("h1")).toHaveText(ME.name);
    await expect(card.locator(".head .subtitle")).toHaveText("Engineering");
    await page.waitForTimeout(300);
    expect(mcp.callsTo("desks_nearby")).toEqual([]);
    await expect(card.locator("#desks")).toBeEmpty();
  });

  test("opens a person from the people found and goes back", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "staff_index", { q: "acme" });
    await expect(card.locator("h1")).toHaveText("3 people found");
    const tiles = card.locator(".person-tile");
    await expect(tiles.locator(".title")).toHaveText(["Johanna Lorenz", "Bob Jones", "Priya Natarajan"]);
    await expect(tiles.nth(0).locator(".sub")).toHaveText("Senior Engineer · Engineering");
    await expect(tiles.nth(0).locator(".avatar img")).toBeVisible();
    await expect(tiles.nth(1).locator(".avatar")).toHaveText("BJ");

    await tiles.nth(1).click();
    await expect(card.locator("h1")).toHaveText("Bob Jones");
    await expect(card.locator("h2").first()).toHaveText("Book a meeting with Bob");
    await expect.poll(() => mcp.callsTo("staff_free_busy").at(-1)?.id).toBe(PEOPLE.bob.email);

    await card.getByRole("button", { name: "All results" }).click();
    await expect(card.locator("h1")).toHaveText("3 people found");
    await card.locator(".person-tile").nth(0).click();
    await expect(card.locator("h1")).toHaveText("Johanna Lorenz");
    await expect(card.locator("#desks .tile")).toHaveCount(4);
  });

  test("shows the only person found", async ({ page }) => {
    const { card } = await renderCard(page, "staff_index", { q: "johanna" }, { tools: { staff_index: () => ok([PEOPLE.johanna]) } });
    await expect(card.locator("h1")).toHaveText("Johanna Lorenz");
    await expect(card.getByRole("button", { name: "All results" })).toHaveCount(0);
  });

  test("says when no one was found", async ({ page }) => {
    const { card } = await renderCard(page, "staff_index", { q: "nobody" }, { tools: { staff_index: () => ok([]) } });
    await expect(card.locator("#app")).toHaveText("No one found");
  });

  test("shows an error when the person can't be loaded", async ({ page }) => {
    const { card } = await renderCard(page, "staff_show", SHOW, { tools: { staff_show: () => failure(404, "not found") } });
    await expect(card.locator(".status.error")).toHaveText("Unable to load this person: not found");
  });
});
