// Passes when the app saved Dark appearance and the Lavender theme. iOS writes UserDefaults a few
// seconds after a change, so this polls for up to 15 seconds.
import { yoinkctl } from "./yoinkctl.mjs";

const deadline = Date.now() + 15000;
let values = {};
while (Date.now() < deadline) {
  values = yoinkctl("state", "--prefs").preferences.values;
  if (values.appearance === "Dark" && values.accentTheme === "lavender") {
    console.log("ok: appearance Dark, accentTheme lavender");
    process.exit(0);
  }
  await new Promise((resolve) => setTimeout(resolve, 1000));
}
throw new Error(`expected appearance Dark and accentTheme lavender, found ${JSON.stringify(values)}`);
