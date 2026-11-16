import { LEVEL_MAP, mapPin, photo } from "./images";
import { accepted, created, failure, image, ok, type ToolHandler } from "./fake-mcp";

// A small PlaceOS Sydney office: one building, two levels, four rooms, desks and people.
// Times are on Tuesday 13 October 2026 in Sydney (AEDT, UTC+11), the tests fix the clock
// at 3:50pm that day.

export const TIMEZONE = "Australia/Sydney";
export const NOW = new Date("2026-10-13T15:50:00+11:00");

// the epoch of a time on the test day, or a day offset from it
export const at = (time: string, days = 0) => Math.floor(new Date(`2026-10-${13 + days}T${time}:00+11:00`).getTime() / 1000);

export const ME = { id: "user-me", email: "steve@acme.com", name: "Steve Takach", department: "Engineering" };

export const PEOPLE = {
  johanna: { id: "user-jl", email: "johanna@acme.com", name: "Johanna Lorenz", title: "Senior Engineer", department: "Engineering", office_location: "Office 23/2102", phone: "+61 2 9000 1234" },
  bob: { id: "user-bj", email: "bob@acme.com", name: "Bob Jones", title: "Account Manager", department: "Sales" },
  priya: { id: "user-pn", email: "priya@acme.com", name: "Priya Natarajan", title: "Designer", department: "Product" },
};

// who has a profile photo, the others show their initials
const PHOTOS: Record<string, Buffer> = {
  [PEOPLE.johanna.email]: photo(96, 96, [70, 90, 140], [150, 170, 220]),
  [PEOPLE.priya.email]: photo(96, 96, [140, 80, 90], [220, 160, 150]),
};

export const BUILDING = { id: "zone-bld", name: "PlaceOS Sydney Dev", display_name: "PlaceOS Sydney Dev", tags: ["building"], parent_id: "zone-org" };
export const LEVEL_1 = { id: "zone-l1", name: "Level 1", display_name: "Level 1", tags: ["level"], parent_id: BUILDING.id };
const ORG = { id: "zone-org", name: "Acme", display_name: "Acme", tags: ["org"], parent_id: null };

const room = (n: number, capacity: number, features: string[], images: number, extra: Record<string, unknown> = {}) => ({
  id: `sys-room-${n}`,
  name: `Sydney Room ${n}`,
  display_name: `Sydney Room ${n}`,
  description: null,
  email: `room${n}@acme.com`,
  capacity,
  features,
  images: Array.from({ length: images }, (_, i) => `https://acme.example/room-${n}-${i}.jpg`),
  map_id: `room-${n}`,
  zones: [ORG.id, BUILDING.id, LEVEL_1.id],
  timezone: TIMEZONE,
  approval: false,
  ...extra,
});

export const ROOMS = [
  room(1, 4, ["Wireless presenter", "Zoom Room"], 2),
  room(2, 8, ["HDMI", "Wireless presenter"], 1),
  room(3, 10, ["WebEx"], 0, { approval: true }),
  room(4, 4, [], 1),
];

// room photos: a wide and a portrait one, so letterboxing shows
const ROOM_PHOTOS = [photo(640, 360, [180, 140, 90], [240, 220, 190]), photo(300, 420, [80, 110, 130], [180, 210, 220])];

const attendee = (person: { email: string; name: string }, extra: Record<string, unknown> = {}) => ({
  name: person.name,
  email: person.email,
  response_status: "accepted",
  resource: false,
  ...extra,
});

export const EVENT = {
  id: "evt-1",
  title: "Design review",
  body: "Agenda: the new booking flow",
  event_start: at("16:00"),
  event_end: at("16:30"),
  timezone: TIMEZONE,
  host: ME.email,
  calendar: ME.email,
  creator: ME.email,
  status: "confirmed",
  private: false,
  all_day: false,
  recurring: false,
  attendees: [
    attendee(ME, { organizer: true }),
    attendee(PEOPLE.johanna),
    attendee(PEOPLE.bob, { response_status: "tentative" }),
    attendee(PEOPLE.priya, { response_status: "needsAction" }),
    { name: ROOMS[0].name, email: ROOMS[0].email, response_status: "accepted", resource: true },
  ],
  location: ROOMS[0].name,
  online_meeting_provider: "Microsoft Teams",
  online_meeting_url: "https://teams.microsoft.com/l/meetup-join/e2e",
  online_meeting_id: "435 269 110 526 74",
  system: ROOMS[0],
  system_id: ROOMS[0].id,
};

export const DESKS = Array.from({ length: 12 }, (_, n) => ({
  id: `desk-${n + 1}`,
  name: `Desk 1.${String(n + 1).padStart(2, "0")}`,
  map_id: `desk-${n + 1}`,
  zone_id: LEVEL_1.id,
  features: n % 3 === 0 ? ["Standing", "Dual monitors"] : n % 3 === 1 ? ["Dual monitors"] : [],
  accessible: n === 5,
  assigned_to: null,
}));

export const BOOKING = {
  id: 42,
  booking_type: "desk",
  booking_start: at("09:00"),
  booking_end: at("17:30"),
  timezone: TIMEZONE,
  asset_id: DESKS[2].id,
  asset_ids: [DESKS[2].id],
  asset_name: DESKS[2].name,
  title: DESKS[2].name,
  description: "",
  user_id: ME.id,
  user_email: ME.email,
  user_name: ME.name,
  booked_by_id: ME.id,
  booked_by_email: ME.email,
  booked_by_name: ME.name,
  zones: [ORG.id, BUILDING.id, LEVEL_1.id],
  approved: true,
  rejected: false,
  checked_in: false,
  deleted: false,
  all_day: false,
  instance: null,
  extension_data: { map_id: DESKS[2].map_id },
};

