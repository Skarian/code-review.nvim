import { access } from "node:fs/promises";

const required = [
  "src/index.ts",
  "src/cli.ts",
  "src/errors.ts",
  "src/auth.ts",
  "src/jwt.ts",
  "src/health.ts",
  "src/redact.ts",
  "src/transcribe.ts",
  "src/record.ts",
  "src/audio/decibri.ts"
];

for (const file of required) {
  await access(file);
}
