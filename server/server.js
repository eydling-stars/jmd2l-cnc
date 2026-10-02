// JMD-2L CNC — сервер: связка «браузер ⇄ Arduino» через USB-serial.
// Node.js LTS + serialport. Статика из ../web, порт 8080.
// Команды слатья по очереди (плата однопоточная): статус «?» — только когда
// ни одна команда не ждёт ответа, чтобы JSON статуса не перепутался с ответом.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
// Экспорт у serialport разный: v10 отдаёт сам класс (module.exports = SerialPort),
// v11 и новее — именованный { SerialPort }. Берём с запасом, чтобы смена версии
// не роняла сервер на первой же строке. Заодно это снимает требование Node 14+:
// v10 не использует «?.» и «??» и работает на Node 12 — последнем, что официально
// поддерживает Windows 7.
const sp = require('serialport');
const SerialPort = sp.SerialPort || sp;
// Кириллицу плата шлёт в UTF-8, и она влезает в USB не мгновенно: две-три
// посылки по 64 байта. Если декодировать каждый кусок отдельно (chunk.toString),
// многобайтовый символ, разрезанный между кусками, превращается в «�» —
// «ERR УЖЕ ИДЕТ ДОМ» приходило как «ERR У��Е ИДЕТ ДОМ». StringDecoder держит
// недоехавший хвост символа до следующего куска.
const { StringDecoder } = require('string_decoder');

const ROOT = path.join(__dirname, '..');
const WEB = path.join(ROOT, 'web');
const CFG_FILE = path.join(__dirname, 'config.json');
const WEB_PORT = 8080;

// ---- конфиг ----
let cfg = { port: '' };
try { cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8')); } catch (_) {}
const saveCfg = () => {
  try { fs.writeFileSync(CFG_FILE, JSON.stringify(cfg, null, 2)); } catch (_) {}
};

// ---- журнал (последние 500), раздаётся по SSE и /api/log ----
const log = [];
const logAdd = (s, lvl = 'info') => {
  log.push({ t: Date.now(), l: lvl, s });
  if (log.length > 500) log.shift();
  sseBroadcast({ t: 'log', d: { t: log[log.length - 1].t, l: lvl, s } });
};

// ---- SSE-клиенты ----
const clients = new Set();
function sseBroadcast(obj) {
  const frame = `data: ${JSON.stringify(obj)}\n\n`;
  for (const res of clients) res.write(frame);
}

// ---- serial: очередь команд, статус-опрос ----
let serial = null;
let pendingCmd = null;        // {id, c} — команда, ответ которой ещё не пришёл
let pendingAt = 0;            // когда отправили: страховка от залипания
let cmdQueue = [];
let cmdSeq = 0;
let wantConnect = true;
let isDisconnected = false;   // true только при выходе через Ctrl+C
let settleUntil = 0;          // после открытия CH340 дёргает DTR = сброс Arduino:
                              // первые ~1.2 с загрузчик ест команды — не шлём ничего

const mime = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.ico': 'image/x-icon',
};
const reply = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(obj)); };

function onLine(raw) {
  const line = raw.replace(/\r$/, '');
  if (!line) return;
  if (line.startsWith('!')) {
    // баннер после сброса платы: плата перезагрузилась — то, что мы слали
    // до этого, съел загрузчик, ответов не будет
    pendingCmd = null;
    cmdQueue = [];
    logAdd(`плата: ${line}`);
    return;
  }
  // Строки событий платы: '#' в начале. Это не ответ на команду, поэтому
  // pendingCmd не трогаем — OK/ERR по команде придёт следом своим путём.
  if (line.startsWith('#')) { logAdd(line.slice(1), 'ev'); return; }
  if (line.startsWith('{')) {
    let o = null;
    try { o = JSON.parse(line); } catch (_) {}
    if (!o) { logAdd(`не разобрал строку: ${line}`, 'warn'); return; }
    if (Array.isArray(o.v)) sseBroadcast({ t: 'cfg', d: o });        // T → настройки
    else if (typeof o.isr_hz === 'number') sseBroadcast({ t: 'w', d: o }); // W → диагностика
    else sseBroadcast({ t: 'st', d: o });                             // ? → статус
    // JSON — это ответ на опрос «?», а он пишется напрямую, мимо очереди.
    // Ответ приходит уже после того, как в очередь встала команда, и раньше
    // он безусловно забирал ожидание у этой команды: та теряла имя в
    // журнале и могла поймать ложное «нет ответа — пропускаю». Снимаем
    // ожидание только если действительно ждём опрос.
    if (pendingCmd && pendingCmd.c === '?') pendingCmd = null;
    pullQueue();
    return;
  }
  // Всё остальное — ответ на команду: OK / OK <число> / PONG / ERR <текст>.
  // Логируем ВСЁ, а не только ошибки: по журналу должен быть виден весь
  // диалог с платой, иначе неизвестно, какую команду она приняла, а какую
  // отвергла. Опрос статуса сюда не попадает — сервер шлёт его мимо очереди.
  const pc = pendingCmd;
  pendingCmd = null;
  // Имя команды может не совпасть: ответ приходит быстрее, чем сервер успел
  // поставить ожидание, и тогда pc пуст. Молчать об этом нельзя — журнал
  // событий обязан быть полным, иначе непонятно, куда делся ответ.
  logAdd(`${pc && pc.c ? pc.c : 'без команды'} → ${line}`,
         line.startsWith('ERR') ? 'err' : 'info');
  sseBroadcast({ t: 'r', d: { id: pc ? pc.id : 0, c: pc ? pc.c : '', text: line } });
  pullQueue();
}

