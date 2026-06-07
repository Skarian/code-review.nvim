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

function wavWithPeak(size = 172, peak = 2048) {
  const wav = Buffer.alloc(size);
  wav.writeInt16LE(peak, 44);
  return wav;
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((promiseResolve, promiseReject) => {
    resolve = promiseResolve;
    reject = promiseReject;
  });
  return { promise, resolve, reject };
}

async function waitUntil(predicate, message, timeoutMs = 500) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail(message);
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
      stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
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

test("record command waits for recorder readiness before recording_started", async () => {
  const stdin = new FakeStdin();
  const lines = [];
  const ready = deferred();
  let startCalls = 0;
  const promise = recordCommand(["--out", "/tmp/recording-ready.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: (value) => lines.push(value),
    createRecorder: async () => ({
      ok: true,
      ready: () => ready.promise,
      start: async () => { startCalls += 1; },
      error: () => null,
      stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
    })
  });

  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.deepEqual(lines, []);
  assert.equal(startCalls, 0);

  ready.resolve();
  await waitUntil(() => lines.some((line) => line.event === "recording_started"), "recording_started was not emitted after readiness");
  assert.equal(startCalls, 1);
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
});

test("prearmed record emits ready, then starts after start command", async () => {
  const stdin = new FakeStdin();
  const lines = [];
  const ready = deferred();
  let startCalls = 0;
  const promise = recordCommand(["--prearm", "--out", "/tmp/prearmed-ready.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: (value) => lines.push(value),
    createRecorder: async () => ({
      ok: true,
      ready: () => ready.promise,
      start: async () => { startCalls += 1; },
      error: () => null,
      stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
    })
  });

  ready.resolve();
  await waitUntil(() => lines.some((line) => line.event === "recording_ready"), "recording_ready was not emitted");
  assert.equal(startCalls, 0);
  assert.equal(lines.some((line) => line.event === "recording_started"), false);

  stdin.send("start\n");
  await waitUntil(() => lines.some((line) => line.event === "recording_started"), "recording_started was not emitted after start");
  assert.equal(startCalls, 1);
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
});

test("prearmed record defers early start command until stream is ready", async () => {
  const stdin = new FakeStdin();
  const lines = [];
  const ready = deferred();
  let startCalls = 0;
  let recorderCreated = false;
  const promise = recordCommand(["--prearm", "--out", "/tmp/prearmed-warming.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: (value) => lines.push(value),
    createRecorder: async () => ({
      ok: true,
      ready: () => {
        recorderCreated = true;
        return ready.promise;
      },
      start: async () => { startCalls += 1; },
      error: () => null,
      stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
    })
  });

  await waitUntil(() => recorderCreated, "recorder was not created");
  stdin.send("start\n");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(startCalls, 0);
  assert.deepEqual(lines, []);

  ready.resolve();
  await waitUntil(() => lines.some((line) => line.event === "recording_started"), "recording_started was not emitted after ready");
  assert.deepEqual(lines.map((line) => line.event), ["recording_ready", "recording_started"]);
  assert.equal(startCalls, 1);
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
});

test("record command passes pre-roll duration to recorder", async () => {
  const stdin = new FakeStdin();
  let seen;
  const promise = recordCommand(["--out", "/tmp/recording-preroll.wav", "--max-ms", "10000", "--min-duration-ms", "0", "--pre-roll-ms", "123"], stdin, {
    printJson: () => {},
    createRecorder: async (opts) => {
      seen = opts;
      return {
        ok: true,
        error: () => null,
        stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
      };
    }
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
  assert.equal(seen.preRollMs, 123);
});

test("record command maps provider spawn failure during readiness", async () => {
  const calls = { forceStop: 0 };
  const result = await recordCommand(["--out", "/tmp/missing-provider.wav", "--max-ms", "10000"], new FakeStdin(), {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      ready: async () => { throw Object.assign(new Error("ffmpeg missing"), { code: "AudioProviderUnavailable" }); },
      error: () => null,
      forceStop: async () => { calls.forceStop += 1; },
      stop: async () => ({ audioBytes: 0, wav: Buffer.alloc(44) })
    })
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "audio_provider_unavailable");
  assert.equal(calls.forceStop, 1);
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
      stop: async () => ({ audioBytes: 12, wav: wavWithPeak(56) })
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
});

test("record command passes selected audio device to recorder", async () => {
  const stdin = new FakeStdin();
  let seen;
  const promise = recordCommand(["--out", "/tmp/recording.wav", "--max-ms", "10000", "--min-duration-ms", "0", "--audio-device", "ffmpeg-avfoundation:audio:1"], stdin, {
    printJson: () => {},
    createRecorder: async (opts) => {
      seen = opts;
      return {
        ok: true,
        error: () => null,
        stop: async () => ({ audioBytes: 128, wav: wavWithPeak() })
      };
    }
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.event, "recording_stopped");
  assert.equal(seen.audioDevice, "ffmpeg-avfoundation:audio:1");
});

test("record command rejects missing audio device argument", async () => {
  const result = await recordCommand(["--out", "/tmp/recording.wav", "--max-ms", "10000", "--audio-device"], new FakeStdin(), {
    printJson: () => {}
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_arguments");
});

test("record command rejects silent recordings before transcription", async () => {
  const stdin = new FakeStdin();
  const promise = recordCommand(["--out", "/tmp/missing-silent.wav", "--max-ms", "10000", "--min-duration-ms", "0"], stdin, {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => null,
      stop: async () => ({ audioBytes: 128, wav: Buffer.alloc(172) })
    })
  });
  await new Promise((resolve) => setTimeout(resolve, 60));
  stdin.send("stop\n");
  const result = await promise;
  assert.equal(result.ok, false);
  assert.equal(result.code, "empty_recording");
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

test("record command maps trusted opaque startup failure to unavailable device", async () => {
  const calls = { forceStop: 0 };
  const result = await recordCommand(["--out", "/tmp/missing-startup-device.wav", "--max-ms", "10000"], new FakeStdin(), {
    printJson: () => {},
    createRecorder: async () => ({
      ok: true,
      error: () => Object.assign(new Error("device missing"), { code: "AudioDeviceUnavailable" }),
      stop: async () => ({ audioBytes: 0, wav: Buffer.alloc(44) }),
      forceStop: async () => { calls.forceStop += 1; }
    })
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "audio_device_unavailable");
  assert.equal(calls.forceStop, 1);
});

test("ffmpeg recorder escalates from SIGINT to SIGKILL when stop hangs", async () => {
  const { EventEmitter } = await import("node:events");
  const kills = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.stdout = new EventEmitter();
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", "[AVFoundation indev @ x] AVFoundation audio devices:\n[AVFoundation indev @ x] [1] DJI Mic Mini\n");
        child.emit("exit", 1);
      });
      return child;
    }
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
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.stdout = new EventEmitter();
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", "[AVFoundation indev @ x] AVFoundation audio devices:\n[AVFoundation indev @ x] [1] DJI Mic Mini\n");
        child.emit("exit", 1);
      });
      return child;
    }
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
