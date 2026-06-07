import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFile, unlink } from "node:fs/promises";
import {
  classifyDevice,
  listAudioDevices,
  parseAvfoundationDevices,
  parseDshowDevices,
  recommendedDevice,
  resolveAudioDevice
} from "../dist/devices.js";
import { createRecorder } from "../dist/audio/decibri.js";

const avfoundationSample = `
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] ZoomAudioDevice
[AVFoundation indev @ 0x1] [1] DJI Mic Mini-57B7DE
[AVFoundation indev @ 0x1] [2] MacBook Pro Microphone
`;

const dshowSample = `
[dshow @ 000001] DirectShow video devices (some may be both video and audio devices)
[dshow @ 000001]  "Integrated Camera"
[dshow @ 000001] DirectShow audio devices
[dshow @ 000001]  "Microphone (Realtek(R) Audio)"
[dshow @ 000001]     Alternative name "@device_cm_{abc}"
[dshow @ 000001]  "ZoomAudioDevice"
`;

function spawnForList(stderrText) {
  return () => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    process.nextTick(() => {
      child.stderr.emit("data", stderrText);
      child.emit("exit", 1);
    });
    return child;
  };
}

test("parses and ranks AVFoundation microphones without choosing virtual index zero", () => {
  const devices = parseAvfoundationDevices(avfoundationSample);
  assert.equal(devices.length, 3);
  assert.equal(devices[0].name, "ZoomAudioDevice");
  assert.equal(devices[0].virtuality, "likely_virtual");
  const recommended = recommendedDevice(devices);
  assert.equal(recommended.name, "DJI Mic Mini-57B7DE");
  assert.equal(recommended.index, 1);
});

test("parses DirectShow microphones and alternative names", () => {
  const devices = parseDshowDevices(dshowSample);
  assert.equal(devices.length, 2);
  assert.equal(devices[0].name, "Microphone (Realtek(R) Audio)");
  assert.equal(devices[0].selection.alternativeName, "@device_cm_{abc}");
  assert.equal(devices[1].virtuality, "likely_virtual");
});

