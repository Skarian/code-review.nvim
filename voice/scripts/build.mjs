import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const tsc = join(root, "node_modules", "typescript", "bin", "tsc");
const result = spawnSync(process.execPath, [tsc], { stdio: "inherit" });
process.exit(result.status ?? 1);
