# Browser tests for the MCP Apps cards

The cards in `cards/` are rendered in action-controller's card previewer and checked with
[Playwright](https://playwright.dev).

```shell
npm install
npx playwright install chromium
npm run test:e2e
```

Playwright builds the app and starts it on port 3011 (`E2E_PORT`) with `MCP_PREVIEW_PATH`
set, or reuses one already running there. The previewer is an MCP client of the app's MCP
endpoint, which needs authentication, Postgres and a calendar provider, so the tests answer
its requests in the browser instead (`support/fake-mcp.ts`) with the fixtures in
`support/fixtures.ts`: a Sydney office on Tuesday 13 October 2026, the clock fixed at 3:50pm.
The app only serves the previewer's pages, it runs without a database.

To try cards by hand, start the app with `MCP_PREVIEW_PATH=/api/staff/v1/mcp/preview` and
open that path. It calls the real tools, so add an `Authorization` header in the page.

## Writing tests

```typescript
const { card, mcp } = await renderCard(page, "events_show", { id: "evt-1" }, { viewport: "mobile", theme: "dark" });
await card.getByRole("button", { name: "Edit" }).click();
expect(mcp.callsTo("events_edit")).toEqual([...]);
```

* `renderCard` opens the tool's preview, answers the MCP requests and waits for the card.
  `tools` replaces fixture tools for one test, i.e. a failure or another user
* `mcp.callsTo(name)` lists the arguments of every call a card made to a tool
* `snapshot(page, name)` saves a screenshot of the card to `test-results/screenshots` for
  review. They aren't compared with baselines: fonts differ between operating systems
* script errors in the page or the card fail the test

## The shared kit

The cards are served as single files, so the code they share lives in `cards/_kit` and is
copied into each card between its `kit:css` and `kit:js` markers by `npm run cards:kit`.
`kit.spec.ts` fails when a card's copy is out of date.
