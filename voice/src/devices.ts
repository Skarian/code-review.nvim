import { spawn as nodeSpawn } from "node:child_process";
import { helperError } from "./errors.js";

const VIRTUAL_PATTERNS = [
  { pattern: /zoom/i, reason: "name_contains_zoom" },
  { pattern: /blackhole/i, reason: "name_contains_blackhole" },
  { pattern: /loopback/i, reason: "name_contains_loopback" },
  { pattern: /soundflower/i, reason: "name_contains_soundflower" },
  { pattern: /\bobs\b/i, reason: "name_contains_obs" },
  { pattern: /teams/i, reason: "name_contains_teams" },
  { pattern: /virtual/i, reason: "name_contains_virtual" },
  { pattern: /aggregate/i, reason: "name_contains_aggregate" }
];

const PHYSICAL_PATTERNS = [
  { pattern: /microphone/i, reason: "name_contains_microphone" },
  { pattern: /\bmic\b/i, reason: "name_contains_mic" },
  { pattern: /headset/i, reason: "name_contains_headset" },
  { pattern: /airpods/i, reason: "name_contains_airpods" },
  { pattern: /usb/i, reason: "name_contains_usb" },
  { pattern: /dji/i, reason: "name_contains_known_hardware" },
  { pattern: /shure/i, reason: "name_contains_known_hardware" },
  { pattern: /rode/i, reason: "name_contains_known_hardware" },
  { pattern: /blue/i, reason: "name_contains_known_hardware" }
];

function run(command: string, args: string[], spawnImpl: any = nodeSpawn): Promise<{ code: number | null, stdout: string, stderr: string }> {
  return new Promise((resolve) => {
    const child = spawnImpl(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on?.("data", (chunk: Buffer | string) => {
      stdout += String(chunk);
    });
    child.stderr?.on?.("data", (chunk: Buffer | string) => {
      stderr += String(chunk);
    });
    child.once("error", () => resolve({ code: null, stdout, stderr }));
    child.once("exit", (code: number | null) => resolve({ code, stdout, stderr }));
  });
}

export function classifyDevice(name: string): { virtuality: string, confidence: string, reasons: string[] } {
  const virtualReasons = VIRTUAL_PATTERNS.filter((item) => item.pattern.test(name)).map((item) => item.reason);
  if (virtualReasons.length > 0) {
    return { virtuality: "likely_virtual", confidence: "medium", reasons: virtualReasons };
  }
  const physicalReasons = PHYSICAL_PATTERNS.filter((item) => item.pattern.test(name)).map((item) => item.reason);
  if (physicalReasons.length > 0) {
    return { virtuality: "likely_physical", confidence: "medium", reasons: physicalReasons };
  }
  return { virtuality: "unknown", confidence: "low", reasons: [] };
}

function avfoundationDevice(index: number, name: string) {
  const classified = classifyDevice(name);
  return {
    id: `ffmpeg-avfoundation:audio:${index}`,
    provider: "ffmpeg-avfoundation",
    kind: "audioinput",
    index,
    name,
    ...classified,
    selection: { provider: "ffmpeg-avfoundation", audioDeviceIndex: index, audioDeviceName: name }
  };
}

function avfoundationDefaultDevice() {
  return {
    id: "ffmpeg-avfoundation:audio:default",
    provider: "ffmpeg-avfoundation",
    kind: "audioinput",
    index: null,
    name: "System Default",
    virtuality: "unknown",
    confidence: "medium",
    reasons: ["provider_default"],
    selection: { provider: "ffmpeg-avfoundation", audioDeviceName: "default" }
  };
}

function avfoundationOpaqueDevice(index: number) {
  return {
    id: `ffmpeg-avfoundation:audio:${index}`,
    provider: "ffmpeg-avfoundation",
    kind: "audioinput",
    index,
    name: `AVFoundation microphone ${index}`,
    virtuality: "unknown",
    confidence: "low",
    reasons: ["trusted_opaque_id"],
    trustedOpaqueId: true,
    selection: { provider: "ffmpeg-avfoundation", audioDeviceIndex: index }
  };
}

function avfoundationOpaqueDefaultDevice() {
  return {
    ...avfoundationDefaultDevice(),
    trustedOpaqueId: true,
    reasons: ["provider_default", "trusted_opaque_id"]
  };
}

function dshowDevice(name: string, alternativeName: string | null) {
  const stableName = alternativeName || name;
  const classified = classifyDevice(name);
  return {
    id: `ffmpeg-dshow:audio:${encodeURIComponent(stableName)}`,
    provider: "ffmpeg-dshow",
    kind: "audioinput",
    index: null,
    name,
    ...classified,
    selection: { provider: "ffmpeg-dshow", audioDeviceName: name, alternativeName }
  };
}

function dshowOpaqueDevice(stableName: string) {
  return {
    id: `ffmpeg-dshow:audio:${encodeURIComponent(stableName)}`,
    provider: "ffmpeg-dshow",
    kind: "audioinput",
    index: null,
    name: stableName,
    virtuality: "unknown",
    confidence: "low",
    reasons: ["trusted_opaque_id"],
    trustedOpaqueId: true,
    selection: { provider: "ffmpeg-dshow", audioDeviceName: stableName, alternativeName: stableName }
  };
}

export function parseAvfoundationDevices(text: string) {
  const devices = [];
  let inAudio = false;
  for (const line of text.split(/\r?\n/)) {
    if (line.includes("AVFoundation audio devices:")) {
      inAudio = true;
      continue;
    }
    if (line.includes("AVFoundation video devices:")) {
      inAudio = false;
      continue;
    }
    if (!inAudio) continue;
    const match = line.match(/\]\s+\[(\d+)\]\s+(.+)\s*$/);
    if (match) {
      devices.push(avfoundationDevice(Number(match[1]), match[2]));
    }
  }
  return devices;
}

