import { unlink } from "node:fs/promises";
import { helperError, printJson } from "./errors.js";
import { createRecorder } from "./audio/decibri.js";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function recordCommand(args: string[], stdin: any = process.stdin, options: any = {}): Promise<any> {
  const outIndex = args.indexOf("--out");
  const maxIndex = args.indexOf("--max-ms");
  const minIndex = args.indexOf("--min-duration-ms");
  const out = outIndex >= 0 ? args[outIndex + 1] : null;
  const maxMs = maxIndex >= 0 ? Number(args[maxIndex + 1]) : 60000;
  const minDurationMs = minIndex >= 0 ? Number(args[minIndex + 1]) : (options.minDurationMs ?? 900);
  if (!out || !Number.isFinite(maxMs) || !Number.isFinite(minDurationMs)) {
    return helperError("invalid_arguments", "Invalid record arguments.", false);
  }
  const recorder = await (options.createRecorder || createRecorder)({ out });
  if (!recorder.ok) {
    return recorder.error;
  }
  await sleep(50);
  const startupError = recorder.error?.();
  if (startupError) {
    return helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: startupError.code || startupError.name });
  }
  const emitJson = options.printJson || printJson;
  emitJson({ ok: true, event: "recording_started" });
  const started = Date.now();
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value: any) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      stdin.off?.("data", onData);
      stdin.pause?.();
      resolve(value);
    };
    const timer = setTimeout(async () => {
      try {
        await recorder.stop();
      } catch {
      }
      finish(helperError("timeout", "Recording timed out.", true));
    }, maxMs);
    stdin.setEncoding("utf8");
    const onData = async (chunk: Buffer | string) => {
      if (String(chunk).includes("discard")) {
        try {
          await recorder.stop();
        } catch {
        }
        await unlink(out).catch(() => {});
        finish({ ok: true, event: "discarded" });
      } else if (String(chunk).includes("stop")) {
        const recorderError = recorder.error?.();
        if (recorderError) {
          finish(helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: recorderError.code || recorderError.name }));
          return;
        }
        const durationMillis = Date.now() - started;
        if (durationMillis < minDurationMs) {
          try {
            await recorder.stop();
          } catch {
          }
          await unlink(out).catch(() => {});
          finish({ ok: true, event: "recording_too_short", message: "Recording was too short.", durationMillis });
          return;
        }
        const stopped = await recorder.stop();
        finish({ ok: true, event: "recording_stopped", durationMillis, audioBytes: stopped.audioBytes, mimeType: "audio/wav" });
      }
    };
    stdin.on("data", onData);
  });
}
