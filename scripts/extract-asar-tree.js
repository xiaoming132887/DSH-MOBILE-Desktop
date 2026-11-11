const fs = require('fs');
const path = require('path');

const archive = process.argv[2];
const rootEntry = process.argv[3];
const outDir = process.argv[4];
const unpackedDir = process.argv[5] || '';

const fd = fs.openSync(archive, 'r');
const head = Buffer.alloc(16);
fs.readSync(fd, head, 0, 16, 0);
const headerSize = head.readUInt32LE(12);
const headerBuf = Buffer.alloc(headerSize);
fs.readSync(fd, headerBuf, 0, headerSize, 16);
const header = JSON.parse(headerBuf.toString('utf8'));
const dataStart = 16 + headerSize;

let root = header;
for (const part of rootEntry.split('/')) root = root.files[part];
if (!root || !root.files) throw new Error('not a directory: ' + rootEntry);

let files = 0;
let bytes = 0;
function walk(node, prefix) {
  for (const [name, entry] of Object.entries(node.files)) {
    const rel = prefix ? prefix + '/' + name : name;
    const dest = path.join(outDir, ...rel.split('/'));
    if (entry.files) {
      fs.mkdirSync(dest, { recursive: true });
      walk(entry, rel);
      continue;
    }
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    let wrote = false;
    if (entry.unpacked && unpackedDir) {
      const src = path.join(unpackedDir, rootEntry, ...rel.split('/'));
      if (fs.existsSync(src)) {
        fs.copyFileSync(src, dest);
        bytes += fs.statSync(src).size;
        wrote = true;
      }
    }
    if (!wrote) {
      const buf = Buffer.alloc(Number(entry.size));
      fs.readSync(fd, buf, 0, buf.length, dataStart + Number(entry.offset));
      fs.writeFileSync(dest, buf);
      bytes += buf.length;
    }
    files++;
    if (files % 2000 === 0) console.log(`extracted ${files} files, ${(bytes / 1048576).toFixed(1)} MiB`);
  }
}
walk(root, '');
console.log(`done: ${files} files, ${(bytes / 1048576).toFixed(1)} MiB`);
fs.closeSync(fd);
