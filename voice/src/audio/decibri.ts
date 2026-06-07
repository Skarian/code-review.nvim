import { createRequire } from "node:module";
import { createWriteStream } from "node:fs";
import { open, readFile } from "node:fs/promises";
import { spawn as nodeSpawn } from "node:child_process";
import { resolveAudioDevice } from "../devices.js";
import { helperError } from "../errors.js";

const require = createRequire(import.meta.url);
const FFMPEG_STOP_GRACE_MS = 1500;
const DEFAULT_PRE_ROLL_MS = 250;

function wavHeader(dataBytes: number, sampleRate: number, channels: number) {
  const header = Buffer.alloc(44);
  const byteRate = sampleRate * channels * 2;
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + dataBytes, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(channels * 2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(dataBytes, 40);
  return header;
}

async function waitForExit(closePromise: Promise<void>, timeoutMs: number) {
  let timeout: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      closePromise.then(() => true),
      new Promise<boolean>((resolve) => {
        timeout = setTimeout(() => resolve(false), timeoutMs);
      })
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function appendPreRoll(chunks: Buffer[], chunk: Buffer, maxBytes: number) {
  if (maxBytes <= 0) return;
  chunks.push(chunk);
  let total = chunks.reduce((sum, item) => sum + item.length, 0);
  while (total > maxBytes && chunks.length > 0) {
    const first = chunks[0];
    const overflow = total - maxBytes;
    if (overflow >= first.length) {
      chunks.shift();
      total -= first.length;
    } else {
      chunks[0] = first.subarray(overflow);
      total -= overflow;
    }
  }
}

function readyState() {
  let resolved = false;
  let resolveReady: () => void = () => {};
  let rejectReady: (error: any) => void = () => {};
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = () => {
      resolved = true;
      resolve();
    };
    rejectReady = (error: any) => {
      if (!resolved) reject(error);
    };
  });
  return {
    ready,
    isResolved() {
      return resolved;
    },
    resolveReady,
    rejectReady
  };
}

async function patchWav(path: string, audioBytes: number, sampleRate: number, channels: number) {
  const fd = await open(path, "r+");
  try {
    await fd.write(wavHeader(audioBytes, sampleRate, channels), 0, 44, 0);
  } finally {
    await fd.close();
  }
}

async function createFfmpegRecorder(options: any = {}): Promise<any> {
  const spawnImpl = options.spawnImpl || nodeSpawn;
  const platform = options.platform || process.platform;
  if (platform !== "darwin" && platform !== "win32") {
    return null;
  }
  const sampleRate = options.sampleRate ?? 16000;
  const channels = options.channels ?? 1;
  const bytesPerSecond = sampleRate * channels * 2;
  const preRollBytes = Math.floor(bytesPerSecond * (options.preRollMs ?? DEFAULT_PRE_ROLL_MS) / 1000);
  const stopGraceMs = options.stopGraceMs ?? FFMPEG_STOP_GRACE_MS;
  let out = options.out;
  const device = await resolveAudioDevice(options.audioDevice, { platform, spawnImpl });
  if (!device.ok && device.ok === false) {
    return { ok: false, error: device };
  }
  if (!device.selection) {
    return { ok: false, error: helperError("audio_device_unavailable", "No microphone input device is available.", false) };
  }

  let pendingError: any = null;
  let stderr = "";
  let stream: any = null;
  let audioBytes = 0;
  let recording = false;
  const preRollChunks: Buffer[] = [];
  const ready = readyState();
  const inputArgs = device.provider === "ffmpeg-dshow"
    ? ["-f", "dshow", "-i", `audio=${device.selection.audioDeviceName}`]
    : ["-f", "avfoundation", "-i", `:${device.selection.audioDeviceIndex ?? device.selection.audioDeviceName}`];
  const recorderFailureCode = device.trustedOpaqueId ? "AudioDeviceUnavailable" : "GenericFailure";
  const child = spawnImpl("ffmpeg", [
    "-loglevel",
    "error",
    ...inputArgs,
    "-ar",
    String(sampleRate),
    "-ac",
    String(channels),
    "-f",
    "s16le",
    "pipe:1"
  ], { stdio: ["ignore", "pipe", "pipe"] });

  child.stdout?.on?.("data", (chunk: Buffer) => {
    if (!ready.isResolved()) {
      ready.resolveReady();
    }
    if (recording && stream) {
      stream.write(chunk);
      audioBytes += chunk.length;
    } else {
      appendPreRoll(preRollChunks, Buffer.from(chunk), preRollBytes);
    }
  });
  child.stderr?.on?.("data", (chunk: Buffer | string) => {
    stderr += String(chunk);
  });
  child.once("error", (error: any) => {
    const code = error?.code === "ENOENT" ? "AudioProviderUnavailable" : recorderFailureCode;
    pendingError = Object.assign(error, { code });
    ready.rejectReady(pendingError);
  });

  let exited = false;
  const closePromise = new Promise<void>((resolve) => {
    child.once("exit", (code: number) => {
      exited = true;
      if (code && code !== 255 && !pendingError) {
        pendingError = Object.assign(new Error(stderr || "ffmpeg recording failed"), { code: recorderFailureCode });
      }
      if (pendingError) {
        ready.rejectReady(pendingError);
      }
      resolve();
    });
  });
  const forceStop = async () => {
    if (!exited) {
      child.kill("SIGKILL");
      await waitForExit(closePromise, stopGraceMs).catch(() => false);
    }
    if (stream) {
      stream.destroy?.();
      stream = null;
    }
  };

  return {
    ok: true,
    provider: device.provider,
    device,
    ready() {
      return ready.ready;
    },
    async start(startOut?: string) {
      out = startOut || out;
      if (!out) {
        throw Object.assign(new Error("missing output path"), { code: "InvalidArguments" });
      }
      if (recording) return;
      audioBytes = 0;
      stream = createWriteStream(out, { flags: "w" });
      stream.write(wavHeader(0, sampleRate, channels));
      const preRoll = Buffer.concat(preRollChunks);
      if (preRoll.length > 0) {
        stream.write(preRoll);
        audioBytes += preRoll.length;
      }
      recording = true;
    },
    error() {
      return pendingError;
    },
    forceStop,
    async stop() {
      recording = false;
      if (!exited) {
        child.kill("SIGINT");
        const stopped = await waitForExit(closePromise, stopGraceMs);
        if (!stopped) {
          await forceStop();
        }
      }
      if (stream) {
        await new Promise<void>((resolve, reject) => {
          stream.end((error: Error | null | undefined) => error ? reject(error) : resolve());
        });
        await patchWav(out, audioBytes, sampleRate, channels);
        stream = null;
      }
      const wav = out ? await readFile(out).catch(() => Buffer.alloc(44)) : Buffer.alloc(44);
      return { wav, audioBytes };
    }
  };
}

