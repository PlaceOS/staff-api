import { expect, overflows, previewerErrors, renderCard, snapshot, test } from "./support/card";
import { failure, ok } from "./support/fake-mcp";
import { BOOKING, DESKS, ME, PEOPLE, at } from "./support/fixtures";

const SHOW = { id: BOOKING.id };
// the booking as bookings_show returns it, with changes
const showing = (changes: Record<string, unknown>) => ({ bookings_show: () => ok({ ...BOOKING, ...changes }) });

test.describe("booking card", () => {
  for (const viewport of ["desktop", "tablet", "mobile"] as const) {
    for (const theme of ["light", "dark"] as const) {
      test(`renders on ${viewport} in ${theme}`, async ({ page }) => {
        const { card } = await renderCard(page, "bookings_show", SHOW, { viewport, theme });
        await expect(card.locator("h1")).toHaveText("Desk 1.03");
        // the map is the only media, so it shows on every width
        await expect(card.locator(".map .canvas img")).toBeVisible();
        await expect(card.locator(".details")).toContainText("Level 1 · PlaceOS Sydney Dev");
        await expect(card.getByRole("button", { name: "Edit" })).toBeVisible();
        expect(await overflows(card)).toBe(false);
        expect(await previewerErrors(page)).toEqual([]);
        await snapshot(page, `bookings-${viewport}-${theme}`);
      });
    }
  }

  test("shows when, the status and the type", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW);
    await expect(card.locator(".subtitle")).toHaveText("Today, Tue, 13 Oct · 9:00 am – 5:30 pm AEDT");
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Booked", "Approved", "Desk"]);
    await expect(card.locator(".chips .chip").first()).toHaveClass(/ok/);
    const details = card.locator(".details");
    await expect(details).toContainText("Today, Tue, 13 Oct · 9:00 am – 5:30 pm AEDT · 8h 30m");
    await expect(details.locator("dt")).toHaveText(["When", "Where", "Type", "Booked for"]);
    await expect(card.locator("text=Check-in")).toHaveCount(0);
  });

  const STATES: [string, Record<string, unknown>, string, RegExp][] = [
    ["not approved", { approved: false }, "Booked", /ok/],
    ["rejected", { approved: false, rejected: true, current_state: "rejected" }, "Rejected", /danger/],
    ["checked in", { checked_in: true, current_state: "checked_in" }, "Checked in", /ok/],
    ["cancelled", { deleted: true, current_state: "cancelled" }, "Cancelled", /danger/],
    ["checked out", { checked_in: false, current_state: "CheckedOut" }, "Checked out", /^chip$/],
  ];
  for (const [name, changes, label, kind] of STATES) {
    test(`shows a ${name} booking`, async ({ page }) => {
      const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing(changes) });
      const chip = card.locator(".chips[aria-label=Status] .chip").first();
      await expect(chip).toHaveText(label);
      await expect(chip).toHaveClass(kind);
      // only bookings that are still on can be changed
      const changeable = name === "not approved" || name === "checked in";
      await expect(card.getByRole("button", { name: "Cancel booking" })).toHaveCount(changeable ? 1 : 0);
    });
  }

  test("names other kinds of booking", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ booking_type: "parking", title: "Bay 12", asset_name: "Bay 12" }) });
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Booked", "Approved", "Parking"]);
    await expect(card.locator(".details")).toContainText("Parking");
    await card.getByRole("button", { name: "Cancel booking" }).click();
    await expect(card.locator(".footer")).toContainText("Cancel your parking booking?");
  });

  test("shows an all day booking", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ all_day: true, booking_start: at("00:00"), booking_end: at("00:00", 1) }) });
    await expect(card.locator(".subtitle")).toHaveText("Today, Tue, 13 Oct · all day");
    await expect(card.locator(".details .duration")).toHaveCount(0);
  });

  test("shows the asset on its level map, zoomed with the buttons", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    const map = card.locator(".map");
    await expect(map).toHaveClass(/solo/);
    await expect(map.locator(".pin")).toBeVisible();
    await expect(map.locator(".caption")).toHaveText("Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".carousel")).toHaveCount(0);
    await expect(card.locator(".map-toggle")).toHaveCount(0);
    expect(mcp.callsTo("assets_map")).toEqual([{ id: BOOKING.asset_id }]);
    // the only media, so it spans the card but stays short enough to read the details
    const [width, height, cardWidth] = await map.evaluate((node) => [node.clientWidth, node.clientHeight, node.ownerDocument.body.clientWidth]);
    expect(width).toBeGreaterThan(cardWidth - 50);
    expect(height).toBeLessThanOrEqual(320);

    await expect(map).toHaveAttribute("data-scale", "2.00");
    await card.getByRole("button", { name: "Zoom in" }).click();
    await expect(map).toHaveAttribute("data-scale", "3.00");
    await card.getByRole("button", { name: "Zoom out" }).click();
    await card.getByRole("button", { name: "Zoom out" }).click();
    await expect(map).toHaveAttribute("data-scale", "1.33");
    await card.getByRole("button", { name: "Recenter" }).click();
    await expect(map).toHaveAttribute("data-scale", "2.00");
  });

  test("shows the map compactly on mobile, without a toggle", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { viewport: "mobile" });
    const map = card.locator(".map");
    await expect(map.locator(".canvas img")).toBeVisible();
    await expect(card.locator(".map-toggle")).toHaveCount(0);
    expect(await map.evaluate((node) => node.clientHeight)).toBeLessThan(240);
    // 44px touch targets on mobile
    expect(await card.getByRole("button", { name: "Edit" }).evaluate((node) => node.getBoundingClientRect().height)).toBeGreaterThanOrEqual(44);
  });

  test("keeps the map across edits without loading it again", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    await expect(card.locator(".map .pin")).toBeVisible();
    await card.getByRole("button", { name: "Edit" }).click();
    await expect(card.locator(".map .pin")).toBeVisible();
    await card.getByRole("button", { name: "Back" }).click();
    await expect(card.locator(".details")).toContainText("Level 1 · PlaceOS Sydney Dev");
    expect(mcp.callsTo("assets_map")).toHaveLength(1);
  });

  test("names the asset only when the title doesn't, and never shows its id", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW);
    const where = card.locator(".details dd#where");
    await expect(where).toHaveText("Level 1 · PlaceOS Sydney Dev");
    await expect(where.locator(".where-name")).toHaveCount(0);
    await expect(where.locator("#where-location")).not.toHaveClass(/muted/);
    await expect(card.locator("body")).not.toContainText(BOOKING.asset_id);
  });

  test("names the asset when the booking has its own title", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ title: "Focus day" }) });
    await expect(card.locator("h1")).toHaveText("Focus day");
    await expect(card.locator(".details dd#where")).toHaveText("Desk 1.03 · Level 1 · PlaceOS Sydney Dev");
    await expect(card.locator(".details .where-name")).toHaveText("Desk 1.03");
    await expect(card.locator("#where-location")).toHaveClass(/muted/);
    await expect(card.locator("body")).not.toContainText(BOOKING.asset_id);
  });

  test("shows who it's for and who booked it, with their photos", async ({ page }) => {
    const booked = { user_id: PEOPLE.priya.id, user_email: PEOPLE.priya.email, user_name: PEOPLE.priya.name, booked_by_id: ME.id, booked_by_email: ME.email, booked_by_name: ME.name };
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing(booked) });
    const details = card.locator(".details");
    await expect(details.locator("dt")).toHaveText(["When", "Where", "Type", "Booked for", "Booked by"]);
    const forPerson = details.locator("dd").nth(3);
    await expect(forPerson).toContainText("Priya Natarajan");
    await expect(forPerson).toContainText(PEOPLE.priya.email);
    await expect(forPerson.locator(".avatar img")).toBeVisible();
    const byPerson = details.locator("dd").nth(4);
    await expect(byPerson).toContainText("Steve Takach");
    await expect(byPerson.locator(".avatar")).toHaveText("ST");
    // the one who booked it can change it
    await expect(card.getByRole("button", { name: "Edit" })).toBeVisible();
    await snapshot(page, "bookings-desktop-booked-for");
  });

  test("shows the notes", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ description: "Near the window\nBring a monitor cable" }) });
    const notes = card.locator(".details .notes");
    await expect(notes).toHaveText("Near the window\nBring a monitor cable");
    await expect(notes).toHaveCSS("white-space", "pre-wrap");
  });

  test("edits the date, times and notes, without a title", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    await card.getByRole("button", { name: "Edit" }).click();
    const form = card.locator("form#edit");
    await expect(form.locator("input[name=date]")).toBeFocused();
    await expect(form.locator("label")).toHaveText(["Date", "Start", "End", "Notes"]);
    await expect(form.locator("input[name=title]")).toHaveCount(0);
    await expect(form.locator("input[name=date]")).toHaveValue("2026-10-13");
    await expect(form.locator("input[name=start]")).toHaveValue("09:00");
    await expect(form.locator("input[name=end]")).toHaveValue("17:30");
    await snapshot(page, "bookings-desktop-edit");

    await form.locator("input[name=end]").fill("18:00");
    await form.locator("textarea[name=description]").fill("Near the window");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("Booking updated");
    expect(mcp.callsTo("bookings_edit")).toEqual([{ id: BOOKING.id, description: "Near the window", booking_end: at("18:00") }]);
    await expect(card.locator(".subtitle")).toHaveText("Today, Tue, 13 Oct · 9:00 am – 6:00 pm AEDT");
    await expect(card.locator(".details .notes")).toHaveText("Near the window");
    await expect(card.locator("form#edit")).toHaveCount(0);
  });

  test("moves the booking to another day", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW, { viewport: "mobile" });
    await card.getByRole("button", { name: "Edit" }).click();
    await card.locator("input[name=date]").fill("2026-10-14");
    await card.locator("input[name=start]").fill("08:30");
    expect(await overflows(card)).toBe(false);
    await snapshot(page, "bookings-mobile-edit");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("Booking updated");
    expect(mcp.callsTo("bookings_edit")).toEqual([{ id: BOOKING.id, booking_start: at("08:30", 1), booking_end: at("17:30", 1) }]);
    await expect(card.locator(".subtitle")).toHaveText("Tomorrow, Wed, 14 Oct · 8:30 am – 5:30 pm AEDT");
  });

  test("checks the edit before saving", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    await card.getByRole("button", { name: "Edit" }).click();
    await card.locator("input[name=end]").fill("08:00");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("The end must be after the start");
    await expect(card.locator("#status")).toHaveClass(/error/);

    await card.locator("input[name=end]").fill("17:30");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("Nothing changed");
    await expect(card.locator("form#edit")).toHaveCount(0);
    expect(mcp.callsTo("bookings_edit")).toEqual([]);
  });

  test("shows why an edit failed and keeps the form", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { bookings_edit: () => failure(409, "the desk is already booked") } });
    await card.getByRole("button", { name: "Edit" }).click();
    await card.locator("input[name=start]").fill("08:00");
    await card.getByRole("button", { name: "Save changes" }).click();
    await expect(card.locator("#status")).toHaveText("The booking couldn't be saved: the desk is already booked");
    await expect(card.getByRole("button", { name: "Save changes" })).toBeEnabled();
    await expect(card.locator("input[name=start]")).toHaveValue("08:00");
  });

  test("cancels the booking once confirmed", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    await card.getByRole("button", { name: "Cancel booking" }).click();
    await expect(card.locator(".footer")).toContainText("Cancel your desk booking?");
    await snapshot(page, "bookings-desktop-confirm-cancel");
    await card.getByRole("button", { name: "Keep it" }).click();
    expect(mcp.callsTo("bookings_destroy")).toEqual([]);

    // reloaded once cancelled
    mcp.use(showing({ deleted: true, current_state: "cancelled" }));
    await card.getByRole("button", { name: "Cancel booking" }).click();
    await card.getByRole("button", { name: "Yes, cancel it" }).click();
    await expect(card.locator("#status")).toHaveText("Booking cancelled");
    await expect(card.locator(".chips[aria-label=Status] .chip").first()).toHaveText("Cancelled");
    await expect(card.getByRole("button", { name: "Edit" })).toHaveCount(0);
    await expect(card.locator(".footer")).toHaveCount(0);
    expect(mcp.callsTo("bookings_destroy")).toEqual([{ id: BOOKING.id }]);
    expect(mcp.callsTo("bookings_show")).toEqual([SHOW, { id: BOOKING.id }]);
  });

  test("cancels one occurrence of a recurring booking", async ({ page }) => {
    const instance = at("09:00");
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ instance }) });
    await card.getByRole("button", { name: "Cancel booking" }).click();
    mcp.use(showing({ instance, deleted: true }));
    await card.getByRole("button", { name: "Yes, cancel it" }).click();
    await expect(card.locator("#status")).toHaveText("Booking cancelled");
    expect(mcp.callsTo("bookings_destroy")).toEqual([{ id: BOOKING.id, instance }]);
    expect(mcp.callsTo("bookings_show").at(-1)).toEqual({ id: BOOKING.id, instance });
  });

  test("shows the booking as cancelled when it can't be reloaded", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW);
    mcp.use({ bookings_show: () => failure(404, "not found") });
    await card.getByRole("button", { name: "Cancel booking" }).click();
    await card.getByRole("button", { name: "Yes, cancel it" }).click();
    await expect(card.locator("#status")).toHaveText("Booking cancelled");
    await expect(card.locator(".chips[aria-label=Status] .chip").first()).toHaveText("Cancelled");
  });

  test("shows why a cancel failed", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { bookings_destroy: () => failure(403, "not allowed") } });
    await card.getByRole("button", { name: "Cancel booking" }).click();
    await card.getByRole("button", { name: "Yes, cancel it" }).click();
    await expect(card.locator("#status")).toHaveText("The booking couldn't be cancelled: not allowed");
    await expect(card.locator(".chips[aria-label=Status] .chip").first()).toHaveText("Booked");
    await expect(card.getByRole("button", { name: "Cancel booking" })).toBeVisible();
  });

  test("is read only for someone else's booking", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { users_current: () => ok(PEOPLE.bob) } });
    await expect(card.locator("h1")).toHaveText("Desk 1.03");
    await expect(card.locator(".details")).toContainText("Steve Takach");
    await expect(card.getByRole("button", { name: "Edit" })).toHaveCount(0);
    await expect(card.getByRole("button", { name: "Cancel booking" })).toHaveCount(0);
    await expect(card.locator(".footer")).toHaveCount(0);
  });

  test("lets the owner matched by email change it", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { users_current: () => ok({ email: ME.email.toUpperCase() }) } });
    await expect(card.getByRole("button", { name: "Edit" })).toBeVisible();
  });

  test("is read only once the booking has ended", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ booking_start: at("09:00", -1), booking_end: at("17:30", -1) }) });
    await expect(card.locator(".subtitle")).toContainText("Mon, 12 Oct");
    await expect(card.locator(".footer")).toHaveCount(0);
  });

  test("renders the booking made by bookings_book", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_book", { asset_id: DESKS[3].id });
    await expect(card.locator("h1")).toHaveText("Desk 1.04");
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Booked", "Approved", "Desk"]);
    await expect(card.locator(".map .caption")).toHaveText("Level 1 · PlaceOS Sydney Dev");
    expect(mcp.callsTo("bookings_book")).toEqual([{ asset_id: DESKS[3].id }]);
    expect(mcp.callsTo("assets_map")).toEqual([{ id: DESKS[3].id }]);
  });

  test("leaves out the map when the asset isn't on one", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW, { tools: { assets_map: () => failure(404, "not on a map") } });
    await expect(card.locator("h1")).toHaveText("Desk 1.03");
    await expect.poll(() => mcp.callsTo("assets_map").length).toBe(1);
    await expect(card.locator(".media")).toHaveCount(0);
    await expect(card.locator(".details dt#where-term")).toBeHidden();
    await expect(card.getByRole("button", { name: "Edit" })).toBeVisible();
    expect(await previewerErrors(page)).toEqual([]);
    await snapshot(page, "bookings-desktop-no-map");
  });

  test("shows the asset's name without a map", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { ...showing({ title: "Focus day" }), assets_map: () => failure(404, "not on a map") } });
    await expect(card.locator(".media")).toHaveCount(0);
    await expect(card.locator(".details dd#where")).toHaveText("Desk 1.03");
  });

  test("doesn't look for a visitor on a map", async ({ page }) => {
    const { card, mcp } = await renderCard(page, "bookings_show", SHOW, { tools: showing({ booking_type: "visitor", title: "Visitor: Jane", asset_id: "jane@example.com", asset_name: "jane@example.com" }) });
    await expect(card.locator(".chips[aria-label=Status] .chip")).toHaveText(["Booked", "Approved", "Visitor"]);
    await expect(card.locator(".media")).toHaveCount(0);
    expect(mcp.callsTo("assets_map")).toEqual([]);
  });

  test("shows an error when the booking can't be loaded", async ({ page }) => {
    const { card } = await renderCard(page, "bookings_show", SHOW, { tools: { bookings_show: () => failure(404, "not found") } });
    await expect(card.locator(".status.error")).toHaveText("Unable to load the booking: not found");
  });
});
