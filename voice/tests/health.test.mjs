import test from "node:test";
import assert from "node:assert/strict";
import { health } from "../dist/health.js";

test("health does not require microphone access", async () => {
  const result = await health({ files: [] });
  assert.equal(result.ok, true);
  assert.equal(result.checks.some((check) => check.name === "audio_provider" && check.code === "not_checked"), true);
});

test("health checks chatgpt TLS reachability when credentials are fresh", async () => {
  const result = await health({
    credentials: { ok: true },
    tlsReachable: async () => true,
  });
  assert.equal(result.checks.some((check) => check.name === "network" && check.code === "chatgpt_reachable"), true);
  assert.equal(result.checks.some((check) => check.name === "transcription_endpoint"), false);

  const disabled = await health({ files: [], network: false });
  assert.equal(disabled.checks.some((check) => check.name === "network" && check.code === "disabled"), true);
});
