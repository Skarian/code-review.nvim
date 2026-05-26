import { discoverCredentials } from "./auth.js";
import { connect } from "node:tls";
async function tlsReachable(host, timeoutMs = 3000) {
    return new Promise((resolve) => {
        const socket = connect({ host, port: 443, servername: host, timeout: timeoutMs }, () => {
            socket.end();
            resolve(true);
        });
        socket.once("timeout", () => {
            socket.destroy();
            resolve(false);
        });
        socket.once("error", () => resolve(false));
    });
}
export async function health(options = {}) {
    const credentials = options.credentials || await discoverCredentials(options);
    const networkEnabled = options.network !== false;
    const checks = [
        { name: "node", status: "ok", code: "node_available", message: process.version },
        {
            name: "credentials",
            status: credentials.ok ? "ok" : "warn",
            code: credentials.ok ? "codex_file_chatgpt" : credentials.code,
            message: credentials.ok ? "Codex ChatGPT auth file found." : credentials.message
        }
    ];
    if (networkEnabled && credentials.ok) {
        const reachable = await (options.tlsReachable || tlsReachable)("chatgpt.com");
        checks.push({
            name: "network",
            status: reachable ? "ok" : "warn",
            code: reachable ? "chatgpt_reachable" : "chatgpt_unreachable",
            message: reachable ? "chatgpt.com TLS reachable." : "Could not verify TLS reachability to chatgpt.com."
        });
    }
    return {
        ok: checks.every((check) => check.status !== "error"),
        checks,
        credentialSource: credentials.ok ? "codex_file_chatgpt" : credentials.code,
        selectedEndpoint: "https://chatgpt.com/backend-api/transcribe"
    };
}
