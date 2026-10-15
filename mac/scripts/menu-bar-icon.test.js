const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function loadRows() {
  const src = fs.readFileSync(path.join(__dirname, '..', 'BatteryEmergencyOverlay.swift'), 'utf8');
  const start = src.indexOf('enum MenuBarIconArt');
  const end = src.indexOf('private func makeStatusBarIcon');
  assert.ok(start >= 0 && end > start);
  const rows = [...src.slice(start, end).matchAll(/"([.#]{18})"/g)].map((match) => match[1]);
  assert.equal(rows.length, 18);
  return rows;
}

function components(rows) {
  const height = rows.length;
  const width = rows[0].length;
  const seen = Array.from({ length: height }, () => Array(width).fill(false));
  const parts = [];
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (rows[y][x] !== '#' || seen[y][x]) continue;
      const pixels = [];
      const stack = [[x, y]];
      seen[y][x] = true;
      while (stack.length) {
        const [cx, cy] = stack.pop();
        pixels.push([cx, cy]);
        for (const dx of [-1, 0, 1]) {
          for (const dy of [-1, 0, 1]) {
            if (dx === 0 && dy === 0) continue;
            const nx = cx + dx;
            const ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= width || ny >= height || seen[ny][nx] || rows[ny][nx] !== '#') continue;
            seen[ny][nx] = true;
            stack.push([nx, ny]);
          }
        }
      }
      parts.push(pixels);
    }
  }
  return parts;
}

function bounds(pixels) {
  const xs = pixels.map((pixel) => pixel[0]);
  const ys = pixels.map((pixel) => pixel[1]);
  return {
    left: Math.min(...xs),
    right: Math.max(...xs),
    top: Math.min(...ys),
    bottom: Math.max(...ys),
  };
}

function center(box) {
  return { x: (box.left + box.right) / 2, y: (box.top + box.bottom) / 2 };
}

// The nub sits above the body's wide top edge and is not part of the centered box.
function bodyBox(shell) {
  const byRow = new Map();
  for (const [x, y] of shell) {
    const row = byRow.get(y) || [];
    row.push(x);
    byRow.set(y, row);
  }
  const widest = Math.max(...[...byRow.values()].map((xs) => xs.length));
  const caps = [...byRow.entries()].filter(([, xs]) => xs.length === widest).map(([y]) => y);
  const top = Math.min(...caps);
  const body = shell.filter(([, y]) => y >= top);
  return bounds(body);
}

function measure(rows) {
  const parts = components(rows).sort((a, b) => b.length - a.length);
  assert.equal(parts.length, 3);
  const body = bodyBox(parts[0]);
  const mark = bounds(parts.slice(1).flat());
  return { body, mark, bodyCenter: center(body), markCenter: center(mark) };
}

test('menu bar exclamation is centered in the battery body at @1x and @2x', () => {
  const rows = loadRows();
  rows.forEach((row) => assert.equal(row, [...row].reverse().join('')));

  const at1 = measure(rows);
  assert.equal(at1.markCenter.x, at1.bodyCenter.x);
  assert.equal(at1.markCenter.y, at1.bodyCenter.y);
  assert.equal(at1.mark.left - at1.body.left, at1.body.right - at1.mark.right);
  assert.equal(at1.mark.top - at1.body.top, at1.body.bottom - at1.mark.bottom);

  const doubled = rows.flatMap((row) => {
    const wide = [...row].map((pixel) => pixel.repeat(2)).join('');
    return [wide, wide];
  });
  const at2 = measure(doubled);
  assert.equal(at2.markCenter.x, at2.bodyCenter.x);
  assert.equal(at2.markCenter.y, at2.bodyCenter.y);
  assert.equal(at2.bodyCenter.x, at1.bodyCenter.x * 2 + 0.5);
  assert.equal(at2.bodyCenter.y, at1.bodyCenter.y * 2 + 0.5);
  assert.equal(at2.markCenter.x, at1.markCenter.x * 2 + 0.5);
  assert.equal(at2.markCenter.y, at1.markCenter.y * 2 + 0.5);
});
