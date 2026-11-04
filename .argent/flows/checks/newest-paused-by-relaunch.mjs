// Passes when a download interrupted by quitting the app comes back paused with the relaunch message.
import { expectPaused } from "./transfer.mjs";

await expectPaused("Paused when yoink'd closed");
