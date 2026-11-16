import { defineConfig } from "@playwright/test";

// the app is started on its own port, so it doesn't clash with a development server
const port = Number(process.env.E2E_PORT ?? 3011);

// Browser tests for the MCP Apps cards, see e2e/README.md
export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    // wide enough for the previewer's desktop viewport (1280px) beside its form
    viewport: { width: 1920, height: 1200 },
    // the fixtures are in Sydney, so the cards show the times they're written with
    timezoneId: "Australia/Sydney",
    locale: "en-AU",
    trace: "retain-on-failure",
  },
  webServer: {
    // a development build: the previewer only serves pages, the tests answer the MCP
    // requests (e2e/support/fake-mcp.ts), so no database or calendar is needed
    command: `mkdir -p bin && crystal build src/staff-api.cr -o bin/staff-api-e2e && ./bin/staff-api-e2e -p ${port}`,
    url: `http://127.0.0.1:${port}/api/staff/v1/mcp/preview`,
    env: {
      MCP_PREVIEW_PATH: "/api/staff/v1/mcp/preview",
      PLACE_URI: "http://127.0.0.1:1",
      PG_DATABASE_URL: "postgresql://e2e@127.0.0.1:1/e2e",
    },
    reuseExistingServer: !process.env.CI,
    timeout: 600_000, // the first build can be slow
  },
});