function pullQueue() {
  if (pendingCmd || !serial || !serial.isOpen) return;
  if (Date.now() < settleUntil) return;          // загрузчик ещё крутится
  const next = cmdQueue.shift();
  if (!next) return;
  pendingCmd = next;
  pendingAt = Date.now();
  serial.write(next.c + '\n');
}

function sendCommand(c) {
  if (!serial || !serial.isOpen) return { ok: 0, err: 'нет связи с платой' };
  cmdQueue.push({ id: ++cmdSeq, c });
  pullQueue();
  return { ok: 1, id: cmdSeq };
}

let buf = '';
let dec = new StringDecoder('utf8');   // хвост многобайтового символа между кусками
function serialOpen(portPath, cb) {
  serialClose(() => {
    // Конструктор закреплённого serialport 10: путь идёт первым аргументом,
    // опции вторым. В 11+ путь переехал внутрь объекта опций.
    serial = new SerialPort(portPath, { baudRate: 115200, autoOpen: false });
    buf = '';                                        // не наследовать хвост прошлой сессии
    dec = new StringDecoder('utf8');
    serial.open((err) => {
      if (err) { logAdd(`не открылся ${portPath}: ${err.message}`, 'err'); serial = null; cb && cb(err); return; }
      logAdd(`связь: ${portPath}`);
      wantConnect = true;
      // DTR/RTS отпускаем: на этой плате RTS в единице держит ATmega в
      // загрузчике, и она молчит - ни баннера, ни ответа на «?». Сбрасывает
      // плату только фронт DTR, поэтому после открытия его надо снять, иначе
      // после каждого перезапуска сервера связь пропадала сама собой.
      // Именно set(), а не присваивание port.dtr: в serialport 10 присваивание
      // лишь создаёт поле на объекте, линии не трогает, и плата остаётся в
      // загрузчике — связи нет, а ошибки никто не видит.
      serial.set({ dtr: false, rts: false });
      settleUntil = Date.now() + 1200;   // CH340: DTR-импульс сбрасывает плату
      sseBroadcast({ t: 'conn', d: { connected: true, path: portPath } });
      cb && cb(null);
    });
    serial.on('data', (chunk) => {
      buf += dec.write(chunk);
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        onLine(line);
      }
      if (buf.length > 4096) buf = buf.slice(-1024);
    });
    serial.on('error', (e) => logAdd(`порт: ${e.message}`, 'err'));
    serial.on('close', () => {
      serial = null;   // иначе autoConnect() рано выходит: объект порта ещё держится
      logAdd(isDisconnected ? 'связь закрыта' : `порт ${portPath} закрылся`, 'warn');
      sseBroadcast({ t: 'conn', d: { connected: false, path: portPath } });
      if (wantConnect) setTimeout(autoConnect, 1000);   // переподключение
    });
  });
}

function serialClose(cb) {
  if (!serial) { cb && cb(); return; }
  wantConnect = false;
  pendingCmd = null;
  cmdQueue = [];
  try { serial.close(() => {}); } catch (_) {}
  serial = null;
  if (cb) setTimeout(cb, 50);
}

// Плата опознаётся баннером на команду «!». Открытие порта дёргает DTR и
// перезагружает ATmega, поэтому пишем не сразу, а после паузы на перезагрузку.
// Ничего, что двигает стол, здесь не отправляется — только «!».
function probePort(portPath) {
  return new Promise((resolve) => {
    let p = null, done = false, seen = '';
    const finish = (ok) => {
      if (done) return;
      done = true;
      clearTimeout(to);
      clearTimeout(toSettle);
      try { p && p.close(() => {}); } catch (_) {}
      resolve(ok);
    };
    const to = setTimeout(() => finish(false), 2500);
    const toSettle = setTimeout(() => {
      try { p.write('!\n', () => {}); } catch (_) { finish(false); }
    }, 700);
    try {
      p = new SerialPort(portPath, { baudRate: 115200, autoOpen: false });
    } catch (_) { return resolve(false); }
    p.on('data', (chunk) => {
      seen += chunk.toString('utf8');
      if (seen.indexOf('JMD-2L') >= 0) finish(true);
    });
    p.on('error', () => finish(false));
    p.open((err) => { if (err) finish(false); });
  });
}

