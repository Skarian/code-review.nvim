export function redact(value) {
  return String(value ?? "")
    .replace(/Bearer\s+[A-Za-z0-9._-]+/g, "Bearer [REDACTED]")
    .replace(/eyJ[A-Za-z0-9._-]+/g, "[REDACTED_JWT]")
    .replace(/"access_token"\s*:\s*"[^"]+"/g, "\"access_token\":\"[REDACTED]\"")
    .replace(/"id_token"\s*:\s*"[^"]+"/g, "\"id_token\":\"[REDACTED]\"")
    .replace(/\/[^\s"]+\.wav/g, "[REDACTED_AUDIO_PATH]");
}
