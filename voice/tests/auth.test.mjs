import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { discoverCredentials } from "../dist/auth.js";

function jwt(exp) {
  const enc = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${enc({ alg: "none" })}.${enc({ exp })}.sig`;
}

function jwtPayload(payload) {
  const enc = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${enc({ alg: "none" })}.${enc(payload)}.sig`;
}

test("discovers first readable Codex auth file", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  await mkdir(codex);
  const file = join(codex, "auth.json");
  await writeFile(file, JSON.stringify({ auth_mode: "chatgpt", tokens: { access_token: jwt(2000000000), id_token: jwt(2000000000), account_id: "acct" } }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, true);
  assert.equal(result.file, file);
  assert.equal(result.accountId, "acct");
});

test("malformed first readable auth file is invalid and does not continue", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  const fallback = join(dir, ".codex");
  await mkdir(codex);
  await mkdir(fallback);
  await writeFile(join(codex, "auth.json"), "{");
  await writeFile(join(fallback, "auth.json"), JSON.stringify({ auth_mode: "chatgpt", tokens: { access_token: jwt(2000000000), id_token: jwt(2000000000) } }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_credentials");
  assert.equal(result.details, undefined);
});

test("expired access token asks user to login to codex", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  await mkdir(codex);
  await writeFile(join(codex, "auth.json"), JSON.stringify({ auth_mode: "chatgpt", tokens: { access_token: jwt(1000), id_token: jwt(2000000000) } }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, false);
  assert.equal(result.code, "codex_auth_expired");
  assert.equal(result.details, undefined);
});

test("expired optional id token does not block fresh access token", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  await mkdir(codex);
  await writeFile(join(codex, "auth.json"), JSON.stringify({
    auth_mode: "chatgpt",
    tokens: {
      access_token: jwtPayload({ exp: 2000000000 }),
      id_token: jwtPayload({ exp: 999, "https://api.openai.com/auth": { chatgpt_account_id: "acct-from-expired-id" } })
    }
  }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, true);
  assert.equal(result.accountId, "acct-from-expired-id");
});

test("rejects non auth_mode chatgpt shapes", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  await mkdir(codex);
  await writeFile(join(codex, "auth.json"), JSON.stringify({ mode: "chatgpt", tokens: { access_token: jwt(2000000000) } }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, false);
  assert.equal(result.code, "invalid_credentials");
});

test("uses documented id token nested account id claim", async () => {
  const dir = await mkdtemp(join(tmpdir(), "cr-auth-"));
  const codex = join(dir, "codex");
  await mkdir(codex);
  await writeFile(join(codex, "auth.json"), JSON.stringify({
    auth_mode: "chatgpt",
    tokens: {
      access_token: jwtPayload({ exp: 2000000000 }),
      id_token: jwtPayload({ exp: 2000000000, "https://api.openai.com/auth": { chatgpt_account_id: "acct-from-id" } })
    }
  }));
  const result = await discoverCredentials({ env: { CODEX_HOME: codex, HOME: dir }, nowSeconds: 1000 });
  assert.equal(result.ok, true);
  assert.equal(result.accountId, "acct-from-id");
});
