// Browser editor for Apple II hi-res line art. The pure logic at the top
// (parse, serialize, Bresenham, raster, hit testing) also runs under Node.
// The UI at the bottom is browser only.

// PURE:

function parse(text) {
  return JSON.parse(text);
}

// Python json.dumps with the default ", " / ": " separators.
function pyDump(v) {
  if (typeof v === 'number') return String(v);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(pyDump).join(', ') + ']';
  return '{' + Object.keys(v).map(function (k) {
    return JSON.stringify(k) + ': ' + pyDump(v[k]);
  }).join(', ') + '}';
}

// Python json.dumps(v, separators=(',', ':')) for run data.
function compactDump(v) {
  if (Array.isArray(v)) return '[' + v.map(compactDump).join(',') + ']';
  if (typeof v === 'number') return String(v);
  return JSON.stringify(v);
}

function grpLine(g, keys) {
  const head = keys.map(function (k) {
    return JSON.stringify(k) + ': ' + pyDump(g[k]);
  }).join(', ');
  const runs = g.runs.map(function (r) {
    return '      ' + compactDump(r);
  }).join(',\n');
  return '    {' + head + ', "runs": [\n' + runs + '\n    ]}';
}

// Byte-for-byte the layout car.json is kept in.
function serialize(doc) {
  const out = ['{'];
  for (const k of ['width', 'height', 'art_height', 'title', 'caption_rows'])
    out.push('  ' + JSON.stringify(k) + ': ' + pyDump(doc[k]) + ',');
  out.push('  "base": [');
  out.push(doc.base.map(function (g) {
    return grpLine(g, ['name', 'view']);
  }).join(',\n'));
  out.push('  ],');
  out.push('  "overlays": [');
  out.push(doc.overlays.map(function (g) {
    return grpLine(g, ['name', 'hides']);
  }).join(',\n'));
  out.push('  ],');
  out.push('  "labels": [');
  out.push(doc.labels.map(function (l) {
    return '    ' + pyDump(l);
  }).join(',\n'));
  out.push('  ]');
  out.push('}');
  return out.join('\n') + '\n';
}

function pushSegs(segs, runs) {
  for (const r of runs)
    for (let i = 0; i + 1 < r.length; i++)
      segs.push([r[i][0], r[i][1], r[i + 1][0], r[i + 1][1]]);
}

// Segments of the base (minus hidden groups) plus the named overlays,
// in draw order.
function picture(doc, overlayNames) {
  const shown = new Set(overlayNames || []);
  const hide = new Set();
  for (const o of doc.overlays)
    if (shown.has(o.name))
      for (const h of o.hides) hide.add(h);
  const segs = [];
  for (const g of doc.base)
    if (!hide.has(g.name)) pushSegs(segs, g.runs);
  for (const o of doc.overlays)
    if (shown.has(o.name)) pushSegs(segs, o.runs);
  return segs;
}

