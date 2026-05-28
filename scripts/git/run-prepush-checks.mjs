#!/usr/bin/env node
import { main } from "../quality/runner.mjs";

main(["--mode=prepush", ...process.argv.slice(2)]);

