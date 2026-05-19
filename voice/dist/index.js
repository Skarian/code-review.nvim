import { run } from "./cli.js";
run().then((code) => {
    process.exitCode = code;
}).catch((error) => {
    process.stderr.write(String(error && error.message ? error.message : error) + "\n");
    process.exitCode = 3;
});