// The same Bresenham as line() in mkart.py and hgrline.asm, clipped to the
// buffer.
function line(px, w, h, x0, y0, x1, y1) {
  let dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
  const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  let err = dx + dy;
  for (;;) {
    if (x0 >= 0 && x0 < w && y0 >= 0 && y0 < h) px[y0 * w + x0] = 255;
    if (x0 === x1 && y0 === y1) return;
    const e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}

// Writes both on and off glyph pixels.
function text(px, w, h, x, y, msg, font, inv) {
  for (let i = 0; i < msg.length; i++) {
    const g = font[msg.charCodeAt(i) & 0x3F];
    for (let r = 0; r < 8; r++) {
      const row = g[r];
      for (let c = 0; c < 7; c++) {
        const on = (((row >> c) & 1) === 1) !== inv;
        const xx = x + 7 * i + c, yy = y + r;
        if (xx >= 0 && xx < w && yy >= 0 && yy < h)
          px[yy * w + xx] = on ? 255 : 0;
      }
    }
  }
}

// Segments, then title, labels, captions.
function rasterFromSegments(doc, segs, captions, font) {
  const w = doc.width, h = doc.height;
  const px = new Uint8Array(w * h);
  for (const s of segs) line(px, w, h, s[0], s[1], s[2], s[3]);
  const t = doc.title;
  if (t) text(px, w, h, 7 * Math.floor((40 - t.length) / 2), 0, t, font, false);
  for (const lab of doc.labels) {
    const x = lab.x, y = lab.y;
    for (let r = -2; r <= 9; r++)
      for (let c = -2; c <= 8; c++) {
        const xx = x + c, yy = y + r;
        if (xx >= 0 && xx < w && yy >= 0 && yy < h) px[yy * w + xx] = 0;
      }
    text(px, w, h, x, y, lab.key, font, false);
    line(px, w, h, x - 2, y - 2, x + 8, y - 2);
    line(px, w, h, x - 2, y + 9, x + 8, y + 9);
    line(px, w, h, x - 2, y - 2, x - 2, y + 9);
    line(px, w, h, x + 8, y - 2, x + 8, y + 9);
  }
  const rows = doc.caption_rows || [];
  for (let i = 0; i < rows.length && i < captions.length; i++)
    if (captions[i]) text(px, w, h, 0, rows[i], captions[i], font, false);
  return px;
}

function raster(doc, overlayNames, captions, font) {
  return rasterFromSegments(doc, picture(doc, overlayNames), captions, font);
}

function distToSeg(qx, qy, x0, y0, x1, y1) {
  const dx = x1 - x0, dy = y1 - y0;
  const l2 = dx * dx + dy * dy;
  let t = l2 ? ((qx - x0) * dx + (qy - y0) * dy) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  const cx = x0 + t * dx - qx, cy = y0 + t * dy - qy;
  return Math.sqrt(cx * cx + cy * cy);
}

function nearestOnSeg(qx, qy, x0, y0, x1, y1) {
  const dx = x1 - x0, dy = y1 - y0;
  const l2 = dx * dx + dy * dy;
  let t = l2 ? ((qx - x0) * dx + (qy - y0) * dy) / l2 : 0;
  t = Math.max(0, Math.min(1, t));
  return [Math.round(x0 + t * dx), Math.round(y0 + t * dy)];
}

function hitVertex(runs, x, y, tol) {
  let best = null, bd = tol;
  for (let ri = 0; ri < runs.length; ri++)
    for (let pi = 0; pi < runs[ri].length; pi++) {
      const p = runs[ri][pi];
      const d = Math.hypot(p[0] - x, p[1] - y);
      if (d < bd) { bd = d; best = { ri: ri, pi: pi }; }
    }
  return best;
}

function hitSegment(runs, x, y, tol) {
  let best = null, bd = tol;
  for (let ri = 0; ri < runs.length; ri++) {
    const r = runs[ri];
    for (let si = 0; si + 1 < r.length; si++) {
      const d = distToSeg(x, y, r[si][0], r[si][1], r[si + 1][0], r[si + 1][1]);
      if (d < bd) { bd = d; best = { ri: ri, si: si }; }
    }
  }
  return best;
}

function inArt(doc, s) {
  return Math.min(s[0], s[2]) >= 0 && Math.max(s[0], s[2]) < doc.width &&
         Math.min(s[1], s[3]) >= 0 && Math.max(s[1], s[3]) < doc.art_height;
}

// Segments of the displayed picture that leave the art area.
function badSegments(doc, overlayNames) {
  const bad = [];
  for (const s of picture(doc, overlayNames))
    if (!inArt(doc, s)) bad.push({ seg: s });
  return bad;
}

function countSegments(runs) {
  let n = 0;
  for (const r of runs) n += Math.max(0, r.length - 1);
  return n;
}

if (typeof module !== 'undefined') module.exports = {
  parse: parse, serialize: serialize, picture: picture, line: line,
  text: text, raster: raster, rasterFromSegments: rasterFromSegments,
  distToSeg: distToSeg, nearestOnSeg: nearestOnSeg,
  hitVertex: hitVertex, hitSegment: hitSegment,
  badSegments: badSegments, countSegments: countSegments
};

// EDITOR:

if (typeof document !== 'undefined' && document.getElementById('screen')) {

const DEFAULT_TEXT = `
{
  "width": 280,
  "height": 192,
  "art_height": 168,
  "title": "CHRYSLER ELECTRONIC VOICE ALERT",
  "caption_rows": [176, 184],
  "base": [
    {"name": "S_BODY", "view": "side", "runs": [
      [[58,59],[37,58],[36,48],[37,36],[92,34],[128,15],[177,15],[181,16],[184,18],[196,27],[200,28],[238,32],[242,33],[243,48],[242,58],[213,59]],
      [[178,59],[93,59]],
      [[93,59],[93,55],[92,51],[90,47],[88,44],[84,41],[80,40],[75,39],[71,40],[67,41],[63,44],[60,47],[58,51],[57,55],[58,59]],
      [[213,59],[213,55],[212,51],[210,47],[208,44],[204,41],[200,40],[195,39],[191,40],[187,41],[183,44],[180,47],[178,51],[177,55],[178,59]]
    ]},
    {"name": "S_BUMPERS", "view": "side", "runs": [
      [[31,57],[39,57],[39,49],[31,49],[31,57]],
      [[31,53],[39,53]],
      [[241,57],[249,57],[249,49],[241,49],[241,57]],
      [[241,53],[249,53]]
    ]},
    {"name": "S_GLASS", "view": "side", "runs": [
      [[102,31],[123,19],[127,18],[146,18],[146,31],[102,31]],
      [[151,31],[151,18],[170,18],[174,20],[176,31],[151,31]],
      [[182,30],[182,20],[183,20],[192,29],[192,30],[182,30]]
    ]},
    {"name": "S_DOORS", "view": "side", "runs": [
      [[96,33],[96,58]],
      [[148,31],[148,58]],
      [[178,15],[178,31],[181,32],[182,45]],
      [[135,37],[141,37]],
      [[174,37],[180,37]]
    ]},
    {"name": "S_TRIM", "view": "side", "runs": [
      [[39,48],[59,48]],
      [[91,48],[179,48]],
      [[211,48],[241,48]]
    ]},
    {"name": "S_LAMPS", "view": "side", "runs": [
      [[37,46],[43,46],[43,40],[37,40],[37,46]],
      [[235,45],[242,45],[242,36],[235,36],[235,45]]
    ]},
    {"name": "S_WHEELS", "view": "side", "runs": [
      [[90,56],[90,53],[88,49],[86,47],[83,44],[79,43],[75,43],[71,43],[68,44],[65,47],[62,49],[61,53],[60,56],[61,60],[62,63],[65,66],[68,68],[71,70],[75,70],[79,70],[83,68],[86,66],[88,63],[90,60],[90,56]],
      [[80,56],[79,54],[77,52],[74,52],[71,54],[70,56],[71,59],[74,60],[77,60],[79,59],[80,56]],
      [[210,56],[210,53],[208,49],[206,47],[203,44],[199,43],[195,43],[191,43],[188,44],[185,47],[182,49],[181,53],[180,56],[181,60],[182,63],[185,66],[188,68],[191,70],[195,70],[199,70],[203,68],[206,66],[208,63],[210,60],[210,56]],
      [[200,56],[199,54],[197,52],[194,52],[191,54],[190,56],[191,59],[194,60],[197,60],[199,59],[200,56]]
    ]},
    {"name": "T_BODY", "view": "top", "runs": [
      [[37,83],[39,81],[241,81],[243,83],[243,151],[241,153],[39,153],[37,151],[37,83]],
      [[37,84],[33,84],[32,85],[32,149],[33,150],[37,150]],
      [[243,84],[247,84],[248,85],[248,149],[247,150],[243,150]]
    ]},
    {"name": "T_GLASS", "view": "top", "runs": [
      [[96,86],[96,148]],
      [[96,86],[127,90],[181,90],[192,86]],
      [[96,148],[127,144],[181,144],[192,148]],
      [[127,90],[127,144]],
      [[181,90],[181,144]],
      [[192,86],[192,148]]
    ]},
    {"name": "T_SIDES", "view": "top", "runs": [
      [[96,84],[192,84]],
      [[96,150],[192,150]],
      [[38,86],[96,86]],
      [[38,148],[96,148]]
    ]},
    {"name": "T_DOORS", "view": "top", "runs": [
      [[148,84],[148,81]],
      [[148,150],[148,153]],
      [[183,84],[183,81]],
      [[183,150],[183,153]],
      [[96,84],[96,81]],
      [[96,150],[96,153]]
    ]},
    {"name": "T_MIRRORS", "view": "top", "runs": [
      [[98,81],[99,77],[104,77],[104,81]],
      [[98,153],[99,157],[104,157],[104,153]]
    ]},
    {"name": "T_TRUNK", "view": "top", "runs": [
      [[195,88],[238,88],[238,146],[195,146],[195,88]]
    ]},
    {"name": "T_CABIN", "view": "top", "runs": [
      [[106,87],[104,95],[104,139],[106,147]],
      [[133,121],[153,121],[153,140],[133,140],[133,121]],
      [[148,121],[148,140]],
      [[133,113],[153,113],[153,94],[133,94],[133,113]],
      [[148,113],[148,94]],
      [[160,94],[177,94],[177,140],[160,140],[160,94]],
      [[172,94],[172,140]]
    ]},
    {"name": "T_WHEEL", "view": "top", "runs": [
      [[115,133],[115,137],[114,140],[112,141],[111,140],[110,137],[109,133],[110,130],[111,127],[112,126],[114,127],[115,130],[115,133]]
    ]},
    {"name": "T_RADIATOR", "view": "top", "runs": [
      [[44,97],[48,97],[48,137],[44,137],[44,97]]
    ]},
    {"name": "T_ENGINE", "view": "top", "runs": [
      [[58,94],[78,94],[78,121],[58,121],[58,94]]
    ]},
    {"name": "T_AIRCLEAN", "view": "top", "runs": [
      [[75,107],[75,110],[73,112],[71,113],[68,114],[65,113],[63,112],[61,110],[61,107],[61,105],[63,102],[65,101],[68,101],[71,101],[73,102],[75,105],[75,107]]
    ]},
    {"name": "T_TRANS", "view": "top", "runs": [
      [[61,122],[76,122],[78,126],[75,132],[63,132],[61,130],[61,122]]
    ]},
    {"name": "T_BATTERY", "view": "top", "runs": [
      [[49,136],[62,136],[62,147],[49,147],[49,136]]
    ]},
    {"name": "T_WASHER", "view": "top", "runs": [
      [[46,87],[55,87],[55,94],[46,94],[46,87]]
    ]},
    {"name": "T_BOOSTER", "view": "top", "runs": [
      [[94,139],[94,141],[92,143],[90,144],[87,144],[85,143],[83,141],[82,139],[83,137],[85,135],[87,134],[90,134],[92,135],[94,137],[94,139]],
      [[78,137],[82,137],[82,141],[78,141],[78,137]]
    ]},
    {"name": "T_COOLANT", "view": "top", "runs": [
      [[85,88],[93,88],[93,95],[85,95],[85,88]]
    ]},
    {"name": "T_STRUTS", "view": "top", "runs": [
      [[83,90],[82,92],[80,92],[78,92],[77,90],[78,88],[80,87],[82,88],[83,90]],
      [[83,144],[82,146],[80,147],[78,146],[77,144],[78,142],[80,142],[82,142],[83,144]]
    ]}
  ],
  "overlays": [
    {"name": "DOOR 1", "hides": [], "runs": [
      [[96,153],[148,159],[148,153]]
    ]},
    {"name": "DOOR 2", "hides": [], "runs": [
      [[96,81],[148,75],[148,81]]
    ]},
    {"name": "DOOR 3", "hides": [], "runs": [
      [[148,153],[183,157],[183,153]]
    ]},
    {"name": "DOOR 4", "hides": [], "runs": [
      [[148,81],[183,77],[183,81]]
    ]},
    {"name": "TRUNK OPEN", "hides": ["T_TRUNK"], "runs": [
      [[198,28],[228,11],[229,13],[201,29]],
      [[200,104],[234,104],[234,130],[200,130],[200,104]],
      [[212,110],[222,110],[222,124],[212,124],[212,110]],
      [[214,112],[220,112],[220,116],[214,116],[214,112]],
      [[222,114],[225,114],[225,120],[223,122]]
    ]},
    {"name": "HEADLAMPS", "hides": [], "runs": [
      [[30,47],[6,52]],
      [[30,43],[6,43]],
      [[30,40],[6,34]],
      [[31,90],[8,96]],
      [[31,90],[8,90]],
      [[31,90],[8,83]],
      [[31,144],[8,138]],
      [[31,144],[8,144]],
      [[31,144],[8,151]]
    ]},
    {"name": "TAIL LAMPS", "hides": [], "runs": [
      [[250,42],[262,45]],
      [[250,40],[262,40]],
      [[250,39],[262,36]]
    ]},
    {"name": "BRAKE LAMPS", "hides": [], "runs": [
      [[236,43],[241,43]],
      [[236,40],[241,40]],
      [[236,38],[241,38]],
      [[250,45],[272,51]],
      [[250,43],[272,46]],
      [[250,40],[272,40]],
      [[250,38],[272,35]],
      [[250,36],[272,29]],
      [[249,90],[267,95]],
      [[249,90],[267,90]],
      [[249,90],[267,84]],
      [[249,144],[267,139]],
      [[249,144],[267,144]],
      [[249,144],[267,150]]
    ]},
    {"name": "BELT ON", "hides": [], "runs": [
      [[152,139],[142,122]]
    ]},
    {"name": "BELT OFF", "hides": [], "runs": [
      [[152,142],[135,142]]
    ]},
    {"name": "KEY", "hides": [], "runs": [
      [[109,133],[108,135],[107,135],[106,133],[107,132],[108,132],[109,133]],
      [[109,133],[114,133]]
    ]},
    {"name": "PARK BRAKE", "hides": [], "runs": [
      [[124,146],[123,148],[122,150],[120,151],[117,152],[115,151],[113,150],[111,148],[111,146],[111,143],[113,141],[115,140],[117,139],[120,140],[122,141],[123,143],[124,146]]
    ]},
    {"name": "DISC PADS", "hides": [], "runs": [
      [[85,56],[85,53],[83,50],[80,48],[77,47],[73,47],[70,48],[67,50],[66,53],[65,56],[66,59],[67,62],[70,64],[73,65],[77,65],[80,64],[83,62],[85,59],[85,56]],
      [[81,52],[86,52],[86,48],[81,48],[81,52]]
    ]}
  ],
  "labels": [
    {"key": "2", "x": 119, "y": 42},
    {"key": "4", "x": 161, "y": 42},
    {"key": "H", "x": 63, "y": 23},
    {"key": "L", "x": 7, "y": 29},
    {"key": "R", "x": 259, "y": 29},
    {"key": "E", "x": 259, "y": 47},
    {"key": "T", "x": 217, "y": 36},
    {"key": "D", "x": 70, "y": 71},
    {"key": "1", "x": 119, "y": 154},
    {"key": "3", "x": 161, "y": 154},
    {"key": "W", "x": 49, "y": 69},
    {"key": "C", "x": 14, "y": 113},
    {"key": "O", "x": 63, "y": 103},
    {"key": "P", "x": 63, "y": 123},
    {"key": "G", "x": 49, "y": 137},
    {"key": "U", "x": 84, "y": 135},
    {"key": "K", "x": 119, "y": 129},
    {"key": "B", "x": 112, "y": 142},
    {"key": "S", "x": 133, "y": 131},
    {"key": "A", "x": 112, "y": 98},
    {"key": "F", "x": 203, "y": 94}
  ]
}
`;

const PXW = 3, PXH = 3.28;
const AUTOSAVE_KEY = 'ufonic-chrysler-art-autosave';
const UNDO_MAX = 500;

var doc = parse(DEFAULT_TEXT);
var captions = ['SPACE HORN    CTRL-Q QUIT    CARD SLOT 4', ''];
var shownBase = new Set(doc.base.map(function (g) { return g.name; }));
var shownOverlays = new Set();
var active = { type: 'base', i: 0 };
var mode = 'select';
var selRun = null, selVertex = null, selLabel = -1;
var newRunRi = null, newRunPushed = false;
var pendingLabelKey = 'N';
var zoom = 1, grid = false;
var undoStack = [], redoStack = [];
var drag = null;

var canvas = document.getElementById('screen');
var ctx = canvas.getContext('2d');

function $(id) { return document.getElementById(id); }
function h(tag, cls, txt) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt !== undefined) e.textContent = txt;
  return e;
}
function snap7(x) { return 7 * Math.round(x / 7); }
function pxX(x) { return x * PXW * zoom; }
function pxY(y) { return Math.round(y * PXH * zoom); }
function pickTol() { return Math.max(1.5, 8 / (PXW * zoom)); }

