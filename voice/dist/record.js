import { unlink } from "node:fs/promises";
import { helperError, printJson } from "./errors.js";
import { createRecorder } from "./audio/decibri.js";
const RECORDER_STOP_TIMEOUT_MS = 2000;
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
async function stopRecorder(recorder, timeoutMs) {
    let timeout;
    try {
        return await Promise.race([
            recorder.stop(),
            new Promise((resolve) => {
                timeout = setTimeout(async () => {
                    await recorder.forceStop?.().catch?.(() => { });
                    resolve(helperError("timeout", "Recording stop timed out.", true));
                }, timeoutMs);
            })
        ]);
    }
    catch (error) {
        await recorder.forceStop?.().catch?.(() => { });
        return helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: error?.code || error?.name });
    }
    finally {
        if (timeout)
            clearTimeout(timeout);
    }
}
export async function recordCommand(args, stdin = process.stdin, options = {}) {
    const outIndex = args.indexOf("--out");
    const maxIndex = args.indexOf("--max-ms");
    const minIndex = args.indexOf("--min-duration-ms");
    const out = outIndex >= 0 ? args[outIndex + 1] : null;
    const maxMs = maxIndex >= 0 ? Number(args[maxIndex + 1]) : 60000;
    const minDurationMs = minIndex >= 0 ? Number(args[minIndex + 1]) : (options.minDurationMs ?? 900);
    const stopTimeoutMs = options.stopTimeoutMs ?? RECORDER_STOP_TIMEOUT_MS;
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
        await recorder.forceStop?.().catch?.(() => { });
        return helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: startupError.code || startupError.name });
    }
    const emitJson = options.printJson || printJson;
    emitJson({ ok: true, event: "recording_started" });
    const started = Date.now();
    return new Promise((resolve) => {
        let settled = false;
        const finish = (value) => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            stdin.off?.("data", onData);
            stdin.pause?.();
            resolve(value);
        };
        const timer = setTimeout(async () => {
            await stopRecorder(recorder, stopTimeoutMs);
            finish(helperError("timeout", "Recording timed out.", true));
        }, maxMs);
        stdin.setEncoding("utf8");
        const onData = async (chunk) => {
            if (settled)
                return;
            if (String(chunk).includes("discard")) {
                await stopRecorder(recorder, stopTimeoutMs);
                await unlink(out).catch(() => { });
                finish({ ok: true, event: "discarded" });
            }
            else if (String(chunk).includes("stop")) {
                const recorderError = recorder.error?.();
                if (recorderError) {
                    await recorder.forceStop?.().catch?.(() => { });
                    finish(helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: recorderError.code || recorderError.name }));
                    return;
                }
                const durationMillis = Date.now() - started;
                if (durationMillis < minDurationMs) {
                    await stopRecorder(recorder, stopTimeoutMs);
                    await unlink(out).catch(() => { });
                    finish({ ok: true, event: "recording_too_short", message: "Recording was too short.", durationMillis });
                    return;
                }
                const stopped = await stopRecorder(recorder, stopTimeoutMs);
                if (stopped && stopped.ok === false) {
                    finish(stopped);
                    return;
                }
                finish({ ok: true, event: "recording_stopped", durationMillis, audioBytes: stopped.audioBytes, mimeType: "audio/wav" });
            }
        };
        stdin.on("data", onData);
    });
}
