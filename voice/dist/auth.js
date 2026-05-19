import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { helperError } from "./errors.js";
import { jwtPayload, tokenFresh } from "./jwt.js";
export function candidateAuthFiles(env = process.env) {
    const home = env.HOME || env.USERPROFILE || "";
    const codexHome = env.CODEX_HOME;
    return [
        codexHome ? join(codexHome, "auth.json") : null,
        home ? join(home, ".codex", "auth.json") : null,
        home ? join(home, ".config", "codex", "auth.json") : null
    ].filter(Boolean);
}
function classify(raw, file, nowSeconds) {
    let parsed;
    try {
        parsed = JSON.parse(raw);
    }
    catch {
        return helperError("invalid_credentials", "Codex auth file is malformed.", false);
    }
    if (parsed.auth_mode !== "chatgpt") {
        return helperError("invalid_credentials", "Codex auth file is not ChatGPT auth.", false);
    }
    const accessToken = parsed.tokens?.access_token;
    const idToken = parsed.tokens?.id_token;
    if (!accessToken) {
        return helperError("codex_auth_expired", "Codex auth token expired, please login to codex.", false);
    }
    if (!tokenFresh(accessToken, nowSeconds)) {
        return helperError("codex_auth_expired", "Codex auth token expired, please login to codex.", false);
    }
    const accessPayload = jwtPayload(accessToken) || {};
    const idPayload = jwtPayload(idToken) || {};
    const accountId = parsed.tokens?.account_id || accessPayload["https://api.openai.com/auth"]?.chatgpt_account_id || idPayload["https://api.openai.com/auth"]?.chatgpt_account_id || null;
    return { ok: true, source: "codex_file_chatgpt", file, accessToken, idToken, accountId };
}
export async function discoverCredentials(options = {}) {
    const env = options.env || process.env;
    const files = options.files || candidateAuthFiles(env);
    const nowSeconds = options.nowSeconds ?? Math.floor(Date.now() / 1000);
    for (const file of files) {
        let raw;
        try {
            raw = await readFile(file, "utf8");
        }
        catch {
            continue;
        }
        return classify(raw, file, nowSeconds);
    }
    return helperError("missing_credentials", "Codex auth not found, please login to codex.", false);
}
