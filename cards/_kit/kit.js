  // Shared by every card, copied in by `npm run cards:kit` (scripts/sync-card-kit.mjs).

  // ---- host bridge: JSON-RPC over postMessage (MCP Apps) ----
  const app = document.getElementById("app");
  let nextId = 1;
  const pending = new Map();
  const hooks = { input: () => {}, result: () => {} };

  function send(message) { window.parent.postMessage(message, "*"); }
  function request(method, params) {
    const id = nextId++;
    send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }
  function notify(method, params) { send({ jsonrpc: "2.0", method, params }); }

  window.addEventListener("message", (event) => {
    const msg = event.data;
    if (!msg || msg.jsonrpc !== "2.0") return;
    if (msg.id !== undefined && pending.has(msg.id) && !msg.method) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(msg.error.message || "request failed")) : resolve(msg.result);
      return;
    }
    switch (msg.method) {
      case "ui/notifications/tool-input": hooks.input((msg.params && msg.params.arguments) || {}); break;
      case "ui/notifications/tool-result": hooks.result(msg.params); break;
      case "ui/notifications/host-context-changed": applyContext(msg.params); break;
      case "ui/resource-teardown": send({ jsonrpc: "2.0", id: msg.id, result: {} }); break;
      default:
        // answer unknown requests so the host isn't left waiting
        if (msg.id !== undefined && msg.method) send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "method not found" } });
    }
  });

  // the host's theme and, when it sends them, its colours and fonts
  function applyContext(context) {
    if (!context) return;
    if (context.theme) document.documentElement.dataset.theme = context.theme;
    const variables = context.styles && context.styles.variables;
    if (variables) for (const [name, value] of Object.entries(variables)) if (value) document.documentElement.style.setProperty(name, value);
  }

  // connects to the host, `onInput` gets the tool's arguments and `onResult` its result
  function start(name, { onInput, onResult }) {
    if (onInput) hooks.input = onInput;
    hooks.result = onResult;
    request("ui/initialize", {
      protocolVersion: "2026-01-26",
      appInfo: { name, version: "2.0.0" },
      appCapabilities: {},
    }).then((result) => {
      applyContext(result && result.hostContext);
      notify("ui/notifications/initialized", {});
    }).catch(() => notify("ui/notifications/initialized", {}));
  }

  // keep the host's frame the size of the content
  new ResizeObserver(() => {
    notify("ui/notifications/size-changed", { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight });
  }).observe(document.body);

  // a tool result's {status, headers, body} envelope
  function envelope(result) {
    const content = result && result.structuredContent;
    if (content && typeof content.status === "number") return content;
    const text = result && result.content && result.content.find((item) => item.type === "text");
    try { return text ? JSON.parse(text.text) : null; } catch { return null; }
  }

  function errorText(response, fallback) {
    const body = response && response.body;
    const detail = body && (typeof body === "string" ? body : body.message || body.error);
    return detail ? `${fallback}: ${detail}` : fallback;
  }

  // calls a tool, returning the response body or throwing the error
  async function callTool(name, args, failure) {
    const result = await request("tools/call", { name, arguments: args });
    const response = envelope(result);
    if ((result && result.isError) || !response || response.status >= 400) throw new Error(errorText(response, failure));
    return response.body;
  }

  // calls a tool that returns an image: {src, headers} with lower case header names, or null
  async function callImage(name, args) {
    try {
      const result = await request("tools/call", { name, arguments: args });
      const image = result && !result.isError && result.content && result.content.find((item) => item.type === "image");
      if (!image) return null;
      const response = envelope(result) || {};
      const headers = Object.fromEntries(Object.entries(response.headers || {}).map(([key, value]) => [key.toLowerCase(), value]));
      return { src: `data:${image.mimeType};base64,${image.data}`, headers };
    } catch { return null; }
  }

  // tells the model what the user did in the card, hosts without support reject it
  function tellModel(text) {
    request("ui/update-model-context", { content: [{ type: "text", text }] }).catch(() => {});
  }

  // opens a link through the host, or itself when the host refuses (some only open web links)
  function openLink(url) {
    const fallback = () => window.open(url, "_blank", "noopener");
    request("ui/open-link", { url }).then((result) => { if (result && result.isError) fallback(); }).catch(fallback);
  }

  // the signed in user, for deciding which actions to offer
  let me = null;
  function currentUser() {
    me = me || callTool("users_current", {}, "Unable to load your details").catch(() => ({}));
    return me;
  }

  // ---- DOM ----
  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null || value === false) continue;
      if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else node.setAttribute(key, value === true ? "" : value);
    }
    for (const child of children.flat(Infinity)) if (child !== null && child !== undefined && child !== false) node.append(child);
    return node;
  }

  // replaces the children, skipping empty ones (null would show as the text "null")
  function fill(node, ...children) {
    node.replaceChildren(...children.flat(Infinity).filter((child) => child !== null && child !== undefined && child !== false));
    return node;
  }

  // replaces the element with this id by a fresh render of it
  function refresh(id, view) {
    const node = document.getElementById(id);
    if (node) node.replaceWith(view());
  }

  const ICONS = {
    mail: '<path d="M3 5h18v14H3z"/><path d="m3 6 9 7 9-7"/>',
    phone: '<path d="M5 3h4l2 5-2.5 1.5a11 11 0 0 0 6 6L16 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 5a2 2 0 0 1 2-2"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    locate: '<circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M2 12h4M18 12h4"/>',
    map: '<path d="m9 4-6 2v14l6-2 6 2 6-2V4l-6 2z"/><path d="M9 4v14M15 6v14"/>',
    video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>',
    back: '<path d="m15 18-6-6 6-6"/>',
  };
  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "2");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    svg.innerHTML = ICONS[name] || "";
    return svg;
  }

  const lower = (value) => String(value || "").trim().toLowerCase();
  const narrow = () => window.matchMedia("(max-width: 639px)").matches;

  // ---- time: epochs shown and entered in an IANA timezone ----
  const localZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  function zoneOf(tz) { try { new Intl.DateTimeFormat(undefined, { timeZone: tz }); return tz || localZone; } catch { return localZone; } }
  const format = (epoch, tz, options) => new Intl.DateTimeFormat(undefined, { ...options, timeZone: zoneOf(tz) }).format(new Date(epoch * 1000));
  const fmtTime = (epoch, tz) => format(epoch, tz, { hour: "numeric", minute: "2-digit" });
  const fmtHour = (epoch, tz) => format(epoch, tz, { hour: "numeric" });
  // "Today, Tue 13 Oct", "Tomorrow, …" or "Thu 15 Oct", with the year when it isn't this year
  function fmtDay(epoch, tz) {
    const date = wallClock(epoch, tz).date;
    const today = wallClock(Date.now() / 1000, tz).date;
    const options = { weekday: "short", day: "numeric", month: "short" };
    if (date.slice(0, 4) !== today.slice(0, 4)) options.year = "numeric";
    const day = format(epoch, tz, options);
    if (date === today) return `Today, ${day}`;
    if (date === nextDay(today)) return `Tomorrow, ${day}`;
    return day;
  }
  // the zone's short name, i.e. "AEDT", when it's not the viewer's own zone
  function zoneName(epoch, tz) {
    const part = new Intl.DateTimeFormat(undefined, { timeZoneName: "short", timeZone: zoneOf(tz) }).formatToParts(new Date(epoch * 1000)).find((item) => item.type === "timeZoneName");
    return part ? part.value : "";
  }
  // "4:00 – 4:30 pm", the locale's way of writing a range of times
  function fmtTimes(start, end, tz) {
    const formatter = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", timeZone: zoneOf(tz) });
    return formatter.formatRange ? formatter.formatRange(new Date(start * 1000), new Date(end * 1000)) : `${fmtTime(start, tz)} – ${fmtTime(end, tz)}`;
  }
  // "Today, Tue 13 Oct · 4:00 – 4:30 pm AEDT"
  function fmtRange(start, end, tz, withZone = true) {
    const sameDay = wallClock(start, tz).date === wallClock(end - 1, tz).date;
    const times = sameDay ? fmtTimes(start, end, tz) : `${fmtTime(start, tz)} – ${fmtDay(end, tz)} ${fmtTime(end, tz)}`;
    return `${fmtDay(start, tz)} · ${times}${withZone ? ` ${zoneName(start, tz)}` : ""}`;
  }
  // {date: "YYYY-MM-DD", time: "HH:MM"} of an epoch in a timezone
  function wallClock(epoch, tz) {
    const parts = new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: zoneOf(tz) }).formatToParts(new Date(epoch * 1000));
    const part = (type) => parts.find((item) => item.type === type).value;
    return { date: `${part("year")}-${part("month")}-${part("day")}`, time: `${part("hour")}:${part("minute")}` };
  }
  // the epoch of a date and time in a timezone
  function zonedEpoch(date, time, tz) {
    const [y, m, d] = date.split("-").map(Number);
    const [h, mi] = time.split(":").map(Number);
    const target = Date.UTC(y, m - 1, d, h, mi) / 1000;
    let epoch = target;
    for (let i = 0; i < 2; i++) {
      const wall = wallClock(epoch, tz);
      const [wy, wm, wd] = wall.date.split("-").map(Number);
      const [wh, wmi] = wall.time.split(":").map(Number);
      epoch += target - Date.UTC(wy, wm - 1, wd, wh, wmi) / 1000;
    }
    return epoch;
  }
  // the date (YYYY-MM-DD) some days after another
  function addDays(date, days) {
    const [y, m, d] = date.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
  }
  const nextDay = (date) => addDays(date, 1);
  const prevDay = (date) => addDays(date, -1);
  const nextQuarterHour = () => Math.ceil(Date.now() / 900000) * 900;

  // ---- people: avatars with a photo (staff_photo) or initials ----
  const photos = new Map();
  let photoSlots = 3;
  const photoQueue = [];
  function photoOf(email) {
    const key = lower(email);
    if (!key) return Promise.resolve(null);
    if (!photos.has(key)) {
      photos.set(key, new Promise((resolve) => photoQueue.push({ key, resolve })));
      pumpPhotos();
    }
    return photos.get(key);
  }
  // at most three photo requests at a time
  function pumpPhotos() {
    while (photoSlots > 0 && photoQueue.length) {
      const { key, resolve } = photoQueue.shift();
      photoSlots--;
      callImage("staff_photo", { id: key }).then((image) => resolve(image && image.src)).finally(() => { photoSlots++; pumpPhotos(); });
    }
  }

  function initials(person) {
    const name = String((person && (person.name || person.email)) || "?").replace(/@.*/, "");
    const words = name.split(/[\s._-]+/).filter(Boolean);
    return words.slice(0, 2).map((word) => word[0].toUpperCase()).join("") || "?";
  }

  // an avatar showing the initials until the photo loads, `photo: false` skips the photo
  function avatar(person, { large = false, photo = true } = {}) {
    const node = el("span", { class: large ? "avatar large" : "avatar", "aria-hidden": "true" }, initials(person));
    if (photo && person && person.email) {
      photoOf(person.email).then((src) => { if (src) node.append(el("img", { src, alt: "" })); });
    }
    return node;
  }

  function personRow(person, sub, extra) {
    return el("div", { class: "person" }, avatar(person),
      el("div", { class: "who" },
        el("div", { class: "name" }, person.name || person.email),
        sub || extra ? el("div", { class: "sub" }, sub, extra) : null));
  }

  // ---- media: photos and the level map ----
  // images: {count, load(index) → Promise(src | null), caption}
  // map: {load() → Promise({src, x, y, box} | null), caption}
  function mediaRow({ images, map }) {
    const hasImages = images && images.count > 0;
    const row = el("div", { class: "media" });
    const photosPanel = hasImages ? carousel(images) : null;
    let toggle = null;
    // a room or desk that isn't drawn on a map leaves the photos on their own
    const missing = () => {
      mapPanel.remove();
      if (toggle) toggle.remove();
      if (photosPanel) photosPanel.classList.add("solo");
      else row.remove();
    };
    const mapPanel = map ? mapViewer({ ...map, missing }) : null;
    if (photosPanel && !mapPanel) photosPanel.classList.add("solo");
    if (mapPanel && !photosPanel) mapPanel.classList.add("solo", "open");
    fill(row, photosPanel, mapPanel);
    if (mapPanel && photosPanel) {
      // narrow cards show the map under the photos once asked for, loading it then
      toggle = el("button", { type: "button", class: "map-toggle", "aria-expanded": "false" }, icon("map"), "Show map");
      toggle.addEventListener("click", () => {
        const open = !mapPanel.classList.contains("open");
        mapPanel.classList.toggle("open", open);
        toggle.setAttribute("aria-expanded", String(open));
        toggle.lastChild.textContent = open ? "Hide map" : "Show map";
        if (open) mapPanel.load();
      });
      row.append(toggle);
      if (!narrow()) mapPanel.load();
    } else if (mapPanel) {
      mapPanel.load();
    }
    if (!photosPanel && !mapPanel) return null;
    return row;
  }

  function carousel({ count, load, caption }) {
    const loaded = new Map();
    let index = 0;
    const panel = el("div", { class: "panel carousel", role: "group", "aria-label": "Photos" });
    const show = (next) => {
      index = (next + count) % count;
      render();
      if (!loaded.has(index)) {
        const wanted = index;
        loaded.set(wanted, null);
        load(wanted).then((src) => { loaded.set(wanted, src || "error"); if (index === wanted) render(); });
      }
    };
    const render = () => {
      const src = loaded.get(index);
      fill(panel,
        src && src !== "error" ? el("img", { src, alt: `Photo ${index + 1} of ${count}` }) : el("div", { class: "placeholder" }, src === "error" ? "Photo unavailable" : "Loading photo…"),
        caption ? el("div", { class: "caption" }, caption) : null,
        count > 1 ? [
          el("button", { type: "button", class: "nav prev", "aria-label": "Previous photo", onclick: () => show(index - 1) }, "‹"),
          el("button", { type: "button", class: "nav next", "aria-label": "Next photo", onclick: () => show(index + 1) }, "›"),
          el("div", { class: "dots" }, Array.from({ length: count }, (_, dot) =>
            el("button", { type: "button", "aria-label": `Photo ${dot + 1}`, "aria-current": String(dot === index), onclick: () => show(dot) }))),
        ] : null);
    };
    show(0);
    return panel;
  }

  // the level map with a pin, zoomed with the buttons, ctrl + wheel or a pinch, dragged to pan
  function mapViewer({ load, caption, missing }) {
    const panel = el("div", { class: "panel map", role: "group", "aria-label": "Level map" });
    const canvas = el("div", { class: "canvas" });
    let map = null;
    let view = { scale: 1, x: 0, y: 0 };
    let base = { width: 0, height: 0 };
    let started = false;
    const MIN = 1;
    const MAX = 8;

    fill(panel, el("div", { class: "placeholder" }, "Loading map…"));

    // the map's size at scale 1, contained in the panel
    function measure() {
      const width = panel.clientWidth;
      const height = panel.clientHeight;
      const ratio = map.box[2] / map.box[3];
      base = width / height > ratio ? { width: height * ratio, height } : { width, height: width / ratio };
      canvas.style.width = `${base.width}px`;
      canvas.style.height = `${base.height}px`;
    }
    function clamp() {
      const width = panel.clientWidth;
      const height = panel.clientHeight;
      view.scale = Math.min(MAX, Math.max(MIN, view.scale));
      const w = base.width * view.scale;
      const h = base.height * view.scale;
      view.x = w <= width ? (width - w) / 2 : Math.min(0, Math.max(width - w, view.x));
      view.y = h <= height ? (height - h) / 2 : Math.min(0, Math.max(height - h, view.y));
      canvas.style.transform = `translate(${view.x}px, ${view.y}px) scale(${view.scale})`;
      panel.dataset.scale = view.scale.toFixed(2);
    }
    // zoom around a point of the panel
    function zoom(factor, cx = panel.clientWidth / 2, cy = panel.clientHeight / 2) {
      const scale = Math.min(MAX, Math.max(MIN, view.scale * factor));
      view.x = cx - ((cx - view.x) * scale) / view.scale;
      view.y = cy - ((cy - view.y) * scale) / view.scale;
      view.scale = scale;
      clamp();
    }
    // the pin in the middle, zoomed in a little
    function recenter() {
      measure();
      view.scale = 2;
      const px = ((map.x - map.box[0]) / map.box[2]) * base.width * view.scale;
      const py = ((map.y - map.box[1]) / map.box[3]) * base.height * view.scale;
      view.x = panel.clientWidth / 2 - px;
      view.y = panel.clientHeight / 2 - py;
      clamp();
    }

    function show() {
      const [minX, minY, width, height] = map.box;
      const pin = el("div", { class: "pin", style: `left:${((map.x - minX) / width) * 100}%;top:${((map.y - minY) / height) * 100}%` });
      // the SVG is shown as an image, so nothing in it can run
      fill(canvas, el("img", { src: map.src, alt: "", onload: recenter }), pin);
      fill(panel, canvas,
        el("div", { class: "controls" },
          el("button", { type: "button", "aria-label": "Zoom in", title: "Zoom in", onclick: () => zoom(1.5) }, icon("plus")),
          el("button", { type: "button", "aria-label": "Zoom out", title: "Zoom out", onclick: () => zoom(1 / 1.5) }, icon("minus")),
          el("button", { type: "button", "aria-label": "Recenter", title: "Recenter", onclick: recenter }, icon("locate"))),
        caption || map.location ? el("div", { class: "caption" }, caption || map.location) : null);
      new ResizeObserver(() => { if (panel.clientWidth) { measure(); clamp(); } }).observe(panel);
    }

    // dragging with one pointer, pinching with two
    const pointers = new Map();
    let pinch = null;
    panel.addEventListener("pointerdown", (event) => {
      if (!map || event.target.closest(".controls")) return;
      panel.setPointerCapture(event.pointerId);
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      panel.classList.add("dragging");
      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()];
        pinch = Math.hypot(a.x - b.x, a.y - b.y);
      }
    });
    panel.addEventListener("pointermove", (event) => {
      const last = pointers.get(event.pointerId);
      if (!last) return;
      const point = { x: event.clientX, y: event.clientY };
      pointers.set(event.pointerId, point);
      if (pointers.size === 2 && pinch) {
        const [a, b] = [...pointers.values()];
        const distance = Math.hypot(a.x - b.x, a.y - b.y);
        const rect = panel.getBoundingClientRect();
        zoom(distance / pinch, (a.x + b.x) / 2 - rect.left, (a.y + b.y) / 2 - rect.top);
        pinch = distance;
      } else if (pointers.size === 1) {
        view.x += point.x - last.x;
        view.y += point.y - last.y;
        clamp();
      }
    });
    const release = (event) => {
      pointers.delete(event.pointerId);
      if (pointers.size < 2) pinch = null;
      if (!pointers.size) panel.classList.remove("dragging");
    };
    panel.addEventListener("pointerup", release);
    panel.addEventListener("pointercancel", release);
    // trackpad pinches arrive as ctrl + wheel, a plain wheel keeps scrolling the page
    panel.addEventListener("wheel", (event) => {
      if (!map || !event.ctrlKey) return;
      event.preventDefault();
      const rect = panel.getBoundingClientRect();
      zoom(Math.exp(-event.deltaY / 200), event.clientX - rect.left, event.clientY - rect.top);
    }, { passive: false });

    panel.load = () => {
      if (started) return;
      started = true;
      load().then((found) => {
        if (!found) return missing ? missing() : fill(panel, el("div", { class: "placeholder" }, "Map unavailable"));
        map = found;
        show();
      });
    };
    return panel;
  }

  // a map tool's image as the viewer's {src, x, y, box, location}, or null when it isn't
  // drawn on one. location is "Level 1 · Building", from the X-Map-Location header
  async function loadMap(tool, args) {
    const image = await callImage(tool, args);
    if (!image) return null;
    const pin = String(image.headers["x-map-pin"] || "").split(",").map(Number);
    const box = String(image.headers["x-map-view-box"] || "").split(/[\s,]+/).map(Number);
    if (pin.length !== 2 || box.length !== 4 || !(box[2] > 0 && box[3] > 0)) return null;
    let location = "";
    try { location = decodeURIComponent(image.headers["x-map-location"] || ""); } catch { /* left out */ }
    return { src: image.src, x: pin[0], y: pin[1], box, location };
  }

  // ---- a day's availability as a bar ----
  // segments: [{start, end, kind}] with kind free, me, them, both, busy, booked or past;
  // legend: [[kind, label]]; selected: {start, end}; onPick(epoch) when a spot is clicked
  function timeline({ id, from, to, tz, segments, selected, legend, title, loading, onPick }) {
    const span = to - from;
    const pct = (epoch) => `${((Math.min(Math.max(epoch, from), to) - from) / span) * 100}%`;
    const bar = el("div", { class: loading ? "bar loading" : "bar", role: "img", "aria-label": title || "Availability" });
    if (!loading) {
      for (const segment of segments) {
        if (segment.end <= from || segment.start >= to || segment.kind === "free") continue;
        bar.append(el("div", { class: `seg kind-${segment.kind}`, style: `left:${pct(segment.start)};width:calc(${pct(segment.end)} - ${pct(segment.start)})`, title: segment.label || "" }));
      }
      if (selected && selected.end > from && selected.start < to) {
        bar.append(el("div", { class: "selected", style: `left:${pct(selected.start)};width:calc(${pct(selected.end)} - ${pct(selected.start)})` }));
      }
      if (onPick) {
        bar.addEventListener("click", (event) => {
          const rect = bar.getBoundingClientRect();
          const epoch = from + ((event.clientX - rect.left) / rect.width) * span;
          onPick(Math.floor(epoch / 900) * 900);
        });
      }
    }
    const ticks = el("div", { class: "ticks", "aria-hidden": "true" });
    for (let tick = from; tick < to; tick += 7200) ticks.append(el("span", { style: `left:${pct(tick)}` }, fmtHour(tick, tz)));
    return el("div", { class: "timeline", id },
      el("div", { class: "row", style: "justify-content:space-between" },
        title ? el("strong", { style: "font-size:13px" }, title) : null,
        legend ? el("div", { class: "legend" }, legend.map(([kind, label]) => el("span", {}, el("i", { class: `kind-${kind}` }), label))) : null),
      bar, ticks);
  }

  // the busy segments merged into who's busy when: me, them or both
  function overlay(mine, theirs) {
    const points = [...new Set([...mine, ...theirs].flatMap((period) => [period.start, period.end]))].sort((a, b) => a - b);
    const busy = (list, start, end) => list.some((period) => period.start < end && period.end > start);
    const segments = [];
    for (let i = 0; i < points.length - 1; i++) {
      const [start, end] = [points[i], points[i + 1]];
      const me = busy(mine, start, end);
      const them = busy(theirs, start, end);
      if (!me && !them) continue;
      const kind = me && them ? "both" : me ? "me" : "them";
      const last = segments[segments.length - 1];
      if (last && last.kind === kind && last.end === start) last.end = end;
      else segments.push({ start, end, kind });
    }
    return segments;
  }
