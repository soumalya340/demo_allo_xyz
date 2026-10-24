import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/// Loads the repo-root .env (allo_xyz/.env) into process.env. Imported first by main.ts, so it runs
/// before any module reads its settings. Variables already set in the environment win over the
/// file, and a missing file is fine (Docker passes settings with --env-file / -e instead).
/// This file compiles to backend/dist/env.js, two levels below the repo root.
const envFile = resolve(dirname(fileURLToPath(import.meta.url)), '../../.env');
if (existsSync(envFile)) process.loadEnvFile(envFile);