export function parseDshowDevices(text: string) {
  const devices = [];
  let inAudio = false;
  let lastDevice: any = null;
  for (const line of text.split(/\r?\n/)) {
    if (line.includes("DirectShow audio devices")) {
      inAudio = true;
      continue;
    }
    if (line.includes("DirectShow video devices")) {
      inAudio = false;
      continue;
    }
    if (!inAudio) continue;
    const nameMatch = line.match(/]\s+"([^"]+)"\s*$/);
    if (nameMatch) {
      lastDevice = dshowDevice(nameMatch[1], null);
      devices.push(lastDevice);
      continue;
    }
    const altMatch = line.match(/Alternative name\s+"([^"]+)"/);
    if (altMatch && lastDevice) {
      lastDevice.id = `ffmpeg-dshow:audio:${encodeURIComponent(altMatch[1])}`;
      lastDevice.selection.alternativeName = altMatch[1];
    }
  }
  return devices;
}

function firstByVirtuality(devices: any[], virtuality: string) {
  return devices.find((device) => device.virtuality === virtuality && !device.reasons?.includes?.("provider_default")) || null;
}

export function recommendedDevice(devices: any[]) {
  return firstByVirtuality(devices, "likely_physical")
    || firstByVirtuality(devices, "unknown")
    || firstByVirtuality(devices, "likely_virtual")
    || null;
}

function selectionSummary(device: any, reason: string) {
  if (!device) return null;
  return { id: device.id, reason };
}