// the space's meetings, i.e. spaces_show
export function spaceSchedule(id: string, periodStart?: number) {
  const space = ROOMS.find((candidate) => candidate.id === id) ?? ROOMS[0];
  const start = periodStart ?? at("00:00");
  return {
    space,
    zones: [ORG, BUILDING, LEVEL_1],
    timezone: TIMEZONE,
    period_start: start,
    period_end: at("00:00", 1),
    events: [
      { id: "m1", title: "Standup", host: PEOPLE.bob.email, event_start: at("09:00"), event_end: at("09:30"), all_day: false, private: false },
      { id: "m2", title: null, host: null, event_start: at("13:00"), event_end: at("14:00"), all_day: false, private: true },
      { id: "m3", title: "Design review", host: ME.email, event_start: at("16:00"), event_end: at("16:30"), all_day: false, private: false },
    ].filter((event) => event.event_end > start),
    events_error: null,
  };
}

// as render_level_map sends them
const MAP_HEADERS = { "X-Map-View-Box": "0 0 1000 600", "X-Map-Level": LEVEL_1.id, "X-Map-Location": encodeURIComponent(`${LEVEL_1.name} · ${BUILDING.name}`) };

const roomById = (id: string) => ROOMS.find((candidate) => candidate.id === id);
const deskById = (id: string) => DESKS.find((candidate) => candidate.id === id);

// the tools every card can call, answered from the fixtures above
export function staffApi(): Record<string, ToolHandler> {
  return {
    users_current: () => ok(ME),

    events_show: () => ok(EVENT),
    events_book: (args) => created({
      ...EVENT,
      id: "evt-new",
      title: args.title,
      event_start: args.event_start,
      event_end: args.event_end,
      attendees: [attendee(ME, { organizer: true }), ...(args.attendees ?? []).map((email: string) => ({ name: email, email, response_status: "needsAction", resource: false }))],
      system: args.system_id ? roomById(args.system_id) : null,
      system_id: args.system_id ?? null,
    }),
    events_edit: (args) => ok({ ...EVENT, ...(args.title ? { title: args.title } : {}), ...(args.event_start ? { event_start: args.event_start, event_end: args.event_end } : {}) }),
    events_destroy: () => accepted(),

    bookings_show: () => ok(BOOKING),
    bookings_book: (args) => created({ ...BOOKING, id: 43, asset_id: args.asset_id, asset_ids: [args.asset_id], asset_name: deskById(args.asset_id)?.name, title: args.title ?? deskById(args.asset_id)?.name, booking_start: args.booking_start ?? BOOKING.booking_start, booking_end: args.booking_end ?? BOOKING.booking_end }),
    bookings_edit: (args) => ok({ ...BOOKING, ...args }),
    bookings_destroy: () => accepted(),

    staff_show: () => ok(PEOPLE.johanna),
    staff_index: () => ok([PEOPLE.johanna, PEOPLE.bob, PEOPLE.priya]),
    staff_photo: (args) => {
      const found = PHOTOS[String(args.id).toLowerCase()];
      return found ? image("image/png", found) : failure(404, "no photo");
    },
    staff_free_busy: (args) => ok([
      { email: args.id, busy: [{ start: at("10:00"), end: at("11:00") }, { start: at("13:30"), end: at("14:00") }] },
      { email: ME.email, busy: [{ start: at("09:00"), end: at("09:30") }, { start: at("15:30"), end: at("16:30") }] },
    ]),
    spaces_free: (args) => ok({
      buildings: [BUILDING],
      zone_id: BUILDING.id,
      spaces: ROOMS.filter((candidate) => candidate.capacity >= Number(args.capacity ?? 1)).sort((a, b) => a.capacity - b.capacity),
    }),
    desks_nearby: (args) => args.email === PEOPLE.johanna.email
      ? ok({ origin: DESKS[0], seated: PEOPLE.johanna.email, level: LEVEL_1, timezone: TIMEZONE, period_start: at("09:00"), period_end: at("17:00"), desks: DESKS.slice(1, 5).map((desk, n) => ({ ...desk, distance: 150 * (n + 1) })) })
      : failure(404, "no desk booked"),

    spaces_show: (args) => ok(spaceSchedule(args.id, args.period_start ? Number(args.period_start) : undefined)),
    spaces_index: () => ok(ROOMS),
    calendars_availability: () => ok([...ROOMS.slice(0, 3).map((space) => ({ id: space.email, system: space })), { id: PEOPLE.bob.email }]),
    spaces_image: (args) => {
      const space = roomById(args.id);
      if (!space || Number(args.index) >= space.images.length) return failure(404, "no image");
      return image("image/png", ROOM_PHOTOS[Number(args.index) % ROOM_PHOTOS.length]);
    },
    spaces_map: (args) => {
      const space = roomById(args.id);
      return space ? image("image/svg+xml", LEVEL_MAP, { ...MAP_HEADERS, "X-Map-Pin": mapPin(space.map_id) }) : failure(404, "not on a map");
    },
    assets_map: (args) => image("image/svg+xml", LEVEL_MAP, { ...MAP_HEADERS, "X-Map-Pin": mapPin(String(args.id)) }),
  };
}
