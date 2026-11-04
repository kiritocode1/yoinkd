// Checks for flows that pause, resume or relaunch during a long download. They read the newest job's
// phase and byte count from yoinkctl and keep the byte count between steps in a small state file.
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { yoinkctl } from "./yoinkctl.mjs";

const stateFile = path.join(tmpdir(), "yoinkd-flow-transfer.json");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function newestJob() {
  const jobs = yoinkctl("state", "--jobs").queue.jobs;
  if (!jobs.length) throw new Error("the queue has no jobs");
  return jobs[jobs.length - 1];
}

/** Waits until the newest job is downloading and has received bytes, so its row shows the progress layout. */
export async function expectReceiving(timeoutMs = 60000, aboveBytes = 0) {
  const deadline = Date.now() + timeoutMs;
  let job;
  while (Date.now() < deadline) {
    job = newestJob();
    if (job.phase === "downloading" && job.receivedBytes > aboveBytes) {
      console.log(`ok: "${job.title}" downloading, ${job.receivedBytes} of ${job.expectedBytes} bytes`);
      return job;
    }
    if (["completed", "failed", "cancelled"].includes(job.phase)) break;
    await sleep(250);
  }
  throw new Error(`expected a download receiving more than ${aboveBytes} bytes, found ${JSON.stringify(job)}`);
}

/** Waits until the newest job is paused and its byte count holds still, then remembers that count. */
export async function expectPaused(messagePart, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let job;
  while (Date.now() < deadline) {
    job = newestJob();
    if (job.phase === "paused") break;
    await sleep(250);
  }
  if (job?.phase !== "paused") throw new Error(`expected the download to pause, found ${JSON.stringify(job)}`);
  if (messagePart && !(job.message ?? "").includes(messagePart)) {
    throw new Error(`expected the paused message to mention "${messagePart}", found ${JSON.stringify(job.message)}`);
  }
  await sleep(2000);
  const later = newestJob();
  if (later.phase !== "paused" || later.receivedBytes !== job.receivedBytes) {
    throw new Error(`a paused download kept changing: ${job.receivedBytes} -> ${later.receivedBytes} (${later.phase})`);
  }
  writeFileSync(stateFile, JSON.stringify({ id: job.id, receivedBytes: job.receivedBytes }));
  console.log(`ok: "${job.title}" paused at ${job.receivedBytes} bytes${job.message ? ` (${job.message})` : ""}`);
  return job;
}

/** After resuming, the same job downloads again past the paused byte count instead of restarting. */
export async function expectResumedPastPause(timeoutMs = 60000) {
  const paused = JSON.parse(readFileSync(stateFile, "utf8"));
  const job = await expectReceiving(timeoutMs, paused.receivedBytes);
  if (job.id !== paused.id) throw new Error(`a different job (${job.id}) is downloading, expected ${paused.id}`);
  console.log(`ok: resumed past the paused ${paused.receivedBytes} bytes`);
  return job;
}
