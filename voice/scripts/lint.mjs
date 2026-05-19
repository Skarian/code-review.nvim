import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

async function files(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await files(full));
    else if (entry.name.endsWith(".ts") || entry.name.endsWith(".mjs")) out.push(full);
  }
  return out;
}

let failed = false;
for (const file of [...await files("src"), ...await files("tests"), ...await files("scripts")]) {
  const text = await readFile(file, "utf8");
  if (text.includes("\t")) {
    console.error(`${file}: tabs are not allowed`);
    failed = true;
  }
  if (text.match(/[ \t]$/m)) {
    console.error(`${file}: trailing whitespace`);
    failed = true;
  }
}
if (failed) process.exit(1);
