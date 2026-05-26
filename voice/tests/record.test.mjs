import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { recordCommand } from "../dist/record.js";
import { createRecorder } from "../dist/audio/decibri.js";

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

test("record command bounds recorder stop hangs", async () => {
  const makeRecorder = (calls) => ({
    ok: true,
    error: () => null,
    stop: async () => new Promise(() => {}),
    forceStop: async () => { calls.forceStop += 1; }
  });

  const stopCalls = { forceStop: 0 };
  const stopStdin = new FakeStdin();
  const stop = recordCommand(["--out", "/tmp/recording.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stopStdin, {
    printJson: () => {},
    stopTimeoutMs: 5,
    createRecorder: async () => makeRecorder(stopCalls)
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stopStdin.send("stop\n");
  const stopResult = await stop;
  assert.equal(stopResult.ok, false);
  assert.equal(stopResult.code, "timeout");
  assert.equal(stopCalls.forceStop, 1);

  const discardCalls = { forceStop: 0 };
  const discardStdin = new FakeStdin();
  const discard = recordCommand(["--out", "/tmp/missing-discard.wav", "--max-ms", "10000"], discardStdin, {
    printJson: () => {},
    stopTimeoutMs: 5,
    createRecorder: async () => makeRecorder(discardCalls)
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  discardStdin.send("discard\n");
  assert.deepEqual(await discard, { ok: true, event: "discarded" });
  assert.equal(discardCalls.forceStop, 1);

  const shortCalls = { forceStop: 0 };
  const shortStdin = new FakeStdin();
  const short = recordCommand(["--out", "/tmp/missing-short.wav", "--max-ms", "10000", "--min-duration-ms", "900"], shortStdin, {
    printJson: () => {},
    stopTimeoutMs: 5,
    createRecorder: async () => makeRecorder(shortCalls)
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  shortStdin.send("stop\n");
  const shortResult = await short;
  assert.equal(shortResult.ok, true);
  assert.equal(shortResult.event, "recording_too_short");
  assert.equal(shortCalls.forceStop, 1);

  const timeoutCalls = { forceStop: 0 };
  const timeout = await recordCommand(["--out", "/tmp/missing-timeout.wav", "--max-ms", "5"], new FakeStdin(), {
    printJson: () => {},
    stopTimeoutMs: 5,
    createRecorder: async () => makeRecorder(timeoutCalls)
  });
  assert.equal(timeout.ok, false);
  assert.equal(timeout.code, "timeout");
  assert.equal(timeoutCalls.forceStop, 1);
});

test("record command maps stop rejection to documented recording error", async () => {
  const stdin = new FakeStdin();
  const calls = { forceStop: 0 };
  const promise = recordCommand(["--out", "/tmp/missing-reject.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => null,
      stop: async () => { throw Object.assign(new Error("boom"), { code: "StopFailed" }); },
      forceStop: async () => { calls.forceStop += 1; }
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.ok, false);
  assert.equal(result.code, "recording_permission_denied");
  assert.equal(calls.forceStop, 1);
});

test("record command force-stops recorder after mid-recording error", async () => {
  const stdin = new FakeStdin();
  const calls = { forceStop: 0, stop: 0 };
  let failed = false;
  const promise = recordCommand(["--out", "/tmp/missing-mid-recording-error.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => failed ? Object.assign(new Error("device lost"), { code: "DeviceLost" }) : null,
      stop: async () => { calls.stop += 1; return { audioBytes: 0, wav: Buffer.alloc(44) }; },
      forceStop: async () => { calls.forceStop += 1; }
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  failed = true;
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.ok, false);
  assert.equal(result.code, "recording_permission_denied");
  assert.equal(calls.forceStop, 1);
  assert.equal(calls.stop, 0);
});

test("record command force-stops recorder after startup error", async () => {
  const calls = { forceStop: 0 };
  const result = await recordCommand(["--out", "/tmp/missing-startup-error.wav", "--max-ms", "10000"], new FakeStdin(), {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => Object.assign(new Error("permission denied"), { code: "PermissionDenied" }),
      stop: async () => ({ audioBytes: 0, wav: Buffer.alloc(44) }),
      forceStop: async () => { calls.forceStop += 1; }
    })
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "recording_permission_denied");
  assert.equal(calls.forceStop, 1);
});

test("ffmpeg recorder escalates from SIGINT to SIGKILL when stop hangs", async () => {
  const { EventEmitter } = await import("node:events");
  const kills = [];
  const spawnImpl = () => {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = (signal) => {
      kills.push(signal);
      return true;
    };
    return child;
  };

  const recorder = await createRecorder({
    out: "/tmp/missing-ffmpeg.wav",
    platform: "darwin",
    commandExistsImpl: async () => true,
    spawnImpl,
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  await recorder.stop();
  assert.deepEqual(kills, ["SIGINT", "SIGKILL"]);
});

test("ffmpeg recorder does not force kill after graceful SIGINT exit", async () => {
  const { EventEmitter } = await import("node:events");
  const kills = [];
  const spawnImpl = () => {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = (signal) => {
      kills.push(signal);
      if (signal === "SIGINT") {
        process.nextTick(() => child.emit("exit", 0));
      }
      return true;
    };
    return child;
  };

  const recorder = await createRecorder({
    out: "/tmp/missing-ffmpeg.wav",
    platform: "darwin",
    commandExistsImpl: async () => true,
    spawnImpl,
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  await recorder.stop();
  assert.deepEqual(kills, ["SIGINT"]);
});
