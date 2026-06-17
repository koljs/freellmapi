// Bundles the FreeLLMAPI server into a single ESM file for the Magisk module.
// Mirrors desktop/scripts/bundle-server.mjs but targets server/src/index.ts
// directly. better-sqlite3 stays external (native module, compiled separately
// for arm64 Linux/glibc and shipped alongside the bundle).
import { build } from 'esbuild';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

await build({
  entryPoints: [path.resolve(__dirname, '../server/src/index.ts')],
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  outfile: path.resolve(__dirname, '../build/bundle/index.mjs'),
  external: ['better-sqlite3'],
  // express and other CJS deps reference `require` at runtime; give the ESM
  // bundle a working one (same trick as the desktop bundle).
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);",
  },
  logLevel: 'info',
});