function activeGroup() {
  const list = active.type === 'base' ? doc.base : doc.overlays;
  if (!list.length || active.i >= list.length) return null;
  return list[active.i];
}

function displayedInfo() {
  const segs = [], bad = [];
  const hide = new Set();
  doc.overlays.forEach(function (o) {
    if (shownOverlays.has(o.name))
      o.hides.forEach(function (n) { hide.add(n); });
  });
  function walk(name, runs) {
    runs.forEach(function (r, ri) {
      for (let i = 0; i + 1 < r.length; i++) {
        const s = [r[i][0], r[i][1], r[i + 1][0], r[i + 1][1]];
        segs.push(s);
        if (!inArt(doc, s)) bad.push({ name: name + ' run ' + (ri + 1), seg: s });
      }
    });
  }
  doc.base.forEach(function (g) {
    if (!hide.has(g.name) && shownBase.has(g.name)) walk(g.name, g.runs);
  });
  doc.overlays.forEach(function (o) {
    if (shownOverlays.has(o.name)) walk(o.name, o.runs);
  });
  return { segs: segs, bad: bad };
}

function resizeCanvas() {
  canvas.width = Math.round(doc.width * PXW * zoom);
  canvas.height = Math.round(doc.height * PXH * zoom);
  canvas.style.width = canvas.width + 'px';
  canvas.style.height = canvas.height + 'px';
}