test("lists macOS devices with default and recommended selections", async () => {
  const result = await listAudioDevices({ platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(result.ok, true);
  assert.equal(result.devices[0].id, "ffmpeg-avfoundation:audio:default");
  assert.equal(result.defaultSelection.id, "ffmpeg-avfoundation:audio:default");
  assert.equal(result.recommendedSelection.id, "ffmpeg-avfoundation:audio:1");
});

test("resolves implicit macOS recording to recommended physical device before default", async () => {
  const implicit = await resolveAudioDevice(null, { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(implicit.id, "ffmpeg-avfoundation:audio:1");
  assert.equal(implicit.name, "DJI Mic Mini-57B7DE");

  const explicitDefault = await resolveAudioDevice("ffmpeg-avfoundation:audio:default", { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(explicitDefault.id, "ffmpeg-avfoundation:audio:default");
  assert.equal(explicitDefault.selection.audioDeviceName, "default");

  const onlyDefault = await resolveAudioDevice(null, { platform: "darwin", spawnImpl: spawnForList("[AVFoundation indev @ 0x1] AVFoundation audio devices:\n") });
  assert.equal(onlyDefault.id, "ffmpeg-avfoundation:audio:default");
});

test("resolves trusted opaque IDs without listing and legacy hints with listing", async () => {
  let listed = false;
  const byId = await resolveAudioDevice("ffmpeg-avfoundation:audio:1", {
    platform: "darwin",
    spawnImpl: () => {
      listed = true;
      throw new Error("should not list devices for trusted opaque IDs");
    }
  });
  assert.equal(byId.id, "ffmpeg-avfoundation:audio:1");
  assert.equal(byId.selection.audioDeviceIndex, 1);
  assert.equal(byId.trustedOpaqueId, true);
  assert.equal(listed, false);

  const byName = await resolveAudioDevice("MacBook Pro Microphone", { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(byName.id, "ffmpeg-avfoundation:audio:2");

  const byIndex = await resolveAudioDevice("1", { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(byIndex.name, "DJI Mic Mini-57B7DE");
});

test("reports unavailable legacy and invalid explicit devices", async () => {
  const result = await resolveAudioDevice("Missing Mic", { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(result.ok, false);
  assert.equal(result.code, "audio_device_unavailable");

  const invalid = await resolveAudioDevice("ffmpeg-avfoundation:audio:not-a-number", { platform: "darwin", spawnImpl: spawnForList(avfoundationSample) });
  assert.equal(invalid.ok, false);
  assert.equal(invalid.code, "audio_device_unavailable");
});

test("resolves DirectShow opaque IDs without listing", async () => {
  let listed = false;
  const result = await resolveAudioDevice("ffmpeg-dshow:audio:%40device_cm_%7Babc%7D", {
    platform: "win32",
    spawnImpl: () => {
      listed = true;
      throw new Error("should not list devices for trusted opaque IDs");
    }
  });
  assert.equal(result.ok, undefined);
  assert.equal(result.trustedOpaqueId, true);
  assert.equal(result.selection.audioDeviceName, "@device_cm_{abc}");
  assert.equal(listed, false);
});

test("classifies virtual microphones as advisory only", () => {
  assert.equal(classifyDevice("ZoomAudioDevice").virtuality, "likely_virtual");
  assert.equal(classifyDevice("DJI Mic Mini-57B7DE").virtuality, "likely_physical");
  assert.equal(classifyDevice("Mystery Input").virtuality, "unknown");
});

test("ffmpeg recorder uses selected AVFoundation device instead of index zero", async () => {
  const seen = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    seen.push(args);
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", avfoundationSample);
        child.emit("exit", 1);
      });
      return child;
    }
    child.kill = (signal) => {
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
    audioDevice: "ffmpeg-avfoundation:audio:1",
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  assert.equal(seen.some((args) => args.includes("-list_devices")), false);
  const recordArgs = seen.find((args) => args.includes("avfoundation") && !args.includes("-list_devices"));
  assert.deepEqual(recordArgs.slice(recordArgs.indexOf("-i"), recordArgs.indexOf("-i") + 2), ["-i", ":1"]);
});

test("ffmpeg recorder becomes ready only after PCM and prepends pre-roll", async () => {
  const out = `/tmp/code-review-recorder-${process.pid}-${Date.now()}.wav`;
  let recordChild;
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    if (!args.includes("-list_devices")) {
      recordChild = child;
    }
    child.kill = (signal) => {
      if (signal === "SIGINT") {
        process.nextTick(() => child.emit("exit", 0));
      }
      return true;
    };
    return child;
  };

  const recorder = await createRecorder({
    out,
    platform: "darwin",
    commandExistsImpl: async () => true,
    spawnImpl,
    audioDevice: "ffmpeg-avfoundation:audio:1",
    sampleRate: 1000,
    channels: 1,
    preRollMs: 1000,
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);

  let resolved = false;
  const ready = recorder.ready().then(() => {
    resolved = true;
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(resolved, false);

  const preRoll = Buffer.from([0x00, 0x08, 0x00, 0x00]);
  const recorded = Buffer.from([0x00, 0x10, 0x00, 0x00]);
  recordChild.stdout.emit("data", preRoll);
  await ready;
  assert.equal(resolved, true);

  await recorder.start();
  recordChild.stdout.emit("data", recorded);
  const result = await recorder.stop();
  assert.equal(result.audioBytes, preRoll.length + recorded.length);
  const wav = await readFile(out);
  assert.equal(wav.toString("ascii", 0, 4), "RIFF");
  assert.deepEqual(wav.subarray(44, 44 + preRoll.length), preRoll);
  assert.deepEqual(wav.subarray(44 + preRoll.length, 44 + preRoll.length + recorded.length), recorded);
  await unlink(out).catch(() => {});
});

test("ffmpeg recorder maps direct spawn failure to provider unavailable", async () => {
  const spawnImpl = () => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    process.nextTick(() => {
      child.emit("error", Object.assign(new Error("missing ffmpeg"), { code: "ENOENT" }));
    });
    child.kill = () => true;
    return child;
  };

  const recorder = await createRecorder({
    out: "/tmp/missing-ffmpeg-spawn.wav",
    platform: "darwin",
    commandExistsImpl: async () => true,
    spawnImpl,
    audioDevice: "ffmpeg-avfoundation:audio:1",
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  await assert.rejects(
    () => recorder.ready(),
    (error) => error.code === "AudioProviderUnavailable"
  );
});

test("ffmpeg recorder uses recommended AVFoundation device when none is selected", async () => {
  const seen = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    seen.push(args);
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", avfoundationSample);
        child.emit("exit", 1);
      });
      return child;
    }
    child.kill = (signal) => {
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
  const recordArgs = seen.find((args) => args.includes("avfoundation") && !args.includes("-list_devices"));
  assert.deepEqual(recordArgs.slice(recordArgs.indexOf("-i"), recordArgs.indexOf("-i") + 2), ["-i", ":1"]);
});

test("ffmpeg recorder preserves explicit AVFoundation system default selection", async () => {
  const seen = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    seen.push(args);
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", avfoundationSample);
        child.emit("exit", 1);
      });
      return child;
    }
    child.kill = (signal) => {
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
    audioDevice: "ffmpeg-avfoundation:audio:default",
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  assert.equal(seen.some((args) => args.includes("-list_devices")), false);
  const recordArgs = seen.find((args) => args.includes("avfoundation") && !args.includes("-list_devices"));
  assert.deepEqual(recordArgs.slice(recordArgs.indexOf("-i"), recordArgs.indexOf("-i") + 2), ["-i", ":default"]);
});

test("ffmpeg recorder uses DirectShow opaque IDs without listing", async () => {
  const seen = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    seen.push(args);
    child.kill = (signal) => {
      if (signal === "SIGINT") {
        process.nextTick(() => child.emit("exit", 0));
      }
      return true;
    };
    return child;
  };

  const recorder = await createRecorder({
    out: "/tmp/missing-ffmpeg.wav",
    platform: "win32",
    commandExistsImpl: async () => true,
    spawnImpl,
    audioDevice: "ffmpeg-dshow:audio:%40device_cm_%7Babc%7D",
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  assert.equal(seen.some((args) => args.includes("-list_devices")), false);
  const recordArgs = seen.find((args) => args.includes("dshow") && !args.includes("-list_devices"));
  assert.deepEqual(recordArgs.slice(recordArgs.indexOf("-i"), recordArgs.indexOf("-i") + 2), ["-i", "audio=@device_cm_{abc}"]);
});

test("ffmpeg recorder uses DirectShow audio names on Windows", async () => {
  const seen = [];
  const spawnImpl = (_command, args) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    seen.push(args);
    if (args.includes("-list_devices")) {
      process.nextTick(() => {
        child.stderr.emit("data", dshowSample);
        child.emit("exit", 1);
      });
      return child;
    }
    child.kill = (signal) => {
      if (signal === "SIGINT") {
        process.nextTick(() => child.emit("exit", 0));
      }
      return true;
    };
    return child;
  };

  const recorder = await createRecorder({
    out: "/tmp/missing-ffmpeg.wav",
    platform: "win32",
    commandExistsImpl: async () => true,
    spawnImpl,
    audioDevice: "Microphone (Realtek(R) Audio)",
    stopGraceMs: 5
  });
  assert.equal(recorder.ok, true);
  const recordArgs = seen.find((args) => args.includes("dshow") && !args.includes("-list_devices"));
  assert.deepEqual(recordArgs.slice(recordArgs.indexOf("-i"), recordArgs.indexOf("-i") + 2), ["-i", "audio=Microphone (Realtek(R) Audio)"]);
});
