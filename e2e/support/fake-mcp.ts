import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { Page, Route } from "@playwright/test";

// Answers the card previewer's MCP requests in the browser, so the cards render without a
// database, a calendar provider or authentication. Tool results use the real server's
// shape: `structuredContent` is the {status, headers, body} envelope, images are an image
// content block (see action-controller's MCP invoker).

const MCP_PATH = "**/api/staff/v1/mcp";
const CARDS = join(__dirname, "../../cards");

// the tools that render each card, as annotated with `@[AC::MCP(ui:)]`
export const CARD_TOOLS: Record<string, string> = {
  events_show: "events",
  events_book: "events",
  bookings_show: "bookings",
  bookings_book: "bookings",
  staff_show: "staff",
  staff_index: "staff",
  spaces_show: "spaces",
  spaces_index: "spaces",
  calendars_availability: "spaces",
};

// every tool a card calls, found the same way as the mcp_spec check (the kit's photo, image and map
// helpers take the tool name as their first argument)
function cardCalledTools(): string[] {
  const names = new Set<string>();
  for (const folder of readdirSync(CARDS)) {
    const file = join(CARDS, folder, "card.html");
    if (!existsSync(file)) continue;
    const html = readFileSync(file, "utf8");
    for (const match of html.matchAll(/name: "(\w+)", arguments|(?:callTool|callImage|loadMap)\("(\w+)"/g)) names.add(match[1] ?? match[2]);
  }
  return [...names];
}

export interface ToolReply {
  status?: number;
  headers?: Record<string, string>;
  body?: unknown;
  image?: { mimeType: string; data: Buffer };
}

export type ToolHandler = (args: Record<string, any>) => ToolReply | Promise<ToolReply>;

export const ok = (body: unknown, headers: Record<string, string> = {}): ToolReply => ({ status: 200, body, headers });
export const created = (body: unknown): ToolReply => ({ status: 201, body });
export const accepted = (): ToolReply => ({ status: 202 });
export const failure = (status: number, message: string): ToolReply => ({ status, body: { error: message } });
export const image = (mimeType: string, data: Buffer, headers: Record<string, string> = {}): ToolReply => ({ status: 200, image: { mimeType, data }, headers });

export interface ToolCall {
  name: string;
  arguments: Record<string, any>;
}

export class FakeMcp {
  readonly calls: ToolCall[] = [];
  private readonly tools: Record<string, ToolHandler>;

  constructor(tools: Record<string, ToolHandler>) {
    this.tools = tools;
  }

  // the calls made to a tool, in order
  callsTo(name: string): Record<string, any>[] {
    return this.calls.filter((call) => call.name === name).map((call) => call.arguments);
  }

  // replaces or adds tools, i.e. a different result for the next call
  use(tools: Record<string, ToolHandler>): void {
    Object.assign(this.tools, tools);
  }

  async install(page: Page): Promise<void> {
    await page.route(MCP_PATH, (route) => this.handle(route));
  }

  private async handle(route: Route): Promise<void> {
    const request = route.request();
    if (request.method() !== "POST") return route.fulfill({ status: 202 });
    const message = request.postDataJSON();
    if (message.id === undefined) return route.fulfill({ status: 202 });

    let result: unknown;
    try {
      result = await this.dispatch(message.method, message.params ?? {});
    } catch (error) {
      return route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: (error as Error).message } }),
      });
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "Mcp-Session-Id": "e2e-session" },
      body: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }),
    });
  }

  private async dispatch(method: string, params: Record<string, any>): Promise<unknown> {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: params.protocolVersion,
          capabilities: { tools: { listChanged: true }, resources: {}, extensions: { "io.modelcontextprotocol/ui": {} } },
          serverInfo: { name: "placeos-staff", version: "e2e" },
        };
      case "tools/list":
        return { tools: this.listTools() };
      case "resources/read":
        return this.readCard(params.uri);
      case "tools/call":
        return this.callTool(params.name, params.arguments ?? {});
      default:
        return {};
    }
  }

  private listTools() {
    const names = new Set([...Object.keys(CARD_TOOLS), ...cardCalledTools()]);
    return [...names].map((name) => {
      const card = CARD_TOOLS[name];
      const tool: Record<string, unknown> = { name, inputSchema: { type: "object" } };
      if (card) tool._meta = { ui: { resourceUri: `ui://${card}/card.html?v=e2e` }, "ui/resourceUri": `ui://${card}/card.html?v=e2e` };
      return tool;
    });
  }

  private readCard(uri: string) {
    const path = uri.replace(/^ui:\/\//, "").replace(/\?.*$/, "");
    return {
      contents: [{
        uri,
        mimeType: "text/html;profile=mcp-app",
        text: readFileSync(join(CARDS, path), "utf8"),
        _meta: { ui: { prefersBorder: true } },
      }],
    };
  }

  private async callTool(name: string, args: Record<string, any>) {
    this.calls.push({ name, arguments: args });
    const handler = this.tools[name];
    const reply = handler ? await handler(args) : failure(404, `no fixture for ${name}`);
    const status = reply.status ?? 200;
    const envelope: Record<string, unknown> = { status };
    if (reply.headers && Object.keys(reply.headers).length) envelope.headers = reply.headers;
    if (reply.body !== undefined) envelope.body = reply.body;

    const content: unknown[] = [];
    if (reply.image) content.push({ type: "image", data: reply.image.data.toString("base64"), mimeType: reply.image.mimeType });
    content.push({ type: "text", text: JSON.stringify(envelope) });
    return { content, structuredContent: envelope, isError: status >= 400 };
  }
}
