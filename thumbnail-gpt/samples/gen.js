// Generates two hand-built thumbnails as SVG (1920x1080).
const fs = require("fs");
const path = require("path");
const out = __dirname;

function hex(c) { return [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16)); }
function toHex(a) { return "#" + a.map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join(""); }
function shade(c, f) {
  const a = hex(c);
  return f >= 1 ? toHex(a.map((v) => v + (255 - v) * (f - 1))) : toHex(a.map((v) => v * f));
}
const pts = (p) => p.map((q) => q.join(",")).join(" ");

// Oblique box: front face + lit top + darker right side.
function box(x, y, w, h, d, c, rx = 6, extra = "") {
  const dx = d * 0.55, dy = -d * 0.4;
  return `<g ${extra}>
  <polygon points="${pts([[x, y], [x + dx, y + dy], [x + w + dx, y + dy], [x + w, y]])}" fill="${shade(c, 1.22)}"/>
  <polygon points="${pts([[x + w, y], [x + w + dx, y + dy], [x + w + dx, y + h + dy], [x + w, y + h]])}" fill="${shade(c, 0.72)}"/>
  <rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}" fill="${c}"/>
  <rect x="${x + 6}" y="${y + 6}" width="${w * 0.35}" height="${Math.min(14, h * 0.1)}" rx="4" fill="#fff" opacity=".18"/>
</g>`;
}
// A box rotated about its own left-centre (for arms).
function rbox(x, y, w, h, d, c, deg) {
  return `<g transform="rotate(${deg} ${x} ${y + h / 2})">${box(x, y, w, h, d, c, 6)}</g>`;
}
function star(cx, cy, r, fill = "#fff") {
  const s = r * 0.22;
  return `<path d="M${cx},${cy - r} Q${cx + s},${cy - s} ${cx + r},${cy} Q${cx + s},${cy + s} ${cx},${cy + r} Q${cx - s},${cy + s} ${cx - r},${cy} Q${cx - s},${cy - s} ${cx},${cy - r}Z" fill="${fill}"/>`;
}
function bubble(cx, cy, r) {
  return `<circle cx="${cx}" cy="${cy}" r="${r}" fill="#dff6ff" fill-opacity=".35" stroke="#fff" stroke-width="${Math.max(2, r * 0.12)}"/>
<circle cx="${cx - r * 0.35}" cy="${cy - r * 0.35}" r="${r * 0.2}" fill="#fff"/>`;
}
function drip(x, y, len, w, c) {
  return `<path d="M${x - w / 2},${y} L${x - w / 2},${y + len} A${w / 2},${w / 2} 0 0 0 ${x + w / 2},${y + len} L${x + w / 2},${y}Z" fill="${c}"/>
<circle cx="${x}" cy="${y + len + w * 0.9}" r="${w * 0.42}" fill="${c}"/>`;
}
// A lumpy mud chunk flying, with a streak pointing back to its source.
function chunk(cx, cy, r, fx, fy, c = "#5e3418") {
  const ang = Math.atan2(cy - fy, cx - fx);
  const tx = cx - Math.cos(ang) * r * 1.8, ty = cy - Math.sin(ang) * r * 1.8;
  const lumps = [0, 1, 2, 3, 4].map((i) => {
    const a = i * 1.3 + r;
    return `<circle cx="${cx + Math.cos(a) * r * 0.45}" cy="${cy + Math.sin(a) * r * 0.45}" r="${r * 0.62}" fill="${c}"/>`;
  }).join("");
  return `<line x1="${tx}" y1="${ty}" x2="${cx}" y2="${cy}" stroke="${c}" stroke-width="${r * 0.7}" stroke-linecap="round" opacity=".22"/>
${lumps}<circle cx="${cx - r * 0.3}" cy="${cy - r * 0.35}" r="${r * 0.22}" fill="#c9905e" opacity=".8"/>`;
}
function title(lines, x, y, size, fill = "#ffe02e") {
  return lines.map((t, i) => `<text x="${x}" y="${y + i * size * 0.98}" font-family="'Lilita One','Arial Black',sans-serif" font-size="${size}"
  fill="${fill}" stroke="#000" stroke-width="${size * 0.13}" stroke-linejoin="round" paint-order="stroke"
  style="filter:drop-shadow(0 ${size * 0.07}px 0 #000)">${t}</text>`).join("");
}
const head = `<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
<style>@import url('https://fonts.googleapis.com/css2?family=Lilita+One&amp;display=block');</style>`;