function evtPixel(e) {
  const r = canvas.getBoundingClientRect();
  const cx = e.clientX - r.left, cy = e.clientY - r.top;
  const x = Math.floor(cx / (PXW * zoom));
  const y = Math.floor(cy / (PXH * zoom));
  return {
    x: Math.max(0, Math.min(doc.width - 1, x)),
    y: Math.max(0, Math.min(doc.height - 1, y))
  };
}

function plot(x, y) {
  const y0 = pxY(y);
  ctx.fillRect(pxX(x), y0, PXW * zoom, pxY(y + 1) - y0);
}

function colorLine(x0, y0, x1, y1) {
  let dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
  const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  let err = dx + dy;
  for (;;) {
    if (x0 >= 0 && x0 < doc.width && y0 >= 0 && y0 < doc.height) plot(x0, y0);
    if (x0 === x1 && y0 === y1) return;
    const e2 = 2 * err;
    if (e2 >= dy) { err += dy; x0 += sx; }
    if (e2 <= dx) { err += dx; y0 += sy; }
  }
}

function renderCanvas() {
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  const info = displayedInfo();
  const good = info.segs.filter(function (s) { return inArt(doc, s); });
  const px = rasterFromSegments(doc, good, captions, APPLE_FONT);
  ctx.fillStyle = '#fff';
  const w = doc.width;
  for (let y = 0; y < doc.height; y++) {
    const y0 = pxY(y), hh = pxY(y + 1) - y0;
    for (let x = 0; x < w; x++)
      if (px[y * w + x]) ctx.fillRect(pxX(x), y0, PXW * zoom, hh);
  }
  if (info.bad.length) {
    ctx.fillStyle = '#f00';
    info.bad.forEach(function (b) {
      colorLine(b.seg[0], b.seg[1], b.seg[2], b.seg[3]);
    });
  }
  ctx.fillStyle = '#f00';
  ctx.fillRect(0, pxY(doc.art_height), canvas.width, Math.max(1, Math.round(zoom)));
  if (grid) {
    ctx.fillStyle = 'rgba(255,255,255,0.15)';
    for (let x = 7; x < doc.width; x += 7)
      ctx.fillRect(pxX(x), 0, 1, canvas.height);
    for (let y = 8; y < doc.height; y += 8)
      ctx.fillRect(0, pxY(y), canvas.width, 1);
  }
  const g = activeGroup();
  if (g && mode !== 'label') {
    const s = Math.max(4, 2 * zoom + 2);
    g.runs.forEach(function (r, ri) {
      const hot = selRun && selRun.ri === ri;
      r.forEach(function (p, pi) {
        const cx = pxX(p[0]) + PXW * zoom / 2 - s / 2;
        const cy = pxY(p[1]) + (pxY(p[1] + 1) - pxY(p[1])) / 2 - s / 2;
        const isV = selVertex && selVertex.ri === ri && selVertex.pi === pi;
        ctx.fillStyle = isV ? '#0ff' : hot ? '#ff0' : '#f80';
        ctx.fillRect(cx, cy, s, s);
        ctx.strokeStyle = '#000';
        ctx.strokeRect(cx + 0.5, cy + 0.5, s - 1, s - 1);
      });
    });
  }
  if (selLabel >= 0 && doc.labels[selLabel]) {
    const lab = doc.labels[selLabel];
    ctx.strokeStyle = '#0ff';
    ctx.lineWidth = Math.max(1, zoom);
    ctx.strokeRect(pxX(lab.x - 2) + 0.5, pxY(lab.y - 2) + 0.5,
                   11 * PXW * zoom, pxY(lab.y + 10) - pxY(lab.y - 2));
    ctx.lineWidth = 1;
  }
}

