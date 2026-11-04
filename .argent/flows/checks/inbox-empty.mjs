// Passes when the App Group inbox is available and empty: the app took the shared link and removed
// its file, so it won't be shown a second time.
import { yoinkctl } from "./yoinkctl.mjs";

const { inbox } = yoinkctl("state", "--inbox");
if (!inbox.available) throw new Error("the App Group inbox is unavailable; is the build missing its entitlements?");
if (inbox.requests.length) throw new Error(`${inbox.requests.length} shared link(s) still waiting: ${JSON.stringify(inbox.requests)}`);
console.log("ok: the share inbox is empty");