// Classic blocky hero avatar. Feet at (fx, fy), scale s. face: "grin" | "shock".
function avatar(fx, fy, s, face, armDeg, legSpread = 0) {
  const g = [];
  const SK = "#ffcf9e", COAT = "#ffd21f", BLUE = "#2f6fe0", BOOT = "#1d1d22", HAIR = "#6b3f1f";
  // legs
  g.push(`<g transform="rotate(${legSpread} 0 -330)">${box(-100, -330, 86, 270, 40, BLUE)}${box(-104, -70, 94, 70, 44, BOOT)}</g>`);
  g.push(`<g transform="rotate(${-legSpread} 0 -330)">${box(4, -330, 86, 270, 40, BLUE)}${box(0, -70, 94, 70, 44, BOOT)}</g>`);
  // back arm
  g.push(rbox(70, -560, 250, 70, 34, shade(COAT, 0.88), armDeg + 6));
  // torso with overall bib
  g.push(box(-110, -575, 210, 250, 50, COAT));
  g.push(`<rect x="-65" y="-470" width="120" height="145" rx="6" fill="${BLUE}"/>
<rect x="-80" y="-575" width="18" height="110" fill="${BLUE}"/><rect x="40" y="-575" width="18" height="110" fill="${BLUE}"/>
<circle cx="-50" cy="-455" r="9" fill="#ffe36b"/><circle cx="40" cy="-455" r="9" fill="#ffe36b"/>
<rect x="-110" y="-345" width="210" height="20" fill="${shade(BLUE, 0.8)}"/>`);
  // head + hair
  g.push(box(-80, -730, 150, 145, 46, SK, 14));
  g.push(box(-88, -748, 166, 46, 48, HAIR, 10));
  g.push(`<rect x="-88" y="-712" width="26" height="60" rx="6" fill="${HAIR}"/>`);
  if (face === "grin") {
    g.push(`<ellipse cx="-38" cy="-670" rx="11" ry="17" fill="#111"/><ellipse cx="28" cy="-670" rx="11" ry="17" fill="#111"/>
<circle cx="-41" cy="-676" r="4" fill="#fff"/><circle cx="25" cy="-676" r="4" fill="#fff"/>
<path d="M-50,-638 L40,-638 Q38,-596 -5,-596 Q-48,-596 -50,-638Z" fill="#111"/>
<path d="M-44,-638 L34,-638 L32,-628 L-42,-628Z" fill="#fff"/>
<path d="M-26,-606 Q-5,-622 18,-606 Q-4,-598 -26,-606Z" fill="#e8475a"/>`);
  } else {
    g.push(`<ellipse cx="-38" cy="-672" rx="16" ry="21" fill="#fff" stroke="#111" stroke-width="5"/><ellipse cx="28" cy="-672" rx="16" ry="21" fill="#fff" stroke="#111" stroke-width="5"/>
<circle cx="-36" cy="-670" r="7" fill="#111"/><circle cx="30" cy="-670" r="7" fill="#111"/>
<path d="M-50,-706 L-22,-700" stroke="#111" stroke-width="6" stroke-linecap="round"/><path d="M14,-700 L42,-706" stroke="#111" stroke-width="6" stroke-linecap="round"/>
<ellipse cx="-5" cy="-618" rx="20" ry="26" fill="#111"/><ellipse cx="-5" cy="-610" rx="11" ry="12" fill="#e8475a"/>`);
  }
  // front arm
  g.push(rbox(60, -550, 260, 72, 34, COAT, armDeg));
  return `<g transform="translate(${fx} ${fy}) scale(${s})">
<ellipse cx="0" cy="0" rx="150" ry="22" fill="#000" opacity=".22"/>
${g.join("\n")}</g>`;
}

