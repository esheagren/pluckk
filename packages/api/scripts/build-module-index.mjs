// Rebuilds public/modules/index.json from each built-in module's manifest.json and samples.json.
// Run after adding or changing a module: node scripts/build-module-index.mjs
import { readdirSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'modules');
const modules = [];
for (const id of readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort()) {
  for (const major of readdirSync(join(root, id)).filter((v) => /^\d+$/.test(v)).sort()) {
    const dir = join(root, id, major);
    if (!existsSync(join(dir, 'manifest.json'))) continue;
    const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
    const samples = existsSync(join(dir, 'samples.json')) ? JSON.parse(readFileSync(join(dir, 'samples.json'), 'utf8')) : [];
    modules.push({ use: `${id}@${major}`, owner: 'built-in', ...manifest, samples });
  }
}
writeFileSync(join(root, 'index.json'), JSON.stringify({ modules }, null, 1) + '\n');
console.log(`${modules.length} modules indexed`);