export async function createRecorder(options: any = {}): Promise<any> {
  const ffmpeg = await createFfmpegRecorder(options);
  if (ffmpeg) return ffmpeg;
  let Decibri;
  try {
    Decibri = require("decibri");
  } catch {
    return { ok: false, error: helperError("audio_provider_unavailable", "Audio provider unavailable. Rebuild voice helper or check platform support.", false) };
  }
  const sampleRate = options.sampleRate ?? 16000;
  const channels = options.channels ?? 1;
  const bytesPerSecond = sampleRate * channels * 2;
  const preRollBytes = Math.floor(bytesPerSecond * (options.preRollMs ?? DEFAULT_PRE_ROLL_MS) / 1000);
  let out = options.out;
  let mic;
  try {
    mic = new Decibri({ sampleRate, channels, format: "int16" });
  } catch (error: any) {
    return { ok: false, error: helperError("audio_provider_unavailable", "Audio provider unavailable. Rebuild voice helper or check platform support.", false, { reason: error?.code || error?.name }) };
  }
  const chunks: Buffer[] = [];
  const preRollChunks: Buffer[] = [];
  let audioBytes = 0;
  let stream: any = null;
  let recording = false;
  const ready = readyState();
  mic.on("data", (chunk: Buffer) => {
    if (!ready.isResolved()) {
      ready.resolveReady();
    }
    if (recording && stream) {
      chunks.push(chunk);
      audioBytes += chunk.length;
      stream.write(chunk);
    } else {
      appendPreRoll(preRollChunks, Buffer.from(chunk), preRollBytes);
    }
  });
  let pendingError = null;
  mic.on("error", (error: any) => {
    pendingError = error;
    ready.rejectReady(error);
  });
  return {
    ok: true,
    ready() {
      return ready.ready;
    },
    async start(startOut?: string) {
      out = startOut || out;
      if (!out) {
        throw Object.assign(new Error("missing output path"), { code: "InvalidArguments" });
      }
      if (recording) return;
      stream = createWriteStream(out, { flags: "w" });
      stream.write(wavHeader(0, sampleRate, channels));
      const preRoll = Buffer.concat(preRollChunks);
      if (preRoll.length > 0) {
        chunks.push(preRoll);
        audioBytes += preRoll.length;
        stream.write(preRoll);
      }
      recording = true;
    },
    error() {
      return pendingError;
    },
    async forceStop() {
      try {
        mic.stop();
      } catch {
      }
      if (stream) {
        stream.destroy?.();
      }
    },
    async stop() {
      recording = false;
      mic.stop();
      if (stream) {
        await new Promise<void>((resolve, reject) => {
          stream.end((error: Error | null | undefined) => error ? reject(error) : resolve());
        });
        await patchWav(out, audioBytes, sampleRate, channels);
      }
      return { wav: Buffer.concat([wavHeader(audioBytes, sampleRate, channels), ...chunks]), audioBytes };
    }
  };
}
