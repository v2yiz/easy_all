import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import assert from 'node:assert/strict';
import path from 'node:path';

const root = fileURLToPath(new URL('..', import.meta.url));
const res = spawnSync('bash', [path.join(root, 'test/test_bunny.sh')], {stdio: 'inherit'});
assert.equal(res.status, 0, 'Bunny CDN end-to-end tests failed');
