import { unlink } from "node:fs/promises";
import { helperError, printJson } from "./errors.js";
import { createRecorder } from "./audio/decibri.js";
const RECORDER_STOP_TIMEOUT_MS = 2000;
const DEFAULT_PRE_ROLL_MS = 250;
function recorderFailure(error) {
    if (error?.code === "AudioDeviceUnavailable") {
        return helperError("audio_device_unavailable", "Selected microphone is unavailable or could not be opened. Choose a microphone with :CodeReviewVoiceDevices.", false, { reason: error?.code || error?.name });
    }
    if (error?.code === "AudioProviderUnavailable") {
        return helperError("audio_provider_unavailable", "Audio provider unavailable. Rebuild voice helper or check platform support.", false, { reason: error?.code || error?.name });
    }
    return helperError("recording_permission_denied", "Microphone recording failed or permission was denied.", false, { reason: error?.code || error?.name });
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
        return recorderFailure(error);
    }
    finally {
        if (timeout)
            clearTimeout(timeout);
    }
}
function parseRecordArgs(args, options) {
    const outIndex = args.indexOf("--out");
    const maxIndex = args.indexOf("--max-ms");
    const minIndex = args.indexOf("--min-duration-ms");
    const deviceIndex = args.indexOf("--audio-device");
    const preRollIndex = args.indexOf("--pre-roll-ms");
    const out = outIndex >= 0 ? args[outIndex + 1] : null;
    const maxMs = maxIndex >= 0 ? Number(args[maxIndex + 1]) : 60000;
    const minDurationMs = minIndex >= 0 ? Number(args[minIndex + 1]) : (options.minDurationMs ?? 900);
    const audioDevice = deviceIndex >= 0 ? args[deviceIndex + 1] : (options.audioDevice ?? null);
    const preRollMs = preRollIndex >= 0 ? Number(args[preRollIndex + 1]) : (options.preRollMs ?? DEFAULT_PRE_ROLL_MS);
    const prearm = args.includes("--prearm") || options.prearm === true;
    const invalid = !out
        || !Number.isFinite(maxMs)
        || !Number.isFinite(minDurationMs)
        || !Number.isFinite(preRollMs)
        || (deviceIndex >= 0 && !audioDevice);
    return { invalid, out, maxMs, minDurationMs, audioDevice, preRollMs, prearm };
}
async function waitForReady(recorder) {
    if (recorder.ready) {
        await recorder.ready();
    }
    const startupError = recorder.error?.();
    if (startupError) {
        throw startupError;
    }
}
async function startRecorder(recorder, out, preRollMs) {
    if (recorder.start) {
        await recorder.start(out, preRollMs);
    }
}
function activeRecordingSession(opts) {
    const { stdin, recorder, out, maxMs, minDurationMs, stopTimeoutMs, started, minPeak } = opts;
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
                    finish(recorderFailure(recorderError));
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
                const level = audioLevel(stopped.wav);
                if (stopped.audioBytes <= 0 || level.peak <= minPeak) {
                    await unlink(out).catch(() => { });
                    finish(helperError("empty_recording", "Selected microphone produced no usable speech. Choose a microphone with :CodeReviewVoiceDevices.", false, { audioBytes: stopped.audioBytes, peak: level.peak }));
                    return;
                }
                finish({ ok: true, event: "recording_stopped", durationMillis, audioBytes: stopped.audioBytes, mimeType: "audio/wav" });
            }
        };
        stdin.on("data", onData);
    });
}
async function oneShotRecord(opts) {
    const { args, stdin, options, parsed } = opts;
    const stopTimeoutMs = options.stopTimeoutMs ?? RECORDER_STOP_TIMEOUT_MS;
    const recorder = await (options.createRecorder || createRecorder)({
        out: parsed.out,
        audioDevice: parsed.audioDevice,
        preRollMs: parsed.preRollMs,
        spawnImpl: options.spawnImpl,
        platform: options.platform,
        stopGraceMs: options.stopGraceMs,
        sampleRate: options.sampleRate,
        channels: options.channels
    });
    if (!recorder.ok) {
        return recorder.error;
    }
    try {
        await waitForReady(recorder);
        await startRecorder(recorder, parsed.out, parsed.preRollMs);
    }
    catch (error) {
        await recorder.forceStop?.().catch?.(() => { });
        return recorderFailure(error);
    }
    const emitJson = options.printJson || printJson;
    emitJson({ ok: true, event: "recording_started" });
    return activeRecordingSession({
        stdin,
        recorder,
        out: parsed.out,
        maxMs: parsed.maxMs,
        minDurationMs: parsed.minDurationMs,
        stopTimeoutMs,
        started: Date.now(),
        minPeak: options.minPeak ?? 64
    });
}
async function prearmedRecord(opts) {
    const { stdin, options, parsed } = opts;
    const stopTimeoutMs = options.stopTimeoutMs ?? RECORDER_STOP_TIMEOUT_MS;
    const emitJson = options.printJson || printJson;
    const recorder = await (options.createRecorder || createRecorder)({
        out: parsed.out,
        audioDevice: parsed.audioDevice,
        preRollMs: parsed.preRollMs,
        spawnImpl: options.spawnImpl,
        platform: options.platform,
        stopGraceMs: options.stopGraceMs,
        sampleRate: options.sampleRate,
        channels: options.channels
    });
    if (!recorder.ok) {
        return recorder.error;
    }
    return new Promise((resolve) => {
        let settled = false;
        let ready = false;
        let started = false;
        let startRequested = false;
        let activeSessionStarted = false;
        const finish = (value) => {
            if (settled)
                return;
            settled = true;
            stdin.off?.("data", onData);
            stdin.pause?.();
            resolve(value);
        };
        const beginStart = async () => {
            if (settled || started)
                return;
            if (!ready) {
                startRequested = true;
                return;
            }
            started = true;
            try {
                await startRecorder(recorder, parsed.out, parsed.preRollMs);
            }
            catch (error) {
                await recorder.forceStop?.().catch?.(() => { });
                finish(recorderFailure(error));
                return;
            }
            emitJson({ ok: true, event: "recording_started" });
            activeSessionStarted = true;
            activeRecordingSession({
                stdin,
                recorder,
                out: parsed.out,
                maxMs: parsed.maxMs,
                minDurationMs: parsed.minDurationMs,
                stopTimeoutMs,
                started: Date.now(),
                minPeak: options.minPeak ?? 64
            }).then(finish);
        };
        const onData = async (chunk) => {
            if (settled || activeSessionStarted)
                return;
            const text = String(chunk);
            if (text.includes("discard")) {
                await recorder.forceStop?.().catch?.(() => { });
                await unlink(parsed.out).catch(() => { });
                finish({ ok: true, event: "discarded" });
            }
            else if (text.includes("start")) {
                await beginStart();
            }
        };
        stdin.setEncoding("utf8");
        stdin.on("data", onData);
        waitForReady(recorder).then(async () => {
            if (settled)
                return;
            ready = true;
            emitJson({ ok: true, event: "recording_ready" });
            if (startRequested) {
                await beginStart();
            }
        }).catch(async (error) => {
            await recorder.forceStop?.().catch?.(() => { });
            finish(recorderFailure(error));
        });
    });
}
export async function recordCommand(args, stdin = process.stdin, options = {}) {
    const parsed = parseRecordArgs(args, options);
    if (parsed.invalid) {
        return helperError("invalid_arguments", "Invalid record arguments.", false);
    }
    if (parsed.prearm) {
        return prearmedRecord({ args, stdin, options, parsed });
    }
    return oneShotRecord({ args, stdin, options, parsed });
}
function audioLevel(wav) {
    if (!Buffer.isBuffer(wav) || wav.length <= 44) {
        return { peak: 0 };
    }
    let peak = 0;
    for (let offset = 44; offset + 1 < wav.length; offset += 2) {
        peak = Math.max(peak, Math.abs(wav.readInt16LE(offset)));
    }
    return { peak };
}
