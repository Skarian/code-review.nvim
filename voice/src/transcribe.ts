import { readFile, stat } from "node:fs/promises";
import { helperError } from "./errors.js";

export async function transcribeFile(input: string, credentials: any, options: any = {}): Promise<any> {
  const maxAudioBytes = options.maxAudioBytes ?? 16 * 1024 * 1024;
  const endpoint = options.endpoint || "https://chatgpt.com/backend-api/transcribe";
  const fetchImpl = options.fetch || globalThis.fetch;
  let timeout: NodeJS.Timeout | undefined;
  let controller: AbortController | undefined;
  let signal = options.signal;
  if (!signal && options.timeoutMs) {
    controller = new AbortController();
    signal = controller.signal;
  }
  const info = await stat(input);
  if (info.size > maxAudioBytes) {
    return helperError("audio_too_large", "Recording is too large to transcribe.", false);
  }
  const bytes = await readFile(input);
  const makeForm = () => {
    const form = new FormData();
    form.append("file", new Blob([bytes], { type: "audio/wav" }), "recording.wav");
    return form;
  };
  const headers = {
    authorization: `Bearer ${credentials.accessToken}`,
    "user-agent": "code-review.nvim-voice"
  };
  if (credentials.accountId) headers["ChatGPT-Account-Id"] = credentials.accountId;
  let response;
  try {
    if (signal?.aborted) {
      return helperError("timeout", "ChatGPT transcription request timed out.", true);
    }
    if (controller && options.timeoutMs) {
      timeout = setTimeout(() => controller.abort(), options.timeoutMs);
    }
    for (let attempt = 0; attempt < 2; attempt++) {
      response = await fetchImpl(endpoint, { method: "POST", headers, body: makeForm(), signal });
      if (response.status !== 403 || response.headers?.get?.("cf-mitigated") !== "challenge" || attempt > 0) {
        break;
      }
      await response.arrayBuffer?.().catch(() => {});
    }
  } catch (error: any) {
    if (error && error.name === "AbortError") {
      return helperError("timeout", "ChatGPT transcription request timed out.", true);
    }
    return helperError("network_error", "Could not reach ChatGPT transcription endpoint.", true);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
  if (response.status === 401) {
    return helperError("codex_auth_expired", "Codex auth token expired, please login to codex.", false);
  }
  if (response.status === 403) {
    return helperError("http_error", "ChatGPT transcription endpoint rejected this account or client.", false, { status: 403 });
  }
  if (!response.ok) {
    return helperError("http_error", "ChatGPT transcription request failed.", response.status === 408 || response.status === 429 || response.status >= 500, { status: response.status });
  }
  let json;
  try {
    json = await response.json();
  } catch {
    return helperError("invalid_response", "ChatGPT transcription response was invalid.", false);
  }
  if (typeof json.text !== "string") {
    return helperError("invalid_response", "ChatGPT transcription response did not include text.", false);
  }
  if (json.text.trim() === "") {
    return helperError("empty_transcript", "No speech was transcribed.", false);
  }
  return {
    ok: true,
    text: json.text,
    audioBytes: bytes.length,
    durationMillis: options.durationMillis ?? null,
    model: typeof json.model === "string" ? json.model : null,
    source: "chatgpt"
  };
}
