import test from "node:test";
import assert from "node:assert/strict";
import { redact } from "../dist/redact.js";

test("redacts credentials and audio paths", () => {
  const value = redact([
    "authorization: Bearer secret.token",
    "{\"access_token\":\"access-secret\",\"id_token\":\"id-secret\"}",
    "JWT eyJabc.def.sig",
    "/tmp/code-review/recording.wav",
    "C:\\Temp\\recording.wav",
  ].join("\n"));

  assert.equal(value.includes("secret.token"), false);
  assert.equal(value.includes("access-secret"), false);
  assert.equal(value.includes("id-secret"), false);
  assert.equal(value.includes("eyJabc.def.sig"), false);
  assert.equal(value.includes("/tmp/code-review/recording.wav"), false);
  assert.equal(value.includes("C:\\Temp\\recording.wav"), false);
  assert.equal(value.includes("[REDACTED_AUDIO_PATH]"), true);
});