export function resolveOpaqueAudioDevice(value: string | null | undefined, platform: string = process.platform): any {
  if (!value) return null;
  if (value === "ffmpeg-avfoundation:audio:default") {
    if (platform !== "darwin") {
      return helperError("audio_device_unavailable", "Selected microphone is unavailable on this platform. Choose a microphone with :CodeReviewVoiceDevices.", false);
    }
    return avfoundationOpaqueDefaultDevice();
  }
  const avfoundationMatch = value.match(/^ffmpeg-avfoundation:audio:(\d+)$/);
  if (avfoundationMatch) {
    if (platform !== "darwin") {
      return helperError("audio_device_unavailable", "Selected microphone is unavailable on this platform. Choose a microphone with :CodeReviewVoiceDevices.", false);
    }
    return avfoundationOpaqueDevice(Number(avfoundationMatch[1]));
  }
  if (value.startsWith("ffmpeg-avfoundation:audio:")) {
    return helperError("audio_device_unavailable", "Selected microphone ID is invalid. Choose a microphone with :CodeReviewVoiceDevices.", false);
  }
  const dshowMatch = value.match(/^ffmpeg-dshow:audio:(.+)$/);
  if (dshowMatch) {
    if (platform !== "win32") {
      return helperError("audio_device_unavailable", "Selected microphone is unavailable on this platform. Choose a microphone with :CodeReviewVoiceDevices.", false);
    }
    let stableName = "";
    try {
      stableName = decodeURIComponent(dshowMatch[1]);
    } catch {
      return helperError("audio_device_unavailable", "Selected microphone ID is invalid. Choose a microphone with :CodeReviewVoiceDevices.", false);
    }
    if (!stableName) {
      return helperError("audio_device_unavailable", "Selected microphone ID is invalid. Choose a microphone with :CodeReviewVoiceDevices.", false);
    }
    return dshowOpaqueDevice(stableName);
  }
  if (value.startsWith("ffmpeg-dshow:audio:")) {
    return helperError("audio_device_unavailable", "Selected microphone ID is invalid. Choose a microphone with :CodeReviewVoiceDevices.", false);
  }
  return null;
}

export async function listAudioDevices(options: any = {}) {
  const platform = options.platform || process.platform;
  const spawnImpl = options.spawnImpl || nodeSpawn;
  if (platform === "darwin") {
    const result = await run("ffmpeg", ["-f", "avfoundation", "-list_devices", "true", "-i", ""], spawnImpl);
    if (result.code === null && result.stdout === "" && result.stderr === "") {
      return helperError("audio_provider_unavailable", "ffmpeg is not available for microphone device listing.", false);
    }
    const parsed = parseAvfoundationDevices(result.stderr + result.stdout);
    const devices = [avfoundationDefaultDevice(), ...parsed];
    const recommended = recommendedDevice(parsed);
    return {
      ok: true,
      platform,
      devices,
      defaultSelection: selectionSummary(devices[0], "provider_default"),
      recommendedSelection: selectionSummary(recommended, recommended ? "first likely physical device after skipping likely virtual devices" : "no audio devices found")
    };
  }
  if (platform === "win32") {
    const result = await run("ffmpeg", ["-list_devices", "true", "-f", "dshow", "-i", "dummy"], spawnImpl);
    if (result.code === null && result.stdout === "" && result.stderr === "") {
      return helperError("audio_provider_unavailable", "ffmpeg is not available for microphone device listing.", false);
    }
    const devices = parseDshowDevices(result.stderr + result.stdout);
    const recommended = recommendedDevice(devices);
    return {
      ok: true,
      platform,
      devices,
      defaultSelection: null,
      recommendedSelection: selectionSummary(recommended, recommended ? "first likely physical device after skipping likely virtual devices" : "no audio devices found")
    };
  }
  return { ok: true, platform, devices: [], defaultSelection: null, recommendedSelection: null };
}

export async function resolveAudioDevice(value: string | null | undefined, options: any = {}) {
  const platform = options.platform || process.platform;
  const opaque = resolveOpaqueAudioDevice(value, platform);
  if (opaque) return opaque;
  const listing: any = await listAudioDevices(options);
  if (listing.ok === false) return listing;
  const devices = listing.devices || [];
  if (value) {
    const matched = devices.find((device: any) => {
      return device.id === value
        || device.name === value
        || String(device.index) === value
        || device.selection?.audioDeviceName === value
        || device.selection?.alternativeName === value;
    });
    if (matched) return matched;
    return helperError("audio_device_unavailable", "Selected microphone is unavailable. Choose a microphone with :CodeReviewVoiceDevices.", false);
  }
  const recommendedId = listing.recommendedSelection?.id;
  if (recommendedId) {
    const matchedRecommended = devices.find((device: any) => device.id === recommendedId);
    if (matchedRecommended) return matchedRecommended;
  }
  const defaultId = listing.defaultSelection?.id;
  if (defaultId) {
    const matchedDefault = devices.find((device: any) => device.id === defaultId);
    if (matchedDefault) return matchedDefault;
  }
  return helperError("audio_device_unavailable", "No microphone input device is available.", false);
}