function hitLabel(x, y) {
  for (let i = doc.labels.length - 1; i >= 0; i--) {
    const l = doc.labels[i];
    if (x >= l.x - 2 && x <= l.x + 8 && y >= l.y - 2 && y <= l.y + 9) return i;
  }
  return -1;
}

function buildGroups() {
  function rows(container, list, shownSet, kind) {
    container.textContent = '';
    list.forEach(function (g, i) {
      const row = h('div', 'grow');
      const cb = h('input');
      cb.type = 'checkbox';
      cb.checked = shownSet.has(g.name);
      cb.addEventListener('change', function () {
        if (cb.checked) shownSet.add(g.name); else shownSet.delete(g.name);
        renderAll();
      });
      const nm = h('span',
        'gname' + (active.type === kind && active.i === i ? ' act' : ''), g.name);
      nm.addEventListener('click', function () {
        active = { type: kind, i: i };
        selRun = selVertex = null;
        renderAll();
      });
      const note = kind === 'base'
        ? g.view
        : (g.hides.length ? 'hides ' + g.hides.length : '');
      row.appendChild(cb);
      row.appendChild(nm);
      row.appendChild(h('span', 'cnt',
        countSegments(g.runs) + ' seg' + (note ? ' ' + note : '')));
      container.appendChild(row);
    });
  }
  rows($('baseList'), doc.base, shownBase, 'base');
  rows($('ovlList'), doc.overlays, shownOverlays, 'overlay');
}

function buildHides() {
  const sec = $('hidesSec');
  const g = activeGroup();
  if (!g || active.type !== 'overlay') { sec.style.display = 'none'; return; }
  sec.style.display = '';
  $('hidesTitle').textContent = 'HIDES WHEN ' + g.name + ' SHOWS';
  const box = $('hidesList');
  box.textContent = '';
  doc.base.forEach(function (b) {
    const row = h('div', 'grow');
    const cb = h('input');
    cb.type = 'checkbox';
    cb.checked = g.hides.indexOf(b.name) !== -1;
    cb.addEventListener('change', function () {
      checkpoint();
      const i = g.hides.indexOf(b.name);
      if (cb.checked && i === -1) g.hides.push(b.name);
      if (!cb.checked && i !== -1) g.hides.splice(i, 1);
      renderAll();
    });
    row.appendChild(cb);
    row.appendChild(h('span', 'gname', b.name));
    box.appendChild(row);
  });
}

function buildLabels() {
  const box = $('labelList');
  box.textContent = '';
  doc.labels.forEach(function (l, i) {
    const row = h('div', 'lrow' + (i === selLabel ? ' sel' : ''),
      l.key + '  (' + l.x + ',' + l.y + ')');
    row.addEventListener('click', function () {
      selLabel = i;
      selRun = selVertex = null;
      $('labelKey').value = l.key;
      renderAll();
    });
    box.appendChild(row);
  });
  $('labelKey').value = selLabel >= 0 && doc.labels[selLabel]
    ? doc.labels[selLabel].key : '';
}

function buildWarnings() {
  const box = $('warnList');
  box.textContent = '';
  const bad = displayedInfo().bad;
  if (!bad.length) {
    box.appendChild(h('div', 'muted', 'No segments outside X 0-279, Y 0-167.'));
    return;
  }
  bad.slice(0, 50).forEach(function (b) {
    box.appendChild(h('div', 'warn',
      b.name + ' (' + b.seg[0] + ',' + b.seg[1] + ')-(' +
      b.seg[2] + ',' + b.seg[3] + ')'));
  });
  if (bad.length > 50)
    box.appendChild(h('div', 'muted', '...and ' + (bad.length - 50) + ' more'));
}

function updateCounts() {
  let base = 0, all = 0;
  doc.base.forEach(function (g) { base += countSegments(g.runs); });
  all = base;
  doc.overlays.forEach(function (o) { all += countSegments(o.runs); });
  const g = activeGroup();
  const box = $('counts');
  box.textContent = '';
  box.appendChild(h('div', '', 'Base segments: ' + base));
  box.appendChild(h('div', '', 'Base + all overlays: ' + all));
  if (g) box.appendChild(h('div', '', 'Active: ' + g.name +
    (active.type === 'base' ? ' (' + g.view + ')' : ' (overlay)') +
    ', ' + g.runs.length + ' runs'));
}

function renderAll() {
  renderCanvas();
  buildGroups();
  buildHides();
  buildLabels();
  buildWarnings();
  updateCounts();
  updateModeButtons();
}

function statusMsg() {
  if (mode === 'newrun')
    return 'New run: click points, Enter or double click to end, Esc cancels.';
  if (mode === 'flip') return 'Flip: click the mirror X position.';
  if (mode === 'label') return 'Place label: click where it goes.';
  return 'Drag a vertex. Double click a segment to insert a vertex. ' +
         'Shift-drag or arrows move a run. Delete removes the selection.';
}
function setStatus(extra) {
  $('status').textContent = (extra ? extra + '  ' : '') + statusMsg();
}

