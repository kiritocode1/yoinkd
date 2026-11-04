// Passes when the app saved System appearance and the Sage theme (the defaults). Polls for up to
// 15 seconds because iOS writes UserDefaults shortly after a change.
import { yoinkctl } from "./yoinkctl.mjs";

const deadline = Date.now() + 15000;
let values = {};
while (Date.now() < deadline) {
  values = yoinkctl("state", "--prefs").preferences.values;
  if ((values.appearance ?? "System") === "System" && (values.accentTheme ?? "sage") === "sage") {
    console.log("ok: appearance System, accentTheme sage");
    process.exit(0);
  }
  await new Promise((resolve) => setTimeout(resolve, 1000));
}
throw new Error(`expected appearance System and accentTheme sage, found ${JSON.stringify(values)}`);