async function autoConnect() {
  if (serial) return;
  let ports = [];
  try { ports = await SerialPort.list(); } catch (_) {}
  const names = ports.map((p) => p.path);
  if (names.length === 0) { logAdd('COM-портов не найдено — жду плату', 'warn'); setTimeout(autoConnect, 2000); return; }
  if (cfg.port && names.includes(cfg.port)) return serialOpen(cfg.port);
  // Сохранённого порта нет — это первый запуск после установки. Берём первый
  // в списке наугад нельзя: COM1 (COM материнской платы) в списке обычно
  // первый, и панель молча цепляется не к плате. Поэтому спрашиваем порты
  // сами и берём тот, где отвечает баннер.
  for (const n of names) {
    if (await probePort(n)) {
      logAdd(`плата найдена на ${n}`);
      cfg.port = n;
      saveCfg();
      return serialOpen(n);
    }
  }
  logAdd(`плата не ответила ни на одном порту (${names.join(', ')}) — подключаю первый`, 'warn');
  serialOpen(names[0]);
}
// heartbeat: комментарии SSE — иначе прокси/браузер рвут поток без трафика
setInterval(() => { for (const res of clients) res.write(': ping\n\n'); }, 15000);
setInterval(() => {                                 // опрос статуса 10 раз/с
  if (!serial || !serial.isOpen || Date.now() < settleUntil) return;
  // Плата молчит дольше 2.5 с — рвём ожидание: залипшая команда иначе
  // остановит и опрос статуса, то есть панель ослепнет совсем.
  if (pendingCmd && Date.now() - pendingAt > 2500) {
    logAdd(`нет ответа на «${pendingCmd.c}» — пропускаю`, 'warn');
    pendingCmd = null;
  }
  pullQueue();                                      // подхват команд, накопленных в затишье
  if (!pendingCmd && cmdQueue.length === 0) serial.write('?\n');
}, 100);

// ---- HTTP ----
const server = http.createServer((req, res) => {
  const u = new URL(req.url, `http://${req.headers.host}`);
  const p = u.pathname;

  if (p === '/api/ports' && req.method === 'GET') {
    SerialPort.list().then((ports) => reply(res, 200, {
      ports: ports.map((x) => x.path),
      last: cfg.port, connected: !!(serial && serial.isOpen), path: serial ? serial.path : null,
    })).catch(() => reply(res, 200, { ports: [], last: cfg.port, connected: false }));
    return;
  }
  if (p === '/api/connect' && req.method === 'POST') {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      let o = {};
      try { o = JSON.parse(body); } catch (_) {}
      if (o.path == null) { serialClose(); reply(res, 200, { ok: 1 }); return; }
      cfg.port = String(o.path);
      saveCfg();
      serialOpen(cfg.port, (err) => reply(res, 200, err ? { ok: 0, err: err.message } : { ok: 1 }));
    });
    return;
  }
  if (p === '/api/cmd' && req.method === 'POST') {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      let o = {};
      try { o = JSON.parse(body); } catch (_) {}
      reply(res, 200, typeof o.c === 'string' && o.c ? sendCommand(o.c.trim()) : { ok: 0, err: 'нет команды' });
    });
    return;
  }
  if (p === '/api/stream' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write('retry: 1500\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (p === '/api/log' && req.method === 'GET') { reply(res, 200, { log }); return; }
  if (p === '/api/cfg' && req.method === 'GET') { reply(res, 200, cfg); return; }
  if (p === '/api/cfg' && req.method === 'PUT') {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      try { const o = JSON.parse(body); if (typeof o.port === 'string') { cfg.port = o.port; saveCfg(); } } catch (_) {}
      reply(res, 200, cfg);
    });
    return;
  }

  // статика
  const file = p === '/' ? '/index.html' : p;
  const abs = path.normalize(path.join(WEB, file));
  if (!abs.startsWith(WEB)) { res.writeHead(403); res.end(); return; }
  fs.readFile(abs, (err, data) => {
    if (err) { res.writeHead(404); res.end('нет такого файла'); return; }
    // no-store: правки панели подхватываются сразу по F5, без Ctrl+F5
    res.writeHead(200, { 'Content-Type': mime[path.extname(abs)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
});

server.listen(WEB_PORT, () => {
  logAdd(`сервер слушает http://localhost:${WEB_PORT}`);
  setTimeout(autoConnect, 100);
});
process.on('SIGINT', () => { wantConnect = false; isDisconnected = true; serialClose(); process.exit(0); });
