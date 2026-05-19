import { discoverCredentials } from "./auth.js";
import { helperError, printJson } from "./errors.js";
import { health } from "./health.js";
import { recordCommand } from "./record.js";
import { redact } from "./redact.js";
import { transcribeFile } from "./transcribe.js";
function exitCode(result) {
    if (result.ok)
        return 0;
    return result.code === "invalid_arguments" ? 2 : 1;
}
export async function run(argv = process.argv.slice(2)) {
    const command = argv[0];
    if (command === "health") {
        printJson(await health({ network: !argv.includes("--no-network") }));
        return 0;
    }
    if (command === "record") {
        const result = await recordCommand(argv.slice(1));
        printJson(result);
        return exitCode(result);
    }
    if (command === "transcribe") {
        const inputIndex = argv.indexOf("--input");
        const input = inputIndex >= 0 ? argv[inputIndex + 1] : null;
        const timeoutIndex = argv.indexOf("--timeout-ms");
        const maxAudioIndex = argv.indexOf("--max-audio-bytes");
        const timeoutMs = timeoutIndex >= 0 ? Number(argv[timeoutIndex + 1]) : undefined;
        const maxAudioBytes = maxAudioIndex >= 0 ? Number(argv[maxAudioIndex + 1]) : undefined;
        if (!input || (timeoutIndex >= 0 && !Number.isFinite(timeoutMs)) || (maxAudioIndex >= 0 && !Number.isFinite(maxAudioBytes))) {
            printJson(helperError("invalid_arguments", "Invalid transcribe arguments.", false));
            return 2;
        }
        const credentials = await discoverCredentials();
        if (!credentials.ok) {
            printJson(credentials);
            return 1;
        }
        const result = await transcribeFile(input, credentials, { timeoutMs, maxAudioBytes });
        printJson(result);
        return exitCode(result);
    }
    printJson(helperError("unknown", `Unknown command: ${redact(command)}`, false));
    return 2;
}
