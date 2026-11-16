import { execFileSync } from "node:child_process";
import { expect, test } from "@playwright/test";

// the cards are served as single files, each has a copy of cards/_kit
test("every card has the current shared kit", () => {
  expect(() => execFileSync("node", ["scripts/sync-card-kit.mjs", "--check"], { stdio: "pipe" })).not.toThrow();
});