// ---------------- Thumbnail A: half-and-half pig ----------------
function pig(c) {
  const P = c.base, D = c.dark;
  return [
    box(1060, 790, 92, 120, 50, D),
    box(1550, 790, 92, 120, 50, D),
    box(1010, 460, 660, 340, 210, P, 18),
    box(1080, 795, 96, 125, 50, P),
    box(1480, 795, 96, 125, 50, P),
    `<polygon points="1195,345 1230,235 1300,330" fill="${D}"/><polygon points="1385,330 1455,235 1490,345" fill="${D}"/>`,
    box(1175, 330, 330, 300, 120, P, 22),
    box(1268, 480, 150, 96, 34, c.snout, 16),
  ].join("\n");
}
function makeA() {
  const SPLIT = 1340;
  const wave = (x0) => {
    let d = `M-200,-200 L${x0},-200`;
    for (let y = -200; y <= 1300; y += 60) d += ` Q${x0 + (y / 60) % 2 * 0 + (Math.floor(y / 60) % 2 ? 26 : -26)},${y + 30} ${x0},${y + 60}`;
    return d + ` L-200,1300Z`;
  };
  const pigClip = `<clipPath id="pigShape">${pig({ base: "#000", dark: "#000", snout: "#000" }).replace(/fill="[^"]+"/g, "").replace(/<g[^>]*>|<\/g>/g, "")}</clipPath>`;
  const mud = { base: "#6e3f1d", dark: "#55301a", snout: "#5b331a" };
  const lumps = [];
  for (let i = 0; i < 70; i++) {
    const x = 1000 + ((i * 97) % 360), y = 320 + ((i * 53) % 600), r = 10 + ((i * 7) % 22);
    lumps.push(`<circle cx="${x}" cy="${y}" r="${r}" fill="${i % 3 ? "#5a3217" : "#7d4a24"}"/>`);
  }
  const shines = [[1060, 520, 34, 12], [1130, 700, 26, 10], [1215, 590, 22, 8], [1050, 610, 18, 7], [1240, 380, 20, 8], [1290, 540, 16, 6]]
    .map(([x, y, rx, ry]) => `<ellipse cx="${x}" cy="${y}" rx="${rx}" ry="${ry}" fill="#f3c08f" opacity=".55" transform="rotate(-20 ${x} ${y})"/>`).join("");
  const drips = [[1040, 795, 70, 26], [1110, 795, 40, 20], [1190, 625, 55, 22], [1290, 572, 34, 16], [1200, 798, 90, 24], [1300, 798, 46, 20], [1100, 915, 30, 18]]
    .map(([x, y, l, w]) => drip(x, y, l, w, "#5e3519")).join("");

  // impact point and jet
  const NX = 905, NY = 505, IX = SPLIT - 6, IY = 520;
  const jet = `<polygon points="${NX},${NY - 9} ${IX},${IY - 30} ${IX},${IY + 30} ${NX},${NY + 9}" fill="#7fe3ff" opacity=".9"/>
<polygon points="${NX},${NY - 5} ${IX},${IY - 15} ${IX},${IY + 15} ${NX},${NY + 5}" fill="#fff"/>` +
    [[960, 490, 6], [1010, 535, 5], [1080, 488, 7], [1140, 545, 6], [1200, 490, 8], [1250, 552, 7]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#bff1ff"/>`).join("");
  const splash = [];
  for (let i = 0; i < 16; i++) {
    const a = -Math.PI / 2 + (i - 7.5) * 0.24, L = 70 + ((i * 37) % 90);
    splash.push(`<line x1="${IX}" y1="${IY}" x2="${IX + Math.cos(a) * L * 0.9 - 30}" y2="${IY + Math.sin(a) * L}" stroke="#e9fbff" stroke-width="${9 - (i % 4)}" stroke-linecap="round"/>`);
    splash.push(`<circle cx="${IX + Math.cos(a) * L * 1.25 - 40}" cy="${IY + Math.sin(a) * L * 1.3}" r="${5 + (i % 3) * 3}" fill="#c9f4ff"/>`);
  }
  const chunks = [[1205, 300, 34], [1460, 250, 26], [1560, 380, 18], [1130, 400, 20], [1395, 175, 44], [1600, 205, 30], [1250, 640, 14], [1520, 575, 16]]
    .map(([x, y, r]) => chunk(x, y, r, IX, IY)).join("");

  const sparkle = [[1580, 520, 34], [1460, 690, 22], [1630, 700, 26], [1470, 380, 18], [1700, 430, 16], [1545, 300, 14]].map(([x, y, r]) => star(x, y, r)).join("") +
    [[1610, 610, 26], [1700, 560, 16], [1520, 760, 18], [1745, 350, 22]].map(([x, y, r]) => bubble(x, y, r)).join("");

  const clouds = [[260, 150, 1], [980, 110, 0.8], [1650, 160, 1.1]].map(([x, y, s]) =>
    `<g transform="translate(${x} ${y}) scale(${s})" fill="#fff"><rect x="-110" y="-10" width="240" height="60" rx="30"/><circle cx="-30" cy="-5" r="48"/><circle cx="40" cy="-20" r="58"/></g>`).join("");

  const svg = `${head}
<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#11a9e8"/><stop offset="1" stop-color="#93e4ff"/></linearGradient>
${pigClip}
<clipPath id="left"><path d="${wave(SPLIT)}"/></clipPath>
</defs>
<g transform="rotate(-3 960 540) scale(1.07) translate(-67 -38)">
<rect x="-200" y="-200" width="2400" height="1500" fill="url(#sky)"/>
${clouds}
<path d="M-200,760 Q300,640 800,720 T1800,690 L2200,700 L2200,900 L-200,900Z" fill="#46b85a"/>
${box(640, 590, 190, 130, 90, "#d93a2f", 4)}
<polygon points="640,590 735,520 830,590" fill="#b02a22"/><rect x="705" y="640" width="60" height="80" fill="#fff"/><rect x="712" y="648" width="46" height="72" fill="#8b2a22"/>
${[...Array(14)].map((_, i) => box(-100 + i * 70, 705, 12, 40, 10, "#ffffff", 2)).join("")}
<rect x="-200" y="728" width="1100" height="10" fill="#fff"/>
<rect x="-200" y="750" width="2400" height="600" fill="#5ccc45"/>
<polygon points="880,1180 1000,850 1880,850 1860,1180" fill="#cfd6de"/>
<polygon points="880,1180 1000,850 1340,850 1320,1180" fill="#a6abb1" opacity=".35"/>
<ellipse cx="1150" cy="960" rx="240" ry="40" fill="#5b3418"/><ellipse cx="1110" cy="950" rx="70" ry="10" fill="#9a6a3e" opacity=".6"/>
<ellipse cx="1360" cy="935" rx="400" ry="45" fill="#000" opacity=".2"/>
${pig({ base: "#ff9ec2", dark: "#ef7fa8", snout: "#ff7aa8" })}
<rect x="1520" y="490" width="20" height="260" rx="10" fill="#fff" opacity=".35" transform="rotate(18 1530 620)"/>
<rect x="1580" y="490" width="10" height="250" rx="5" fill="#fff" opacity=".35" transform="rotate(18 1585 620)"/>
<ellipse cx="1312" cy="528" rx="11" ry="14" fill="#7a1f45"/><ellipse cx="1372" cy="528" rx="11" ry="14" fill="#7a1f45"/>
<rect x="1400" y="398" width="48" height="66" rx="16" fill="#111"/><circle cx="1413" cy="413" r="9" fill="#fff"/>
<ellipse cx="1462" cy="500" rx="26" ry="14" fill="#ff6f9f" opacity=".7"/>
<path d="M1450,560 Q1470,585 1495,565" stroke="#7a1f45" stroke-width="8" fill="none" stroke-linecap="round"/>
<g clip-path="url(#left)">
  <g clip-path="url(#pigShape)">${pig(mud)}${lumps.join("")}${shines}</g>
  ${drips}
</g>
<path d="${wave(SPLIT).replace(/M-200,-200 L[\d.]+,-200/, `M${SPLIT},-200`).replace(/ L-200,1300Z/, "")}" fill="none" stroke="#3d220f" stroke-width="10" clip-path="url(#pigShape)"/>
<rect x="1222" y="398" width="48" height="66" rx="16" fill="#111"/><circle cx="1235" cy="413" r="9" fill="#fff"/>
<circle cx="1246" cy="431" r="44" fill="none" stroke="#4a2810" stroke-width="12" stroke-dasharray="40 14"/>
${sparkle}
${avatar(430, 980, 1, "grin", -3)}
<path d="M760,515 Q690,700 540,760 T60,1100" stroke="#2b2b30" stroke-width="16" fill="none"/>
${box(740, 488, 60, 54, 26, "#ffcc00", 8)}
<rect x="790" y="497" width="118" height="18" rx="6" fill="#3a3a40"/><rect x="885" y="492" width="26" height="28" rx="4" fill="#9aa3ad"/>
${jet}
${splash.join("")}
${chunks}
</g>
${title(["WASH THE FARM!"], 50, 165, 138)}
</svg>`;
  fs.writeFileSync(path.join(out, "thumb_A_half_and_half.svg"), svg);
}

// ---------------- Thumbnail B: too big to wash ----------------
function makeB() {
  const G = "#3d7d35", GL = "#86c95c";
  const kaijuShapes = (g, gl, dark) => `
<polygon points="1560,190 1720,170 1790,640 1640,660" fill="${dark}"/>
<polygon points="1640,620 1800,610 1820,700 1640,700" fill="${dark}"/>
<polygon points="1500,880 1880,780 1920,840 1560,960" fill="${dark}"/>
<polygon points="800,900 1560,900 1500,-60 860,-60" fill="${g}"/>
<polygon points="1560,900 1650,850 1580,-60 1500,-60" fill="${shade(g, 0.7)}"/>
<polygon points="790,180 640,170 560,640 710,660" fill="${g}"/>
<polygon points="540,620 720,610 735,705 530,700" fill="${g}"/>
<polygon points="955,880 1405,880 1365,280 995,280" fill="${gl}"/>
${box(830, 820, 260, 190, 70, g, 10)}${box(1270, 820, 260, 190, 70, g, 10)}
<polygon points="880,-80 1480,-80 1450,250 910,250" fill="${shade(g, 1.08)}"/>
<polygon points="1480,-80 1570,-120 1540,210 1450,250" fill="${shade(g, 0.72)}"/>`;
  const clipShape = kaijuShapes("#000", "#000", "#000").replace(/fill="[^"]+"/g, "").replace(/<g[^>]*>|<\/g>/g, "");
  // Clean patch where the jet lands (mask hole).
  const PX = 1170, PY = 520;
  let hole = "";
  for (let i = 0; i < 20; i++) {
    const a = (i / 20) * Math.PI * 2, r = 165 + (i % 2 ? 30 : -18);
    hole += (i ? " L" : "M") + `${PX + Math.cos(a) * r * 1.05},${PY + Math.sin(a) * r * 0.85}`;
  }
  hole += "Z";
  const mudLumps = [];
  for (let i = 0; i < 160; i++) {
    const x = 540 + ((i * 131) % 1300), y = -80 + ((i * 71) % 1080), r = 14 + ((i * 11) % 34);
    mudLumps.push(`<circle cx="${x}" cy="${y}" r="${r}" fill="${i % 3 ? "#5a3217" : "#80502a"}"/>`);
  }
  const streaks = [];
  for (let i = 0; i < 24; i++) {
    const x = 560 + ((i * 89) % 1240), y = 100 + ((i * 47) % 600);
    streaks.push(`<rect x="${x}" y="${y}" width="${16 + (i % 3) * 8}" height="${120 + (i * 29) % 160}" rx="12" fill="#4a2810"/>`);
    streaks.push(`<ellipse cx="${x + 10}" cy="${y + 30}" rx="9" ry="22" fill="#d7a072" opacity=".45"/>`);
  }
  const fallDrips = [[600, 700, 140, 34], [700, 705, 90, 26], [1680, 700, 110, 30], [1790, 700, 160, 34], [900, 1005, 30, 22], [1450, 1005, 40, 26]]
    .map(([x, y, l, w]) => drip(x, y, l, w, "#5e3519")).join("");
  const NX = 486, NY = 832;
  const jetPath = `M${NX},${NY} Q760,330 ${PX - 20},${PY + 10}`;
  const chunks = [[1390, 360, 40], [1420, 620, 30], [930, 360, 34], [960, 650, 26], [1250, 250, 24], [1080, 270, 30], [1500, 470, 22], [1330, 760, 22], [1600, 300, 46], [830, 520, 20]]
    .map(([x, y, r]) => chunk(x, y, r, PX, PY)).join("");
  const spray = [];
  for (let i = 0; i < 22; i++) {
    const a = (i / 22) * Math.PI * 2, L = 120 + ((i * 41) % 110);
    spray.push(`<line x1="${PX + Math.cos(a) * 60}" y1="${PY + Math.sin(a) * 50}" x2="${PX + Math.cos(a) * L}" y2="${PY + Math.sin(a) * L * 0.85}" stroke="#ecfcff" stroke-width="${10 - (i % 4) * 2}" stroke-linecap="round"/>`);
  }
  const svg = `${head}
<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff4d14"/><stop offset=".6" stop-color="#ff8a1f"/><stop offset="1" stop-color="#ffc556"/></linearGradient>
<clipPath id="kaiju">${clipShape}</clipPath>
<mask id="patch"><path d="M0,1400 L0,300 ${[...Array(20)].map((_, i) => `Q${i * 100 + 50},${i % 2 ? 330 : 250} ${i * 100 + 100},290`).join(" ")} L2000,1400Z" fill="#fff"/><path d="${hole}" fill="#000"/></mask>
</defs>
<rect width="1920" height="1080" fill="url(#sky)"/>
<circle cx="350" cy="690" r="170" fill="#ffe28a"/>
${[[200, 210, 1], [1780, 120, 0.8]].map(([x, y, s]) => `<g transform="translate(${x} ${y}) scale(${s})" fill="#ffd2a6"><rect x="-120" y="-10" width="250" height="56" rx="28"/><circle cx="-30" cy="-5" r="44"/><circle cx="40" cy="-18" r="54"/></g>`).join("")}
<path d="M0,840 Q300,760 620,820 T1300,800 T1920,810 L1920,940 L0,940Z" fill="#c4521f"/>
<rect y="900" width="1920" height="200" fill="#4f9a32"/>
${[...Array(28)].map((_, i) => box(i * 72 - 10, 905, 12, 46, 10, "#fff4e6", 2)).join("")}
<rect y="920" width="1920" height="9" fill="#fff4e6"/>
<ellipse cx="1180" cy="1020" rx="560" ry="60" fill="#5b3418"/>
${kaijuShapes(G, GL, shade(G, 0.62))}
${[[880, 175], [1060, 150], [1250, 150], [1440, 175]].map(([x, y]) => `<polygon points="${x - 35},${y + 10} ${x},${y - 80} ${x + 35},${y + 10}" fill="#2a5a24" transform="translate(0 -110)"/>`).join("")}
${[[555, 720], [600, 725], [650, 725], [1650, 720], [1700, 722], [1750, 718]].map(([x, y]) => `<polygon points="${x - 16},${y - 20} ${x + 16},${y - 20} ${x},${y + 26}" fill="#f2efe4"/>`).join("")}
${[855, 925, 995, 1295, 1365, 1435].map((x) => `<polygon points="${x},1010 ${x + 50},1010 ${x + 25},1040" fill="#f2efe4"/>`).join("")}
${[340, 440, 540, 640, 740].map((y) => `<rect x="1000" y="${y}" width="${360 - (740 - y) * 0.05}" height="8" fill="${shade(GL, 0.8)}"/>`).join("")}
<g clip-path="url(#kaiju)"><g mask="url(#patch)">
  <rect x="400" y="-200" width="1600" height="1400" fill="#6b3c1c"/>
  ${mudLumps.join("")}${streaks.join("")}
</g></g>
<path d="${hole}" fill="none" stroke="#3d220f" stroke-width="12"/>
${[[930, 300, 60, 26], [1010, 310, 110, 30], [1120, 300, 50, 22], [1300, 305, 90, 28], [1420, 300, 60, 24], [780, 300, 70, 26]].map(([x, y, l, w]) => drip(x, y - 30, l, w, "#6b3c1c")).join("")}
<g clip-path="url(#kaiju)">${[[920, 20, 40], [1440, 60, 34], [1200, -30, 46], [1500, 160, 30], [890, 140, 26]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#6b3c1c"/>`).join("")}</g>
${star(1120, 470, 30)}${star(1235, 590, 20)}${star(1105, 620, 16)}
<rect x="980" y="30" width="110" height="80" rx="10" fill="#ffd43a"/><rect x="1028" y="38" width="16" height="66" rx="8" fill="#111"/>
<rect x="1260" y="30" width="110" height="80" rx="10" fill="#ffd43a"/><rect x="1308" y="38" width="16" height="66" rx="8" fill="#111"/>
<polygon points="960,-20 1100,15 1100,-10 960,-48" fill="#1f3f1a"/><polygon points="1390,-20 1250,15 1250,-10 1390,-48" fill="#1f3f1a"/>
<rect x="960" y="170" width="430" height="66" rx="10" fill="#5a0f14"/>
${[...Array(9)].map((_, i) => `<polygon points="${972 + i * 47},170 ${1012 + i * 47},170 ${992 + i * 47},205" fill="#fff"/>`).join("")}
${[...Array(8)].map((_, i) => `<polygon points="${995 + i * 47},236 ${1033 + i * 47},236 ${1014 + i * 47},208" fill="#fff"/>`).join("")}
${fallDrips}
<path d="${jetPath}" stroke="#7fe3ff" stroke-width="64" fill="none" stroke-linecap="round" opacity=".85"/>
<path d="${jetPath}" stroke="#ffffff" stroke-width="36" fill="none" stroke-linecap="round"/>
${[[620, 620, 9], [700, 520, 7], [800, 470, 10], [900, 455, 8], [560, 700, 7], [760, 560, 6], [1000, 480, 9]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#dff8ff"/>`).join("")}
${spray.join("")}
${chunks}
<path d="M-40,1080 Q120,880 300,980 T430,900" stroke="#c81e1e" stroke-width="30" fill="none" stroke-linecap="round"/>
${avatar(360, 1040, 0.42, "shock", -48, 12)}
<g transform="rotate(-48 450 852)"><rect x="415" y="836" width="80" height="34" rx="8" fill="#c81e1e"/><rect x="490" y="840" width="34" height="26" rx="4" fill="#d9a520"/></g>
${title(["CAN YOU", "WASH IT?"], 40, 180, 150, "#ffffff")}
</svg>`;
  fs.writeFileSync(path.join(out, "thumb_B_too_big.svg"), svg);
}
makeA();
makeB();
console.log("ok");
