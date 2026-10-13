// Copies the shared card code (cards/_kit) into every card, between its markers:
//   /* kit:css */ … /* /kit:css */ in the card's <style>
//   // kit:js … // /kit:js in the card's <script>
// Cards are served as single files, so they can't import it. `--check` only reports
// cards that are out of date (used by the browser tests).
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const cards = join(dirname(fileURLToPath(import.meta.url)), "../cards");
const css = readFileSync(join(cards, "_kit/kit.css"), "utf8").trimEnd();
const js = readFileSync(join(cards, "_kit/kit.js"), "utf8").trimEnd();
const check = process.argv.includes("--check");

const stale = [];
for (const folder of readdirSync(cards)) {
  const file = join(cards, folder, "card.html");
  if (folder.startsWith("_") || !existsSync(file)) continue;
  const html = readFileSync(file, "utf8");
  const synced = html
    .replace(/\/\* kit:css \*\/[\s\S]*?\/\* \/kit:css \*\//, () => `/* kit:css */\n${css}\n/* /kit:css */`)
    .replace(/\/\/ kit:js\n[\s\S]*?\/\/ \/kit:js/, () => `// kit:js\n${js}\n  // /kit:js`);
  if (!html.includes("/* kit:css */") || !html.includes("// kit:js")) {
    stale.push(`${folder}: missing the kit markers`);
  } else if (synced !== html) {
    stale.push(check ? folder : `updated ${folder}`);
    if (!check) writeFileSync(file, synced);
  }
}

if (check && stale.length) {
  console.error(`cards out of date with cards/_kit, run npm run cards:kit: ${stale.join(", ")}`);
  process.exit(1);
}
if (!check) console.log(stale.length ? stale.join("\n") : "cards are up to date");
