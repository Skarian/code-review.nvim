import test from "node:test";
import assert from "node:assert/strict";
import { run } from "../dist/cli.js";

test("invalid CLI arguments exit with code 2", async () => {
  const write = process.stdout.write;
  process.stdout.write = () => true;
  try {
    assert.equal(await run(["transcribe"]), 2);
    assert.equal(await run(["transcribe", "--input", "audio.wav", "--timeout-ms", "nope"]), 2);
    assert.equal(await run(["transcribe", "--input", "audio.wav", "--max-audio-bytes", "nope"]), 2);
    assert.equal(await run(["record", "--out", "audio.wav", "--max-ms", "nope"]), 2);
    assert.equal(await run(["record", "--out", "audio.wav", "--min-duration-ms", "nope"]), 2);
  } finally {
    process.stdout.write = write;
  }
});
