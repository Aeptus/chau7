#!/usr/bin/env node
import { main } from "../quality/runner.mjs";

main(["--mode=staged", ...process.argv.slice(2)]);

