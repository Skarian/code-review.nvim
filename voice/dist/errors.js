export const ERROR_CODES = new Set([
    "missing_helper",
    "missing_credentials",
    "invalid_credentials",
    "invalid_arguments",
    "codex_auth_expired",
    "audio_provider_unavailable",
    "audio_device_unavailable",
    "recording_permission_denied",
    "recording_too_short",
    "empty_recording",
    "audio_too_large",
    "network_error",
    "http_error",
    "empty_transcript",
    "invalid_response",
    "timeout",
    "unknown"
]);
export function helperError(code, message, retryable = false, details = undefined) {
    return { ok: false, code, message, retryable, ...(details ? { details } : {}) };
}
export function printJson(value) {
    process.stdout.write(`${JSON.stringify(value)}\n`);
}
