import { createRequire } from "node:module";
import { createWriteStream } from "node:fs";
import { open, readFile, stat } from "node:fs/promises";
import { spawn as nodeSpawn } from "node:child_process";
import { helperError } from "../errors.js";

const require = createRequire(import.meta.url);
const FFMPEG_STOP_GRACE_MS = 1500;

function commandExists(command: string, spawnImpl: any = nodeSpawn): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawnImpl(command, ["-version"], { stdio: "ignore" });
    child.once("error", () => resolve(false));
    child.once("exit", (code: number) => resolve(code === 0));
  });
}

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

async function createFfmpegRecorder(options: any = {}): Promise<any> {
  const spawnImpl = options.spawnImpl || nodeSpawn;
  const platform = options.platform || process.platform;
  const commandExistsImpl = options.commandExistsImpl || ((command: string) => commandExists(command, spawnImpl));
  if (platform !== "darwin" || !await commandExistsImpl("ffmpeg")) {
    return null;
  }
  const sampleRate = options.sampleRate ?? 16000;
  const channels = options.channels ?? 1;
  const out = options.out;
  const stopGraceMs = options.stopGraceMs ?? FFMPEG_STOP_GRACE_MS;
  if (!out) return null;
  let pendingError: any = null;
  let stderr = "";
  const child = spawnImpl("ffmpeg", [
    "-y",
    "-loglevel",
    "error",
    "-f",
    "avfoundation",
    "-i",
    ":0",
    "-ar",
    String(sampleRate),
    "-ac",
    String(channels),
    "-f",
    "wav",
    out
  ], { stdio: ["ignore", "ignore", "pipe"] });
  child.stderr?.on?.("data", (chunk: Buffer | string) => {
    stderr += String(chunk);
  });
  child.once("error", (error: Error) => {
    pendingError = error;
  });
  let exited = false;
  const closePromise = new Promise<void>((resolve) => {
    child.once("exit", (code: number) => {
      exited = true;
      if (code && code !== 255 && !pendingError) {
        pendingError = Object.assign(new Error(stderr || "ffmpeg recording failed"), { code: "GenericFailure" });
      }
      resolve();
    });
  });
  const forceStop = async () => {
    if (!exited) {
      child.kill("SIGKILL");
      await waitForExit(closePromise, stopGraceMs).catch(() => false);
    }
  };
  return {
    ok: true,
    provider: "ffmpeg-avfoundation",
    error() {
      return pendingError;
    },
    forceStop,
    async stop() {
      if (!exited) {
        child.kill("SIGINT");
        const stopped = await waitForExit(closePromise, stopGraceMs);
        if (!stopped) {
          await forceStop();
        }
      }
      const info = await stat(out).catch(() => ({ size: 0 }));
      const wav = await readFile(out).catch(() => Buffer.alloc(44));
      return { wav, audioBytes: Math.max(0, info.size - 44) };
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
  const out = options.out;
  let mic;
  try {
    mic = new Decibri({ sampleRate, channels, format: "int16" });
  } catch (error: any) {
    return { ok: false, error: helperError("audio_provider_unavailable", "Audio provider unavailable. Rebuild voice helper or check platform support.", false, { reason: error?.code || error?.name }) };
  }
  const chunks: Buffer[] = [];
  let audioBytes = 0;
  let stream: any = null;
  if (out) {
    stream = createWriteStream(out, { flags: "w" });
    stream.write(wavHeader(0, sampleRate, channels));
  }
  mic.on("data", (chunk: Buffer) => {
    chunks.push(chunk);
    audioBytes += chunk.length;
    if (stream) {
      stream.write(chunk);
    }
  });
  let pendingError = null;
  mic.on("error", (error: any) => {
    pendingError = error;
  });
  return {
    ok: true,
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
      mic.stop();
      if (stream) {
        await new Promise<void>((resolve, reject) => {
          stream.end((error: Error | null | undefined) => error ? reject(error) : resolve());
        });
        const fd = await open(out, "r+");
        try {
          await fd.write(wavHeader(audioBytes, sampleRate, channels), 0, 44, 0);
        } finally {
          await fd.close();
        }
      }
      return { wav: Buffer.concat([wavHeader(audioBytes, sampleRate, channels), ...chunks]), audioBytes };
    }
  };
}