function pushUndo(text) {
  undoStack.push(text);
  if (undoStack.length > UNDO_MAX) undoStack.shift();
  redoStack.length = 0;
  autosave();
}
function checkpoint() { pushUndo(serialize(doc)); }

function fixSelections() {
  if (!doc.base.length && !doc.overlays.length) active = { type: 'base', i: 0 };
  var list = active.type === 'base' ? doc.base : doc.overlays;
  if (!list.length) {
    active = doc.base.length ? { type: 'base', i: 0 } : { type: 'overlay', i: 0 };
    list = active.type === 'base' ? doc.base : doc.overlays;
  }
  if (active.i >= list.length) active.i = 0;
  shownBase = new Set(doc.base.map(function (g) { return g.name; }));
  const ov = new Set();
  doc.overlays.forEach(function (o) {
    if (shownOverlays.has(o.name)) ov.add(o.name);
  });
  shownOverlays = ov;
  const g = activeGroup();
  if (selRun && (!g || selRun.ri >= g.runs.length)) selRun = null;
  if (selVertex && (!g || !selRun || selVertex.ri !== selRun.ri ||
                    selVertex.pi >= g.runs[selVertex.ri].length))
    selVertex = null;
  if (selLabel >= doc.labels.length) selLabel = -1;
  if (mode === 'newrun' || mode === 'flip' || mode === 'label') {
    mode = 'select';
    newRunRi = null;
  }
}

function undo() {
  if (!undoStack.length) return;
  redoStack.push(serialize(doc));
  doc = parse(undoStack.pop());
  fixSelections();
  autosave();
  renderAll();
}
function redo() {
  if (!redoStack.length) return;
  undoStack.push(serialize(doc));
  doc = parse(redoStack.pop());
  fixSelections();
  autosave();
  renderAll();
}

function autosave() {
  try { localStorage.setItem(AUTOSAVE_KEY, serialize(doc)); } catch (e) {}
}

function loadDoc(text) {
  let d;
  try { d = parse(text); } catch (e) { alert('Not valid JSON: ' + e.message); return; }
  if (!d || !Array.isArray(d.base) || !Array.isArray(d.overlays) ||
      !Array.isArray(d.labels) || !d.width || !d.height) {
    alert('Not a car.json style document.');
    return;
  }
  doc = d;
  shownBase = new Set(doc.base.map(function (g) { return g.name; }));
  shownOverlays = new Set();
  active = doc.base.length ? { type: 'base', i: 0 }
                           : { type: 'overlay', i: 0 };
  selRun = selVertex = null;
  selLabel = -1;
  mode = 'select';
  newRunRi = null;
  undoStack = [];
  redoStack = [];
  resizeCanvas();
  autosave();
  renderAll();
}

