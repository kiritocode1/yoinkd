// Passes when the newest download is paused and stays at the same byte count.
import { expectPaused } from "./transfer.mjs";

await expectPaused();
