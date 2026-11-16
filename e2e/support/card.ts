import { test as base, expect, type FrameLocator, type Page } from "@playwright/test";
import { FakeMcp, type ToolHandler } from "./fake-mcp";
import { NOW, staffApi } from "./fixtures";

// Renders cards in the card previewer (mounted by src/staff-api.cr when MCP_PREVIEW_PATH is
// set) with the fake MCP server, and fails tests on script errors in the page or the card.

export type Viewport = "desktop" | "tablet" | "mobile";

export interface RenderOptions {
  viewport?: Viewport;
  theme?: "light" | "dark";
  // tools to answer differently from the fixtures
  tools?: Record<string, ToolHandler>;
}

export interface Rendered {
  card: FrameLocator;
  mcp: FakeMcp;
}

export const preview = (tool: string, args: Record<string, string | number> = {}, options: RenderOptions = {}) => {
  const params = new URLSearchParams(Object.entries(args).map(([key, value]) => [key, String(value)]));
  params.set("viewport_size", options.viewport ?? "desktop");
  params.set("theme", options.theme ?? "light");
  return `/api/staff/v1/mcp/preview/tools/${tool}?${params}`;
};

export async function renderCard(page: Page, tool: string, args: Record<string, string | number> = {}, options: RenderOptions = {}): Promise<Rendered> {
  const mcp = new FakeMcp({ ...staffApi(), ...options.tools });
  await mcp.install(page);
  await page.clock.setFixedTime(NOW);
  await page.goto(preview(tool, args, options));
  await expect(page.locator("#stage")).toHaveAttribute("data-state", "ready");
  return { card: page.frameLocator("#card"), mcp };
}

// the previewer logs protocol problems, such as tools the card isn't allowed to call
export async function previewerErrors(page: Page): Promise<string[]> {
  const log = await page.evaluate(() => (window as any).cardPreviewer.log);
  return log.filter((entry: { level: string }) => entry.level === "error").map((entry: { message?: string; text?: string }) => JSON.stringify(entry));
}

// whether the card scrolls sideways
export async function overflows(card: FrameLocator): Promise<boolean> {
  return card.locator("body").evaluate((body) => body.scrollWidth > body.ownerDocument.documentElement.clientWidth + 1);
}

// a screenshot of the card for review, in <output dir>/screenshots (not a baseline)
export async function snapshot(page: Page, name: string): Promise<void> {
  const dir = base.info().project.outputDir;
  await page.locator("#card").screenshot({ path: `${dir}/screenshots/${name}.png`, animations: "disabled" });
}

export const test = base.extend<{ pageErrors: string[] }>({
  pageErrors: [async ({ page }, use) => {
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await use(errors);
    expect(errors).toEqual([]);
  }, { auto: true }],
});

export { expect };
