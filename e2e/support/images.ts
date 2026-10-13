import { deflateSync } from "node:zlib";

// Generated test images, so the fixtures don't need binary files.

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

// a width x height PNG: a diagonal gradient between two colours with a darker band, so
// letterboxing and paging are visible in screenshots
export function photo(width: number, height: number, from: [number, number, number], to: [number, number, number]): Buffer {
  const rows: Buffer[] = [];
  for (let y = 0; y < height; y++) {
    const row = Buffer.alloc(1 + width * 3);
    for (let x = 0; x < width; x++) {
      const t = (x / width + y / height) / 2;
      const band = y > height * 0.62 && y < height * 0.7 ? 0.7 : 1;
      for (let c = 0; c < 3; c++) row[1 + x * 3 + c] = Math.round((from[c] + (to[c] - from[c]) * t) * band);
    }
    rows.push(row);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // truecolour
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(rows))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// a level map: four rooms along the top, desks below, as the level maps draw them
export const LEVEL_MAP = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 600">
  <rect x="0" y="0" width="1000" height="600" fill="#f4f5f7" stroke="#9aa1ab" stroke-width="4"/>
  ${[0, 1, 2, 3].map((n) => `<g id="room-${n + 1}"><rect x="${20 + n * 245}" y="20" width="225" height="180" fill="#e3e7ee" stroke="#9aa1ab" stroke-width="3"/><text x="${40 + n * 245}" y="60" font-size="28" fill="#5f6672" font-family="sans-serif">Room ${n + 1}</text></g>`).join("")}
  ${Array.from({ length: 12 }, (_, n) => `<rect id="desk-${n + 1}" x="${60 + (n % 6) * 150}" y="${280 + Math.floor(n / 6) * 150}" width="110" height="70" rx="6" fill="#ffffff" stroke="#9aa1ab" stroke-width="3"/>`).join("")}
</svg>`);

// the X-Map-Pin of each element, its centre on the map above
export function mapPin(id: string): string {
  const room = /^room-(\d)$/.exec(id);
  if (room) return `${20 + (Number(room[1]) - 1) * 245 + 112},110`;
  const desk = /^desk-(\d+)$/.exec(id);
  if (desk) {
    const n = Number(desk[1]) - 1;
    return `${60 + (n % 6) * 150 + 55},${280 + Math.floor(n / 6) * 150 + 35}`;
  }
  return "500,300";
}
