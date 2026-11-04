// Passes when the paused download resumes and receives past where it paused.
import { expectResumedPastPause } from "./transfer.mjs";

await expectResumedPastPause();
