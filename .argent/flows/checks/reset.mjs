// Clears the queue, library, media and share inbox so each e2e flow starts from an empty app.
// Keeps the extractor packages to avoid a re-download on every run.
import { yoinkctl } from "./yoinkctl.mjs";

const result = yoinkctl("reset", "--keep-deps");
console.log(`reset: deleted ${result.delete.length} paths`);
