// Shared helpers for flow check scripts: run scripts/yoinkctl against the booted simulator and fail
// the flow step (by throwing, which exits non-zero) when the app's own state disagrees.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

/** Runs yoinkctl and returns its JSON. Its output is printed only when it fails, to keep flow logs short. */
export function yoinkctl(...args) {
  const result = spawnSync(path.join(root, "scripts/yoinkctl"), args, { encoding: "utf8" });
  if (result.status !== 0) {
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    throw new Error(`yoinkctl ${args.join(" ")} exited ${result.status}`);
  }
  return JSON.parse(result.stdout);
}

/** The newest job finishes and its file is a saved, non-empty library item of the given kind. */
export function expectNewestSaved(kind, timeoutSeconds = 90) {
  const { job } = yoinkctl("wait", "--job", "newest", "--phase", "completed", "--timeout", String(timeoutSeconds));
  const { library } = yoinkctl("state", "--library");
  const item = library.items.find((entry) => entry.file === job.storedFile);
  if (!item || !item.fileExists || !(item.bytes > 0)) {
    throw new Error(`"${job.title}" completed but ${job.storedFile} is not a saved, non-empty library file`);
  }
  if (kind && item.kind !== kind) {
    throw new Error(`"${job.title}" was saved as ${item.kind}, expected ${kind}`);
  }
  console.log(`ok: "${job.title}" saved as ${item.file} (${item.bytes} bytes, ${item.kind})`);
  return { job, item };
}