function saveFile() {
  const blob = new Blob([serialize(doc)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'car.json';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
}

function startDrag(kind, p, idx) {
  let orig;
  if (kind === 'vertex')
    orig = activeGroup().runs[idx.ri][idx.pi].slice();
  else if (kind === 'run')
    orig = activeGroup().runs[idx].map(function (q) { return q.slice(); });
  else
    orig = { x: doc.labels[idx].x, y: doc.labels[idx].y };
  drag = { kind: kind, idx: idx, sx: p.x, sy: p.y, orig: orig,
           undoText: serialize(doc), pushed: false };
}

function applyDrag(dx, dy) {
  if (drag.kind === 'vertex') {
    const g = activeGroup();
    g.runs[drag.idx.ri][drag.idx.pi] = [drag.orig[0] + dx, drag.orig[1] + dy];
  } else if (drag.kind === 'run') {
    const run = activeGroup().runs[drag.idx];
    drag.orig.forEach(function (q, i) { run[i] = [q[0] + dx, q[1] + dy]; });
  } else {
    const lab = doc.labels[drag.idx];
    lab.x = snap7(drag.orig.x + dx);
    lab.y = drag.orig.y + dy;
  }
  autosave();
}

function addNewRunPoint(x, y) {
  const g = activeGroup();
  if (!g) return;
  if (newRunRi === null) {
    pushUndo(serialize(doc));
    newRunPushed = true;
    g.runs.push([[x, y]]);
    newRunRi = g.runs.length - 1;
    selRun = { ri: newRunRi };
    selVertex = null;
    selLabel = -1;
  } else {
    const run = g.runs[newRunRi];
    const last = run[run.length - 1];
    if (last[0] !== x || last[1] !== y) run.push([x, y]);
  }
  autosave();
  renderAll();
}

function removeNewRun() {
  const g = activeGroup();
  if (g && newRunRi !== null && g.runs[newRunRi] !== undefined) {
    g.runs.splice(newRunRi, 1);
    if (newRunPushed) { undoStack.pop(); newRunPushed = false; }
    autosave();
  }
  newRunRi = null;
  if (selRun === null) selRun = null;
  selVertex = null;
}

function finishNewRun() {
  if (mode !== 'newrun') return;
  const g = activeGroup();
  if (g && newRunRi !== null &&
      (!g.runs[newRunRi] || g.runs[newRunRi].length < 2))
    removeNewRun();
  newRunRi = null;
  newRunPushed = false;
  mode = 'select';
  renderAll();
}

function cancelMode() {
  if (mode === 'newrun') removeNewRun();
  mode = 'select';
  newRunRi = null;
  newRunPushed = false;
  renderAll();
}

function updateModeButtons() {
  $('btnNewRun').className = mode === 'newrun' ? 'on' : '';
  $('btnFlip').className = mode === 'flip' ? 'on' : '';
  $('btnAddLabel').className = mode === 'label' ? 'on' : '';
}

function doFlip(X) {
  const g = activeGroup();
  if (!g || selRun === null) { mode = 'select'; renderAll(); return; }
  checkpoint();
  g.runs[selRun.ri].forEach(function (p) { p[0] = 2 * X - p[0]; });
  mode = 'select';
  renderAll();
}

function placeLabel(x, y) {
  checkpoint();
  doc.labels.push({ key: pendingLabelKey, x: snap7(x), y: y });
  selLabel = doc.labels.length - 1;
  selRun = selVertex = null;
  mode = 'select';
  renderAll();
}

function deleteSelection() {
  if (mode === 'newrun' && newRunRi !== null) {
    const g = activeGroup();
    const run = g && g.runs[newRunRi];
    if (run && run.length > 1) {
      run.pop();
      renderAll();
    }
    return;
  }
  if (selLabel >= 0 && doc.labels[selLabel]) {
    checkpoint();
    doc.labels.splice(selLabel, 1);
    selLabel = -1;
    renderAll();
    return;
  }
  const g = activeGroup();
  if (g && selVertex) {
    checkpoint();
    const run = g.runs[selVertex.ri];
    run.splice(selVertex.pi, 1);
    if (run.length < 2) {
      g.runs.splice(selVertex.ri, 1);
      selRun = null;
    }
    selVertex = null;
    renderAll();
    return;
  }
  if (g && selRun) {
    checkpoint();
    g.runs.splice(selRun.ri, 1);
    selRun = null;
    renderAll();
  }
}

function nudge(dx, dy) {
  if (mode === 'newrun') return;
  if (selLabel >= 0 && doc.labels[selLabel]) {
    checkpoint();
    const lab = doc.labels[selLabel];
    lab.x = snap7(lab.x + dx * 7);
    lab.y += dy;
    autosave();
    renderAll();
    return;
  }
  const g = activeGroup();
  if (g && selRun) {
    checkpoint();
    g.runs[selRun.ri].forEach(function (p) {
      p[0] += dx;
      p[1] += dy;
    });
    autosave();
    renderAll();
  }
}

// The group under the mouse. The active group wins, then shown overlays,
// then shown base groups. A vertex anywhere beats a segment.
function pickGroup(x, y, tol) {
  const hide = new Set();
  doc.overlays.forEach(function (o) {
    if (shownOverlays.has(o.name)) o.hides.forEach(function (n) { hide.add(n); });
  });
  const order = [active];
  doc.overlays.forEach(function (o, i) {
    if (shownOverlays.has(o.name)) order.push({ type: 'overlay', i: i });
  });
  doc.base.forEach(function (b, i) {
    if (shownBase.has(b.name) && !hide.has(b.name)) order.push({ type: 'base', i: i });
  });
  function runsOf(c) {
    const g = (c.type === 'base' ? doc.base : doc.overlays)[c.i];
    return g ? g.runs : [];
  }
  for (const c of order)
    if (hitVertex(runsOf(c), x, y, tol)) return c;
  for (const c of order)
    if (hitSegment(runsOf(c), x, y, tol)) return c;
  return null;
}

canvas.addEventListener('mousedown', function (e) {
  if (e.button !== 0) return;
  const p = evtPixel(e);
  if (mode === 'newrun') { addNewRunPoint(p.x, p.y); return; }
  if (mode === 'flip') { doFlip(p.x); return; }
  if (mode === 'label') { placeLabel(p.x, p.y); return; }
  const li = hitLabel(p.x, p.y);
  if (li !== -1) {
    selLabel = li;
    selRun = selVertex = null;
    $('labelKey').value = doc.labels[li].key;
    startDrag('label', p, li);
    renderAll();
    return;
  }
  const tol = pickTol();
  const pick = pickGroup(p.x, p.y, tol);
  if (pick) active = pick;
  const g = activeGroup();
  if (g) {
    const v = hitVertex(g.runs, p.x, p.y, tol);
    if (v && e.shiftKey) {
      selRun = { ri: v.ri };
      selVertex = null;
      selLabel = -1;
      startDrag('run', p, v.ri);
      renderAll();
      return;
    }
    if (v) {
      selVertex = v;
      selRun = { ri: v.ri };
      selLabel = -1;
      startDrag('vertex', p, v);
      renderAll();
      return;
    }
    const s = hitSegment(g.runs, p.x, p.y, tol);
    if (s) {
      selRun = { ri: s.ri };
      selVertex = null;
      selLabel = -1;
      if (e.shiftKey) startDrag('run', p, s.ri);
      renderAll();
      return;
    }
  }
  selRun = selVertex = null;
  selLabel = -1;
  renderAll();
});

canvas.addEventListener('dblclick', function (e) {
  if (mode === 'newrun') { finishNewRun(); return; }
  const p = evtPixel(e);
  const g = activeGroup();
  if (!g) return;
  const s = hitSegment(g.runs, p.x, p.y, pickTol());
  if (!s) return;
  const a = g.runs[s.ri][s.si], b = g.runs[s.ri][s.si + 1];
  checkpoint();
  g.runs[s.ri].splice(s.si + 1, 0,
    nearestOnSeg(p.x, p.y, a[0], a[1], b[0], b[1]));
  selRun = { ri: s.ri };
  selVertex = { ri: s.ri, pi: s.si + 1 };
  selLabel = -1;
  renderAll();
});

canvas.addEventListener('mousemove', function (e) {
  if (drag) return;
  const p = evtPixel(e);
  setStatus('X ' + p.x + '  Y ' + p.y);
});

window.addEventListener('mousemove', function (e) {
  if (!drag) return;
  const p = evtPixel(e);
  const dx = p.x - drag.sx, dy = p.y - drag.sy;
  setStatus('X ' + p.x + '  Y ' + p.y);
  if (!drag.pushed && dx === 0 && dy === 0) return;
  if (!drag.pushed) {
    pushUndo(drag.undoText);
    drag.pushed = true;
  }
  applyDrag(dx, dy);
  renderAll();
});

window.addEventListener('mouseup', function () { drag = null; });

window.addEventListener('keydown', function (e) {
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' ||
            t.tagName === 'SELECT'))
    return;
  const ctrl = e.ctrlKey || e.metaKey;
  if (ctrl && !e.shiftKey && e.key === 'z') { e.preventDefault(); undo(); return; }
  if (ctrl && (e.key === 'y' || (e.shiftKey && e.key === 'Z'))) {
    e.preventDefault(); redo(); return;
  }
  if (e.key === 'Escape') { cancelMode(); return; }
  if (e.key === 'Enter' && mode === 'newrun') { finishNewRun(); return; }
  if (e.key === 'Delete' || e.key === 'Backspace') {
    e.preventDefault();
    deleteSelection();
    return;
  }
  const d = { ArrowLeft: [-1, 0], ArrowRight: [1, 0],
              ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
  if (d) { e.preventDefault(); nudge(d[0], d[1]); }
});

$('btnOpen').addEventListener('click', function () { $('fileInput').click(); });
$('fileInput').addEventListener('change', function () {
  const f = this.files[0];
  if (!f) return;
  const rd = new FileReader();
  rd.onload = function () { loadDoc(rd.result); };
  rd.readAsText(f);
  this.value = '';
});
$('btnSave').addEventListener('click', saveFile);
$('zoom').addEventListener('change', function () {
  zoom = +this.value;
  resizeCanvas();
  renderAll();
});
$('grid').addEventListener('change', function () {
  grid = this.checked;
  renderCanvas();
});
$('btnUndo').addEventListener('click', undo);
$('btnRedo').addEventListener('click', redo);

$('btnNewRun').addEventListener('click', function () {
  if (mode === 'newrun') { cancelMode(); return; }
  cancelMode();
  mode = 'newrun';
  newRunRi = null;
  newRunPushed = false;
  renderAll();
});
$('btnDelRun').addEventListener('click', function () {
  const g = activeGroup();
  if (!g || selRun === null) { setStatus('Select a run first.'); return; }
  checkpoint();
  g.runs.splice(selRun.ri, 1);
  selRun = null;
  selVertex = null;
  renderAll();
});
$('btnDupRun').addEventListener('click', function () {
  const g = activeGroup();
  if (!g || selRun === null) { setStatus('Select a run first.'); return; }
  checkpoint();
  const copy = g.runs[selRun.ri].map(function (p) { return p.slice(); });
  g.runs.splice(selRun.ri + 1, 0, copy);
  selRun = { ri: selRun.ri + 1 };
  selVertex = null;
  renderAll();
});
$('btnFlip').addEventListener('click', function () {
  if (selRun === null) { setStatus('Select a run first.'); return; }
  cancelMode();
  mode = 'flip';
  renderAll();
});

$('btnAddGroup').addEventListener('click', function () {
  const name = prompt('New base group name');
  if (!name) return;
  const view = (prompt('View (side or top)', 'side') || 'side').toLowerCase();
  checkpoint();
  doc.base.push({ name: name, view: view === 'top' ? 'top' : 'side', runs: [] });
  shownBase.add(name);
  active = { type: 'base', i: doc.base.length - 1 };
  selRun = selVertex = null;
  renderAll();
});
$('btnAddOvl').addEventListener('click', function () {
  const name = prompt('New overlay name');
  if (!name) return;
  checkpoint();
  doc.overlays.push({ name: name, hides: [], runs: [] });
  active = { type: 'overlay', i: doc.overlays.length - 1 };
  selRun = selVertex = null;
  renderAll();
});
$('btnRename').addEventListener('click', function () {
  const g = activeGroup();
  if (!g) return;
  const name = prompt('New name', g.name);
  if (!name || name === g.name) return;
  checkpoint();
  const old = g.name;
  g.name = name;
  if (active.type === 'base') {
    doc.overlays.forEach(function (o) {
      const i = o.hides.indexOf(old);
      if (i !== -1) o.hides[i] = name;
    });
    if (shownBase.delete(old)) shownBase.add(name);
  } else if (shownOverlays.delete(old)) shownOverlays.add(name);
  renderAll();
});
$('btnDelGroup').addEventListener('click', function () {
  const g = activeGroup();
  if (!g) return;
  if (!confirm('Delete ' + g.name + '?')) return;
  checkpoint();
  const old = g.name;
  if (active.type === 'base') {
    doc.base.splice(active.i, 1);
    doc.overlays.forEach(function (o) {
      const i = o.hides.indexOf(old);
      if (i !== -1) o.hides.splice(i, 1);
    });
    shownBase.delete(old);
  } else {
    doc.overlays.splice(active.i, 1);
    shownOverlays.delete(old);
  }
  fixSelections();
  selRun = selVertex = null;
  renderAll();
});

$('btnAddLabel').addEventListener('click', function () {
  const key = prompt('Label letter', pendingLabelKey);
  if (!key) return;
  pendingLabelKey = key[0].toUpperCase();
  cancelMode();
  mode = 'label';
  renderAll();
});
$('btnDelLabel').addEventListener('click', function () {
  if (selLabel < 0 || !doc.labels[selLabel]) {
    setStatus('Select a label first.');
    return;
  }
  checkpoint();
  doc.labels.splice(selLabel, 1);
  selLabel = -1;
  renderAll();
});
$('labelKey').addEventListener('input', function () {
  if (selLabel < 0 || !doc.labels[selLabel]) return;
  const v = this.value.toUpperCase();
  const ch = v ? v[v.length - 1] : '';
  this.value = ch;
  if (doc.labels[selLabel].key !== ch) {
    checkpoint();
    doc.labels[selLabel].key = ch;
    autosave();
  }
  renderCanvas();
  buildLabels();
});

$('cap0').value = captions[0];
$('cap1').value = captions[1];
$('cap0').addEventListener('input', function () {
  captions[0] = this.value.toUpperCase();
  renderCanvas();
});
$('cap1').addEventListener('input', function () {
  captions[1] = this.value.toUpperCase();
  renderCanvas();
});

document.addEventListener('dragover', function (e) { e.preventDefault(); });
document.addEventListener('drop', function (e) {
  e.preventDefault();
  const f = e.dataTransfer.files && e.dataTransfer.files[0];
  if (!f || !/\.json$/i.test(f.name)) return;
  const rd = new FileReader();
  rd.onload = function () { loadDoc(rd.result); };
  rd.readAsText(f);
});

try {
  const saved = localStorage.getItem(AUTOSAVE_KEY);
  if (saved && saved !== serialize(doc) &&
      confirm('An autosaved copy from a previous session exists. Restore it?'))
    loadDoc(saved);
} catch (e) {}

resizeCanvas();
renderAll();
setStatus('');

}
