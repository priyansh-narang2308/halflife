// Renders each diagram HTML in this folder to ../images/<name>.png at 2x.
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const chrome = process.env.CHROME;
// PUPPETEER_FROM: a node_modules folder that has puppeteer-core (e.g. ../../video/node_modules)
const puppeteer = createRequire(join(process.env.PUPPETEER_FROM, "x.js"))("puppeteer-core");
const b = await puppeteer.launch({ executablePath: chrome, headless: true });
for (const f of readdirSync(here).filter((n) => n.endsWith(".html") && (!process.argv[2] || n.startsWith(process.argv[2])))) {
  const p = await b.newPage();
  await p.setViewport({ width: 1600, height: 900, deviceScaleFactor: 2 });
  await p.goto("file://" + join(here, f), { waitUntil: "networkidle0" });
  await p.evaluate(() => document.fonts.ready);
  const el = await p.$(".canvas");
  await el.screenshot({ path: join(here, "../images", f.replace(".html", ".png")) });
  console.log("rendered", f);
}
await b.close();
