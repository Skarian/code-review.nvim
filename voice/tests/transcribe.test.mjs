import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { transcribeFile } from "../dist/transcribe.js";

async function wav(size = 44) {
  const dir = await mkdtemp(join(tmpdir(), "cr-wav-"));
  const file = join(dir, "recording.wav");
  await writeFile(file, Buffer.alloc(size));
  return file;
}

test("transcribe posts audio with ChatGPT auth", async () => {
  const input = await wav();
  let seen;
  const result = await transcribeFile(input, { accessToken: "token", accountId: "acct" }, {
    fetch: async (url, init) => {
      seen = { url, init };
      return { ok: true, status: 200, json: async () => ({ text: "hello", model: "whisper-test" }) };
    }
  });
  assert.equal(result.ok, true);
  assert.equal(result.text, "hello");
  assert.equal(result.audioBytes, 44);
  assert.equal(result.model, "whisper-test");
  assert.equal(result.source, "chatgpt");
  assert.equal(seen.url, "https://chatgpt.com/backend-api/transcribe");
  assert.equal(seen.init.headers.authorization, "Bearer token");
  assert.equal(seen.init.headers["user-agent"], "code-review.nvim-voice");
  assert.equal(seen.init.headers["ChatGPT-Account-Id"], "acct");
});

test("maps 401 to expired codex auth", async () => {
  const input = await wav();
  const result = await transcribeFile(input, { accessToken: "token" }, {
    fetch: async () => ({ ok: false, status: 401 })
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "codex_auth_expired");
});

test("retries a single Cloudflare edge challenge", async () => {
  const input = await wav();
  let calls = 0;
  const result = await transcribeFile(input, { accessToken: "token" }, {
    fetch: async () => {
      calls += 1;
      if (calls === 1) {
        return {
          ok: false,
          status: 403,
          headers: { get: (name) => name === "cf-mitigated" ? "challenge" : null },
          arrayBuffer: async () => new ArrayBuffer(0)
        };
      }
      return { ok: true, status: 200, json: async () => ({ text: "retried" }) };
    }
  });
  assert.equal(result.ok, true);
  assert.equal(result.text, "retried");
  assert.equal(calls, 2);
});

test("rejects over-large audio before upload", async () => {
  const input = await wav(8);
  const result = await transcribeFile(input, { accessToken: "token" }, { maxAudioBytes: 4 });
  assert.equal(result.ok, false);
  assert.equal(result.code, "audio_too_large");
});

test("maps aborted transcription to timeout", async () => {
  const input = await wav();
  const result = await transcribeFile(input, { accessToken: "token" }, {
    timeoutMs: 1,
    fetch: async (_url, init) => new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => {
        const error = new Error("aborted");
        error.name = "AbortError";
        reject(error);
      });
    })
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, "timeout");
  assert.equal(result.retryable, true);
});

test("maps empty and invalid transcription responses", async () => {
  const input = await wav();
  const empty = await transcribeFile(input, { accessToken: "token" }, {
    fetch: async () => ({ ok: true, status: 200, json: async () => ({ text: "  " }) })
  });
  assert.equal(empty.ok, false);
  assert.equal(empty.code, "empty_transcript");

  const invalid = await transcribeFile(input, { accessToken: "token" }, {
    fetch: async () => ({ ok: true, status: 200, json: async () => ({}) })
  });
  assert.equal(invalid.ok, false);
  assert.equal(invalid.code, "invalid_response");
});
