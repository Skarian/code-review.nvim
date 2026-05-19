import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { recordCommand } from "../dist/record.js";

class FakeStdin extends EventEmitter {
  setEncoding() {}
  send(text) {
    this.emit("data", text);
  }
}

test("record command emits documented stopped JSON contract", async () => {
  const stdin = new FakeStdin();
  const lines = [];
  const promise = recordCommand(["--out", "/tmp/recording.wav", "--max-ms", "10000"], stdin, {
    printJson: (value) => lines.push(value),
    minDurationMs: 0,
    createRecorder: async () => ({
      ok: true,
      error: () => null,
      stop: async () => ({ audioBytes: 128, wav: Buffer.alloc(172) })
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 910));
  stdin.send("stop\n");
  const result = await promise;
  assert.deepEqual(lines[0], { ok: true, event: "recording_started" });
  assert.equal(result.ok, true);
  assert.equal(result.event, "recording_stopped");
  assert.equal(result.audioBytes, 128);
  assert.equal(result.mimeType, "audio/wav");
  assert.equal("path" in result, false);
});

test("record command returns documented discard and too-short events", async () => {
  const makeRecorder = () => ({
    ok: true,
    error: () => null,
    stop: async () => ({ audioBytes: 0, wav: Buffer.alloc(44) })
  });

  const discardStdin = new FakeStdin();
  const discard = recordCommand(["--out", "/tmp/missing-discard.wav", "--max-ms", "10000"], discardStdin, { printJson: () => {}, createRecorder: async () => makeRecorder() });
  await new Promise((resolve) => setTimeout(resolve, 60));
  discardStdin.send("discard\n");
  assert.deepEqual(await discard, { ok: true, event: "discarded" });

  const shortStdin = new FakeStdin();
  const short = recordCommand(["--out", "/tmp/missing-short.wav", "--max-ms", "10000"], shortStdin, { printJson: () => {}, createRecorder: async () => makeRecorder() });
  await new Promise((resolve) => setTimeout(resolve, 60));
  shortStdin.send("stop\n");
  const result = await short;
  assert.equal(result.ok, true);
  assert.equal(result.event, "recording_too_short");
});

test("record command honors min duration argument", async () => {
  const stdin = new FakeStdin();
  const promise = recordCommand(["--out", "/tmp/recording.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => null,
      stop: async () => ({ audioBytes: 12, wav: Buffer.alloc(56) })
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
});
