// JMD-2L CNC — панель управления. Без сборки, без библиотек.
// Общение с сервером: POST /api/cmd {c}, события — SSE /api/stream.
'use strict';

const $ = (id) => document.getElementById(id);
const FAULTS = {
  0: 'нет', 1: 'обороты шпинделя упали ниже уставки', 2: 'обороты выше максимума',
  3: 'ток выше уставки — закусывание', 4: 'сработал концевик', 5: 'пропала связь с панелью',
};
const STATE = {
  st: null, cfg: null, port: '', connected: false, lastReply: '',
  logPaused: false, log: [], chart: [], jogKeys: new Set(),
  protMethod: 4, protOn: true,      // метод защиты (1..4) и вкл/выкл
  curOk: false, curA: 0,            // датчик тока отвечает / текущий ампераж
  gotEvent: false, speedsPending: false, chartOn: true,
  // Идёт ли сеанс на «Мекетном стенде». Пока true, панель не сохраняет
  // скорости и уставки в EEPROM: на стенде всё живёт только в ОЗУ платы.
  benchOn: false,
  // Какую скорость и когда мы последней отправили плате. Статус приходит
  // 10 раз/с, и первый же после нажатия пресета отдаёт ПРЕЖНЕЕ значение — поле,
  // подтягиваемое к плате, откатывалось назад, и ползунок дёргался туда-сюда.
  // null = команду не ждём, плата главная.
  spdAsk: [null, null], spdAskAt: [0, 0],
  // Кто начал текущее движение оси: 'jog' (джог), 'run' («Выполнить») или null
  // (дом, цикл, плата). «Выполнить» не зажигается от ручного джога: что нажали —
  // то и горит. moved — «ось после нажатия действительно поехала», чтобы снять
  // источник только по факту остановки, а не в паузе до старта.
  moveSrc: [null, null], moved: [false, false],
  presets: [],
  axisNames: ['X', 'Y'],
};
// Накопители для карточки «Шпиндель»: время работы и число пусков. Живут
// только пока открыта панель — счётчик переживать перезагрузку страницы
// незачем, а «накрутить» его на панели нечем.
let spinning = false, runMs = 0, spinTick = 0, spinCount = 0;

// ---------- сервер ----------
async function api(path, opts) {
  try {
    const r = await fetch(path, opts);
    return await r.json();
  } catch (_) { return null; }
}
// Команды уходят на плату строго по порядку вызова. Три fetch подряд браузер
// раскладывает по разным соединениям, и порядок до сервера доходил не тот:
// «S 1» приходил после «N 1 40» и гасил только что начатый ход — ось стояла,
// а цикл ждал её до таймаута. Цепочка обещает порядок; api() глотает ошибки,
// поэтому одна неудача не рвёт очередь остальных команд.
let cmdTail = Promise.resolve();
function cmd(c) {
  cmdTail = cmdTail.then(() => api('/api/cmd', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ c })
  }));
  return cmdTail;
}

function handleEvent(e) {
  STATE.gotEvent = true;
  let m = null;
  try { m = JSON.parse(e.data); } catch (_) { return; }
  if (!m || !m.t) return;
  if (m.t === 'st') onStatus(m.d);
  else if (m.t === 'r') onReply(m.d);
  else if (m.t === 'log') onLog(m.d);
  else if (m.t === 'conn') onConn(m.d);
  else if (m.t === 'cfg') { onCfg(m.d.v); fillSettings(m.d.v); }
}

// Настройки с платы: метод защиты и уставки на главном экране. Поле, в
// котором оператор уже печатает, не затираем — иначе нельзя ввести число.
function onCfg(v) {
  STATE.cfg = v;
  STATE.protMethod = v[0] > 0 ? v[0] : STATE.protMethod;
  STATE.protOn = v[0] !== 0;
  const set = (id, val) => { const el = $(id); if (el && document.activeElement !== el) el.value = val; };
  set('thrRpmLo', v[1]);
  set('thrRpmHi', v[2]);
  set('thrCur', (v[5] / 10).toFixed(1));
  set('thrSpin', v[9]);            // сколько ждать разгона шпинделя
  set('thrArm', v[10]);            // порог, выше которого защита взводится
  $('protSel').value = String(STATE.protMethod);
  // Длины хода: поле не трогаем, пока в него печатают, — иначе нельзя ввести
  // число. Само поле подтягивает плату, но только когда не редактируется.
  for (let i = 0; i < 2; i++) {
    const el = $('ax' + i + '-m');
    const um = Number(v[RUN_CFG[i]]);
    if (el && um > 0 && document.activeElement !== el) el.value = (um / 1000).toFixed(1);
  }
}

// Основной путь — EventSource. Если браузер или прокси его не пропускает
// (за 4 с ни одного события), читаем тот же SSE вручную через fetch.
function openSSE() {
  const es = new EventSource('/api/stream');
  es.onmessage = handleEvent;
  es.onerror = () => { /* EventSource переподключается сам */ };
  setTimeout(() => {
    if (STATE.gotEvent || es.readyState === 1) return;
    es.close();
    fetchStream();
  }, 4000);
}
async function fetchStream() {
  try {
    const resp = await fetch('/api/stream');
    const reader = resp.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const frame = buf.slice(0, i);
        buf = buf.slice(i + 2);
        if (frame.startsWith('data: ')) handleEvent({ data: frame.slice(6) });
      }
    }
  } catch (_) { /* поток оборвался — откроем заново */ }
  setTimeout(openSSE, 1500);
}

// ---------- соединение ----------
async function refreshPorts() {
  const d = await api('/api/ports');
  if (!d) return;
  const sel = $('portSel');
  sel.innerHTML = '';
  for (const p of d.ports) {
    const o = document.createElement('option');
    o.value = p; o.textContent = p;
    sel.appendChild(o);
  }
  if (d.ports.length === 0) {
    sel.innerHTML = '<option value="">портов нет</option>';
  } else if (d.connected && d.path) {
    sel.value = d.path;
  } else if (d.last && d.ports.includes(d.last)) {
    sel.value = d.last;
  }
  $('btnConnect').textContent = d.connected ? 'Отключить' : 'Подключить';
  updateConn(d.connected, d.path);
  onLink(d.connected);
}
function onConn(d) {
  $('btnConnect').textContent = d.connected ? 'Отключить' : 'Подключить';
  updateConn(d.connected, d.path);
  onLink(d.connected);
}
function updateConn(connected, path) {
  const el = $('connState');
  el.textContent = connected ? `связь: ${path}` : 'нет связи';
  el.className = 'dot ' + (connected ? 'ok' : 'bad');
  // Подключённый порт помечаем прямо в списке: по голому «COM4» не сразу
  // видно, что выбран именно тот, к которому сейчас подключена плата.
  // Галочка вместо слов: «COM4 — подключено» растягивал список на 176 px и
  // выдавливал шапку.
  for (const o of $('portSel').options) {
    o.textContent = o.value + (connected && o.value === path ? ' ✓' : '');
  }
}
// Поле состояния в шапке: видно всегда, что система делает сейчас. Зелёное —
// работа штатная: «ожидание» (ждём, пока шпиндель возьмёт порог взвода) или
// «контроль работы» (защита взведена). Жёлтое — защиту снял оператор, красное —
// авария. Отдельная полоса аварии при этом мигает.
function renderSysState() {
  const st = STATE.st, el = $('sysState');
  let txt, cls, tip;
  if (!STATE.connected || !st) {
    txt = 'нет связи'; cls = ''; tip = 'плата не подключена';
  } else if (st.ft) {
    txt = 'АВАРИЯ'; cls = ' bad';
    tip = 'причина — в полосе аварии; устраните и нажмите «Сбросить аварию»';
  } else if (!STATE.protOn) {
    txt = 'защита снята'; cls = ' warn';
    tip = 'оператор отключил защиту: контроль оборотов и тока не выполняется';
  } else if (st.sd.ar) {
    txt = 'контроль работы'; cls = ' ok';
    tip = 'защита взведена: следим за оборотами и током';
  } else {
    txt = 'ожидание'; cls = ' ok';
    tip = 'ждём, пока шпиндель возьмёт порог взвода';
  }
  el.textContent = txt;
  el.className = 'sysst' + cls;
  el.title = tip;
}
// Скорость с ползунков обязана совпадать с платой: после перезагрузки и
// переподключения на оси hz = 0, и ход ползёт 1 шаг/с. Шлём один раз на
// подключение — как только пришёл первый статус с настоящим шаг/мм.
// Но только по тем осям, где на плате скорости ещё нет. Навязывать поле при
// переподключении нельзя: поле могло устареть (потолок считается от микрошага,
// а он меняется), и ось получала неверную скорость молча. Где скорость на плате
// уже стоит — поле подтянет renderAxis, плата там главнее.
function pushSpeeds() {
  STATE.speedsPending = false;
  const st = STATE.st;
  for (let i = 0; i < 2; i++) {
    if (st && st.ax[i].h) continue;
    setSpeed(i);
  }
}
function onLink(connected) {
  if (!connected) {
    STATE.speedsPending = false; STATE.connected = false;
    renderSysState();
    return;
  }
  const was = STATE.connected;
  STATE.connected = true;
  if (!was) STATE.speedsPending = true;
  renderSysState();
}
$('btnConnect').onclick = () => {
  if (STATE.connected) api('/api/connect', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"path":null}' });
  else api('/api/connect', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: $('portSel').value }) });
};

// ---------- статус платы ----------
function onStatus(st) {
  STATE.st = st;
  if (STATE.speedsPending) pushSpeeds();   // первый статус знает настоящий шаг/мм
  $('fw').textContent = 'fw ' + st.fw;
  // авария
  const fb = $('faultBox');
  if (st.ft) {
    fb.classList.remove('hidden');
    $('faultText').textContent = 'АВАРИЯ: ' + FAULTS[st.ft] || String(st.ft);
    $('faultMeta').textContent = st.ft === 4 ? 'отъехать от концевика и сбросить' :
      (st.ft === 5 ? 'проверьте связь' : '');
    $('btnResetFault').disabled = st.ft === 4 && (st.lm & 15) !== 0;
  } else fb.classList.add('hidden');
  // шпиндель
  $('rpmVal').textContent = st.sd.ro ? st.sd.r + ' об/мин' : '—';
  // Ток показываем только когда датчик реально отвечает. Раньше висящий пин
  // давал 15 А и пугал оператора; плата сбрасывает co, если датчика нет.
  STATE.curOk = !!st.sd.co;
  STATE.curA = st.sd.c / 10;
  $('curVal').textContent = STATE.curOk ? STATE.curA.toFixed(1) + ' А' : '—';
  const rl = st.sd.r < (STATE.cfg ? STATE.cfg[1] : 400) ? 'bad' : 'ok';
  $('rpmState').textContent = st.sd.ro ? (rl === 'ok' ? 'норма' : 'ниже порога') : 'нет сигнала';
  $('rpmState').className = 'tag ' + (st.sd.ro ? rl : 'bad');
  // Подсказку про датчик — в подсказку плашки, а не отдельной строкой: длинный
  // текст в ячейке ломал высоту карточки и уводил плашки с одной горизонтали.
  $('rpmState').title = st.sd.ro ? 'тахометр отвечает' :
    'тахометр не отвечает — проверьте датчик и «импульсов на оборот» (вкладка «Пусконаладка»)';
  const cl = STATE.curOk && st.sd.c >= (STATE.cfg ? STATE.cfg[5] : 70) ? 'bad' : 'ok';
  $('curState').textContent = STATE.curOk ? (cl === 'ok' ? 'норма' : 'выше порога') : 'нет сигнала';
  $('curState').className = 'tag ' + (STATE.curOk ? cl : 'bad');
  $('curState').title = STATE.curOk ? 'датчик тока в сети' :
    'датчик тока не в сети — проверьте датчик и нажмите «Калибровать ноль» (вкладка «Пусконаладка»)';
  renderProt(st);
  // Прочерк «—» в ячейке реле читался как «нет данных», хотя реле всегда в
  // каком-то состоянии. Пишем словами: выключено / включено.
  $('relayVal').textContent = st.rl ? 'Включено' : 'Выключено';
  $('relayState').textContent = st.rl ? 'сработало' : 'не сработало';
  $('relayState').className = 'tag ' + (st.rl ? 'ok' : 'dim');
  $('relayVal').className = 'big' + (st.rl ? ' ok-text' : ' dim');
  if (typeof renderSetup === 'function') renderSetup(st);
  if (typeof renderBench === 'function') renderBench(st);
  // оси
  for (let i = 0; i < 2; i++) renderAxis(i, st.ax[i], st);
  // график
  if (st.sd.ro || STATE.curOk) {
    // Помечаем отсчёт, если значение подставлено стендом: на графике такая
    // линия идёт пунктиром, подмену нельзя выдавать за настоящий замер.
    const simR = !!(st.sm & 2), simC = !!(st.sm & 4);
    // sd.c плата шлёт в десятых долях ампера. На график клали его как есть,
    // и ось «А» врала в 10 раз: при настоящих 0,1 А линия уходила на 1,0 А.
    // Показание в тексте делит на 10 (строка выше) — график обязан так же.
    STATE.chart.push({ t: Date.now(), rpm: st.sd.ro ? st.sd.r : 0,
                       cur: STATE.curOk ? st.sd.c / 10 : 0, sr: simR, sc: simC });
    if (STATE.chart.length > 900) STATE.chart.shift();
    drawChartThrottled();
  }
  // Время работы шпинделя и шкала разгона. Порог взвода — тот же, что
  // настроен в «Безопасности»: пока обороты ниже него, плата считает, что
  // шпинделя нет (и стол не пускает).
  const thr = STATE.cfg ? (STATE.cfg[10] | 0) : 400;
  const rpmNow = st.sd.ro ? st.sd.r : 0;
  // Время считаем по реальным часам, а не «+100 мс на статус»: темп статусов
  // плавает (печать статуса ~25 мс), за час работы набежала бы ошибка.
  const t = Date.now();
  if (st.sd.ro && rpmNow > thr) {
    if (spinning) runMs += t - spinTick;
    spinning = true; spinTick = t;
  } else {
    if (spinning) spinCount++;
    spinning = false;
  }
  $('runVal').textContent = Math.floor(runMs / 60000) + ':' +
    String(Math.floor(runMs / 1000) % 60).padStart(2, '0');
  $('runState').textContent = spinning ? 'шпиндель крутится' : 'шпиндель стоит';
  $('runState').className = 'tag ' + (spinning ? 'ok' : 'dim');
  $('runState').title = 'Накоплено, пока панель открыта. Пусков: ' + spinCount;

  const pct = thr > 0 ? Math.max(0, Math.min(100, Math.round(rpmNow / thr * 100))) : 100;
  $('armBarFill').style.width = pct + '%';
  $('armBarVal').textContent = thr > 0 ? rpmNow + ' из ' + thr + ' об/мин' : 'порог 0 — взвод сразу';
  // Три состояния, а не два: пока обороты ниже порога — «ждём», при аварии
  // взвод сбрасывается, и тогда «ждём» врёт (обороты уже есть). Отдельной
  // строкой говорим, что дело не в оборотах.
  const ar = st.sd.ar, aw = st.sd.aw, over = thr > 0 && rpmNow >= thr;
  $('armBarState').textContent = ar ? (aw ? 'взвелась: порог завышен' : 'порог взят, защита взведена')
    : (over ? 'порог взят, но защита не взведена' : 'ждём ' + thr + ' об/мин');
  $('armBarState').className = 'tag ' + (ar ? (aw ? 'bad' : 'ok') : (over ? 'bad' : 'dim'));
  $('armBarState').title = ar
    ? (aw ? 'Шпиндель крутится, но до порога не дотянул и защиту включила страховка. Понизьте порог взвода.'
           : 'Защита взводится сама, как только обороты перевалят порог.')
    : (over ? (st.ft ? 'Обороты есть, но плата сбросила взвод: авария ' + (FAULTS[st.ft] || st.ft) +
                    '. Сбросьте аварию — защита взведётся снова.'
                    : 'Обороты есть, взвода нет: проверьте метод защиты в настройках.')
           : 'Защита взводится сама, как только обороты перевалят порог.');
  renderSysState();   // поле состояния в шапке — по тому же статусу
}

// Пресеты хода живут на плате (cfg 32..34) и правятся во вкладке «Настройки».
// Единица — обороты мотора, а не мм/мин: оператор выбирает режим одним нажатием
// и хочет видеть ровно то число, которое вписал в настройках. Раньше тут стояло
// мм/мин, и подпись «600 мм/мин → 1500 об/мин» требовала держать в голове
// пересчёт по мкм на оборот — в настройках ставишь 200, а кнопка едет 1500.
const PRESET_NAMES = ['Точная', 'Рабочая', 'Быстрая'];
const PRESET_CFG = [32, 33, 34];
// Сохранённые скорости ползунков и длины хода: те же настройки, что и пресеты,
// но меняются движением, поэтому пишем их сами и без всяких кнопок.
const SPD_CFG = [35, 36], RUN_CFG = [37, 38];
const presetRpm = (k) => {
  const c = STATE.cfg;
  const v = c ? Number(c[PRESET_CFG[k]]) : 0;
  return v > 0 ? v : 0;
};
// Верхняя строка оси: «Ось X  [стоит]  …  N шаг  потолок … об/мин». Держим её в
// одну линию: если текст стал длиннее и не влезает (счётчик шагов растёт на
// ходу), уменьшаем шрифт всей строки, а не переносим — заголовок не «прыгает».
function fitAxisHead(i) {
  const h = $('ax' + i + '-title');
  const st = $('ax' + i + '-steps');
  const mx = $('ax' + i + '-max');
  if (!h || !st || !mx) return;
  const key = h.clientWidth + '|' + st.textContent + '|' + mx.textContent;
  if (h.dataset.fit === key) return;      // тот же текст и ширина — не меряем
  h.dataset.fit = key;
  h.style.fontSize = '';                  // сперва как задумано (15 px)
  let fs = 15;
  while (fs > 10 && h.scrollWidth > h.clientWidth + 1) {
    fs -= 0.5;
    h.style.fontSize = fs + 'px';
  }
}
function renderAxis(i, ax, st) {
  const b = $('ax' + i);
  if (!b) return;
  const posmm = (ax.p / ax.sp).toFixed(2);
  $('ax' + i + '-pos').textContent = posmm + ' мм';
  $('ax' + i + '-steps').textContent = ax.p + ' шаг';
  $('ax' + i + '-state').textContent =
    (ax.r ? 'ЕДЕТ' : 'стоит') + (ax.e ? '' : ' · ENA выкл');
  $('ax' + i + '-state').className = 'tag ' + (ax.r ? 'ok' : 'dim');
  // Потолок платы в оборотах мотора: 20000 шаг/с, делённые на текущий
  // микрошаг. Раньше здесь стояло «предел N мм/мин», где N считался из
  // выдуманных шагов на миллиметр, — число было правдоподобным и бесполезным.
  const mx = spdMax(i);
  // Короткая надпись: «20000 шаг/с при 400 шаг/об» переносила строку заголовка,
  // и при изменении числа шагов она прыгала. Подробность — в подсказке.
  $('ax' + i + '-max').textContent = 'потолок ' + mx + ' об/мин · ' + sprOf(i) + ' шаг/об';
  $('ax' + i + '-max').title = 'выше этой скорости плата не поедет: предел ' +
    HZ_TOP + ' шаг/с, при ' + sprOf(i) + ' шаг/об это ' + mx + ' об/мин';
  // max поля держим живым: сменили микрошаг на плате — потолок поехал.
  // Значение выше потолка гасим молча, команду не шлём: плата его и так
  // срезает, а лишний R из обработчика статуса гонял бы команду на ровном месте.
  const vs = $('ax' + i + '-v'), vns = $('ax' + i + '-vn');
  if (vs && +vs.max !== mx) { vs.max = mx; vns.max = mx; }
  if (vns && +vns.value > mx) { vns.value = mx; vs.value = mx; }
  // Скорость, которая на плате, — правда. Поле раньше только обрезалось по
  // потолку и больше никогда с платой не сверялось: после смены микрошага оно
  // навсегда осталось 187 об/мин (потолок при 6400 шаг/об), хотя ось на плате
  // шла по 2000. А pushSpeeds() при переподключении отправляет поле на плату —
  // то есть тихо задавал оси не ту скорость. Поэтому поле подтягиваем к плате.
  // Пока оператор в поле печатает — не трогаем; h = 0 (плата ещё не получила
  // скорость после перезагрузки) — тоже, иначе поле обнулится само.
  const busy = document.activeElement === vns || document.activeElement === vs;
  const boardRpm = ax.h ? Math.round(ax.h * 60 / sprOf(i)) : 0;
  // Плата — правда, но пока не дошла наша команда, перебивать её нельзя: первый
  // же статус после нажатия пресета отдаёт прежнее значение, и ползунок
  // откатывался назад, а потом прыгал вперёд. Ждём подтверждения — плата ответит
  // тем же числом. За 1 с не подтвердила — значит срезала потолком или отвергла,
  // тогда верим плате и показываем то, что есть.
  let waiting = STATE.spdAsk[i] !== null;
  if (waiting && (boardRpm === STATE.spdAsk[i] || Date.now() - STATE.spdAskAt[i] >= 1000)) {
    STATE.spdAsk[i] = null;
    waiting = false;
  }
  // Ползунок и поле числа сверяем оба: сверка только по полю числа оставляла
// ползунок с чужим числом, если они расходились (поле «исправилось», а
  // ползунок продолжал показывать своё).
if (vs && ax.h && !busy && !waiting && (+vns.value !== boardRpm || +vs.value !== boardRpm)) {
    vns.value = boardRpm; vs.value = boardRpm;
  }
  // Подпись пресета живёт на плате, а не в замыкании: значение берём здесь.
  // Горит тот пресет, чья скорость стоит на оси СЕЙЧАС. Увели ползунок в
  // сторону — подсветка сходит сама: видно, что скорость задана вручную.
  const curRpm = waiting ? STATE.spdAsk[i] : boardRpm;
  if (b) b.querySelectorAll('button[data-rpm]').forEach((btn) => {
    const rpm = presetRpm(Number(btn.dataset.k));
    btn.dataset.rpm = rpm;
    btn.title = rpm > 0 ? rpm + ' об/мин'
      : 'не задана во вкладке «Настройки» → раздел «Скорости хода»';
    btn.classList.toggle('sel', rpm > 0 && curRpm === rpm);
  });
  // концевики своей оси: ось 0 → биты 0..1, ось 1 → биты 2..3
  const names = i === 0 ? ['концевик X-1', 'концевик X-2'] : ['концевик Y-1', 'концевик Y-2'];
  const lims = $('ax' + i + '-lim');
  if (lims) {
    lims.innerHTML = '';
    for (let k = 0; k < 2; k++) {
      const on = (st.lm >> (i * 2 + k)) & 1;
      lims.innerHTML += '<span class="lim ' + (on ? 'on' : '') + '">' + names[k] + '</span>';
    }
  }
  // Подсветка джога: горит, только если движение начал ИМЕННО джог. «Выполнить»
  // тоже подсвечиваем по направлению, но только для хода по кнопке — ручной джог
  // «Выполнить» не зажигает: что нажали, то и горит. Оба гаснут, когда ось встала.
  const src = STATE.moveSrc[i];
  $('ax' + i + '-l').classList.toggle('on', !!ax.r && !ax.dr && src === 'jog');
  $('ax' + i + '-r').classList.toggle('on', !!ax.r && !!ax.dr && src === 'jog');
  $('ax' + i + '-gol').classList.toggle('on', !!ax.r && !ax.dr && src === 'run');
  $('ax' + i + '-gor').classList.toggle('on', !!ax.r && !!ax.dr && src === 'run');
  // Источник держим, пока ось реально движется; встала — забываем. Без этого
  // подсветка пережила бы ход и зажглась на следующем (например, при доме).
  if (ax.r) STATE.moved[i] = true;
  else if (STATE.moved[i]) { STATE.moved[i] = false; STATE.moveSrc[i] = null; }
  // Обнуление на ходу запрещено: цель хода задана шагами от pos, и обнуление
  // посреди хода сдвинуло бы её на всю пройденную длину — ось уехала бы мимо.
  // Раньше кнопка оставалась нажимаемой, оператор её жал и получал ERR в ответ.
  // Пока ось едет — кнопка неактивна, и спорить с платой не приходится.
  $('ax' + i + '-z').disabled = !!ax.r;
  $('ax' + i + '-z').title = ax.r
    ? `ось ${i + 1} едет: сначала стоп, потом можно обнулять`
    : `ось ${i + 1}: здесь ноль. Счётчик шагов и миллиметры обнуляются на месте`;
  fitAxisHead(i);
}

// ---------- оси: карточки ----------
// Скорость задаётся в оборотах МОТОРА, а не в мм/мин. На стенде ход винта и
// передаточное число неизвестны, поэтому шагов на миллиметр и любые мм/мин
// получаются выдуманными — плата тогда показывает правдоподобную цифру, которая
// ни к чему не относится. Обороты мотора от хода винта не зависят.
//
// Потолок платы — 20000 шагов/с (Timer1 40 кГц, один шаг = два переключения
// PUL), и в оборотах он зависит от микрошага: 20000 / шагов-на-оборот * 60.
// Потолок ставится в max поля живьём из текущих шагов на оборот, чтобы цифра
// никогда не разрешала больше, чем плата выдаст.
const HZ_TOP = 20000;
const sprOf = (i) => {
  const c = STATE.cfg;
  return c ? Math.max(1, c[20 + i * 5] | 0) : 400;
};
const spdMax = (i) => Math.floor(HZ_TOP * 60 / sprOf(i));
// Стрелки джога — по смыслу оси: X ездит влево-вправо, Y — вверх-вниз. Раньше
// обе карточки показывали «◀ ▶», и на вертикальной оси это вводило в
// заблуждение. Плюс/минус за ними не зашит: какая сторона плюсовая — проверяется
// на станке (пункт 5 пусконаладки, «Направление осей»).
const JOG = [
  ['◀', 'влево', '▶', 'вправо'],
  ['▼', 'вниз', '▲', 'вверх'],
];
function buildAxes() {
  const wrap = $('axes');
  wrap.innerHTML = '';
  for (let i = 0; i < 2; i++) {
    const n = STATE.axisNames[i];
    const [jl, jlt, jr, jrt] = JOG[i];
    const el = document.createElement('div');
    el.className = 'card axis';
    el.id = 'ax' + i;
    el.innerHTML = `
      <h3 id="ax${i}-title">Ось ${n} <span id="ax${i}-state" class="tag dim">стоит</span>
          <!-- Шаги и потолок — на той же строке, у правого края. Если число
               выросло и не влезает, renderAxis уменьшает шрифт всей строки. -->
          <span class="ax-info dim"><span id="ax${i}-steps"></span><span id="ax${i}-max" title="выше этой скорости плата не поедет: она обрезает шаги в секунду"></span></span>
      </h3>
      <div class="ax-pos">
        <span class="big" id="ax${i}-pos">0.00 мм</span>
      </div>
      <!-- Джоги разведены по краям карточки, стоп — ровно посередине. Раньше все
           три стояли рядом, и «едет» нажималось вместо «стоп» наоборот. -->
      <div class="ax-row ax-jog">
        <button class="jog" id="ax${i}-l" title="ось ${n} ${jlt} — удерживать">${jl}</button>
        <button class="stop" id="ax${i}-s" title="стоп оси ${n}">■</button>
        <button class="jog" id="ax${i}-r" title="ось ${n} ${jrt} — удерживать">${jr}</button>
      </div>
      <!-- Скорость — обороты мотора. Ползунок и поле показывают одно и то же и
           двигают одно и то же; max обоих ставится живьём в renderAxis из
           текущего микрошага, поэтому поле не может разрешить скорость, которую
           плата всё равно срежет. Шаг 1 об/мин — скорость подбирают опытом, и
           округлять её до десятков незачем. -->
      <div class="ax-row ax-spd">
        <span class="ax-spdn">
          <input type="range" id="ax${i}-v" min="1" max="3000" value="200" step="1"
                 title="скорость мотора, об/мин">
          <input type="number" id="ax${i}-vn" min="1" max="3000" step="1" value="200"
                 title="скорость мотора, об/мин — можно вписать число">
          <span class="u">об/мин</span>
        </span>
      </div>
      <!-- Сторону хода выбирает сама кнопка. Раньше сторону задавал минус в поле
           «ход», и оператор об этом узнавал только постфактум — проехало не туда,
           и куда именно, показывала уже позиция. Две кнопки со стрелками читаются
           однозначно и совпадают с джогом выше: стрелка та же, значит и сторона
           та же. -->
      <div class="ax-row">
        <span>ход, мм</span>
        <input id="ax${i}-m" type="number" step="0.1" value="10" min="0"
               title="длина хода, мм. Сторону задаёт кнопка со стрелкой. Значение сохраняется само">
        <button id="ax${i}-gol" class="run" title="ось ${n} ${jlt} на указанное число мм">${jl} Выполнить</button>
        <button id="ax${i}-gor" class="run" title="ось ${n} ${jrt} на указанное число мм">Выполнить ${jr}</button>
      </div>
      <div class="ax-row">
        <button id="ax${i}-z" title="ось ${n}: здесь ноль. Счётчик шагов и миллиметры обнуляются на месте">Обнулить</button>
        <span class="lims" id="ax${i}-lim"></span>
      </div>`;
    wrap.appendChild(el);

    // скорость: ползунок и поле ввода показывают одно и то же и двигают одно и
    // то же. Пока печатаем — просто держим ползунок в тему; по Enter или уходу
    // фокуса приводим поле к целому и зажимаем в потолок платы.
    const v = $('ax' + i + '-v');
    const vn = $('ax' + i + '-vn');
    const setV = (val) => { v.value = val; vn.value = val; setSpeed(i); };
    v.oninput = () => { vn.value = v.value; setSpeed(i); };
    vn.oninput = () => {
      const x = parseInt(vn.value, 10);
      if (isFinite(x) && x >= 1) { v.value = Math.min(x, spdMax(i)); setSpeed(i); }
    };
    vn.onchange = () => {
      const x = parseInt(vn.value, 10);
      setV(isFinite(x) ? Math.min(Math.max(x, 1), spdMax(i)) : 200);
    };
    for (let k = 0; k < PRESET_NAMES.length; k++) {
      const b = document.createElement('button');
      b.textContent = PRESET_NAMES[k];
      b.dataset.k = k;
      b.dataset.rpm = presetRpm(k);
      // Значение читаем в момент нажатия, а не из замыкания на момент сборки
      // карточки: пресет правят во вкладке «Настройки», и замыкание держало бы
      // старые обороты — подпись показывала бы одно, а ось ехала бы другое.
      b.onclick = () => {
        const rpm = Number(b.dataset.rpm);
        if (!(rpm > 0)) return;
        setV(Math.max(1, Math.min(spdMax(i), rpm)));
      };
      // Пресет — перед группой «ползунок + поле», то есть у левого края строки.
      const grp = v.parentNode;
      grp.parentNode.insertBefore(b, grp);
    }

    // джог
    // Останов по кнопке джога - только если это нажатие действительно начало
    // джог. Раньше pointerleave был привязан к кнопке безусловно, и достаточно
    // было провести мимо стрелки курсором, чтобы ось встала: ничего не
    // нажимая, никто ничего не останавливал, а журнал писал «СТОП X: команда».
    // held живёт вместе с билдом карточки, renderAxis его не трогает.
    let held = false;
    const jog = (dir) => () => {
      held = true;
      STATE.moveSrc[i] = 'jog';
      cmd('D ' + (i + 1) + ' ' + dir); cmd('G ' + (i + 1));
    };
    const halt = () => { cmd('S ' + (i + 1)); };
    const release = () => {
      if (!held) return;
      held = false;
      // Ход по кнопке «Выполнить» отпускание стрелки джога не должен убивать.
      if (STATE.moveSrc[i] === 'jog') cmd('S ' + (i + 1));
    };
    for (const [id, fn] of [['l', jog(0)], ['r', jog(1)]]) {
      const b = $('ax' + i + '-' + id);
      b.onpointerdown = (e) => { e.preventDefault(); fn(); };
      b.onpointerup = release; b.onpointerleave = release;
    }
    $('ax' + i + '-s').onclick = halt;
    // Ход: сторона задаётся кнопкой, поле — это только длина. Плата берёт
    // направление из знака шагов (плюс -> dir 0, минус -> dir 1), поэтому кнопка
    // со стрелкой dir 0 шлёт плюс, а со стрелкой dir 1 — минус.
    const go = (dir) => () => {
      const mm = Math.abs(parseFloat($('ax' + i + '-m').value));
      if (!isFinite(mm) || !mm) return;
      const st = STATE.st;
      const sp = st ? st.ax[i].sp : 4;
      const steps = Math.round(mm * sp);
      STATE.moveSrc[i] = 'run';
      cmd('N ' + (i + 1) + ' ' + (dir ? '-' : '') + steps);
    };
    $('ax' + i + '-gol').onclick = go(0);
    $('ax' + i + '-gor').onclick = go(1);
    // Длина хода сохраняется сама, по уходу с поля: пока печатают, значение
    // меняется на каждый символ, и писать EEPROM на каждый символ нельзя.
    $('ax' + i + '-m').onchange = () => setRunLen(i);
    // Обнуление: приводим ось джогом в точку, жмём «обнулить» — и дальше ход
    // кнопкой «выполнить» считается от неё. Плата откажется, если ось едет.
    $('ax' + i + '-z').onclick = () => cmd('Z ' + (i + 1));
    // Дома на станке нет: счётчик шагов сам по себе ни с чем не сверяется и
    // показывает, сколько стол прошёл с момента включения или последнего
    // обнуления вручную.
  }
  // Длина хода из платы: поле собиралось со значения 10 мм в разметке, и
  // после перезагрузки показывало чужие 10 вместо того, что оператор вписал.
  if (STATE.cfg) {
    for (let i = 0; i < 2; i++) {
      const um = Number(STATE.cfg[RUN_CFG[i]]);
      if (um > 0) $('ax' + i + '-m').value = (um / 1000).toFixed(1);
    }
  }
}
// Скорость уходит на плату оборотами мотора: R <ось> <об/мин>. Плата сама
// переводит их в шаги/с через шаги на оборот и зажимает по своему потолку —
// поэтому сюда уходит ровно то, что вписал оператор, без домысливания.
const setSpeed = (i) => {
  const rpm = Math.max(0, parseInt($('ax' + i + '-v').value, 10) || 0);
  STATE.spdAsk[i] = rpm;
  STATE.spdAskAt[i] = Date.now();
  cmd('R ' + (i + 1) + ' ' + rpm);
  // На стенде скорость своя и в «Управление» не уезжает: плата получает её
  // вживую (R), а в EEPROM ничего не пишем. При выходе стенд вернёт рабочую.
  if (STATE.benchOn) return;
  // Скорость ползунка — настройка станка, а не разовый параметр хода: её
  // настроили один раз и ждут после перезагрузки. Пишем в cfg и просим
  // плату сохранить. Запись в EEPROM отложена на паузу в setTimeout, иначе
  // каждое движение ползунка жгло бы ресурс ячейки (у неё их ~100 тыс.).
  saveLater(() => cmd('T ' + SPD_CFG[i] + ' ' + rpm));
};
// Длина хода из поля «ход, мм» — то же самое: одно число на ось, переживает
// перезагрузку. Сторону хода не храним: её задаёт кнопка со стрелкой, и
// сохранять её вместе с длиной значило бы при следующем включении ехать
// в ту сторону, куда оператор в прошлый раз нажал, а не куда нажал сейчас.
const setRunLen = (i) => {
  if (STATE.benchOn) return;   // на стенде длину хода нигде не сохраняем
  const mm = parseFloat($('ax' + i + '-m').value);
  if (!isFinite(mm) || mm < 0) return;
  saveLater(() => cmd('T ' + RUN_CFG[i] + ' ' + Math.round(mm * 1000)));
};

// Отложенная запись в EEPROM. Плата пишет всю пачку настроек целиком по
// команде TS, поэтому «сохранить» = «собрать всё изменённое и один раз
// записать». Ждём паузу в setTimeout: ползунок шлёт команду на каждое движение,
// и без паузы одно короткое движение съедало бы десятки записей EEPROM.
let saveT0 = null;
function saveLater(send) {
  send();
  saveT0 = setTimeout(() => {
    cmd('TS');
    cmd('T');                    // показать, что плата приняла и не срезала
    saveT0 = null;
    STATE.saved = 'скорости сохранены в плату';
    renderSaved();
  }, 1200);
}
function renderSaved() {
  const el = $('savedTag');
  if (!el) return;
  el.textContent = STATE.saved || '';
  el.classList.toggle('hidden', !STATE.saved);
}

// ---------- график ----------
// Статусы идут 10 раз/с, а перерисовка холста на каждый — лишняя работа.
// Рисуем 2 раза/с: глаз разницы не видит, а нагрузки на браузер почти нет.
let chartT0 = 0;
function drawChartThrottled() {
  if (!STATE.chartOn) return;
  const n = Date.now();
  if (n - chartT0 < 500) return;
  chartT0 = n;
  drawChart();
}
const CH_RPM = '#4ec9b0', CH_CUR = '#e5a54b', CH_GRID = '#252b34', CH_TXT = '#7c8896',
      CH_SIM = '#d8a13a';   // подставленное стендом значение — другой цвет
// Верх шкалы округляем до «красивого» числа, иначе подписи выходят вроде 437
// и сетка не читается глазом.
function niceStep(v) {
  const p = Math.pow(10, Math.floor(Math.log10(Math.max(v, 1e-6))));
  const n = v / p;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p;
}
function clock(t) {
  const d = new Date(t);
  return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
    ':' + ('0' + d.getSeconds()).slice(-2);
}
function drawChart() {
  const cfg = STATE.cfg || [];
  drawPlot($('chartRpm'), 'rpm', CH_RPM, [
    { v: cfg[1] || 0, t: 'не ниже ' + (cfg[1] || 0) },
    { v: cfg[2] || 0, t: 'не выше ' + (cfg[2] || 0) },
  ], 'датчик оборотов не отвечает');
  drawPlot($('chartCur'), 'cur', CH_CUR, [
    { v: (cfg[5] || 0) / 10, t: 'не выше ' + ((cfg[5] || 0) / 10).toFixed(1) + ' А' },
  ], 'датчик тока не отвечает');
  // легенда в заголовках карточек: на холсте мелкий текст нечитаем
  const st = STATE.st;
  const sm = st ? (st.sm | 0) : 0;
  $('lgRpm').textContent = (st && st.sd.ro ? st.sd.r : 0) + ' об/мин' +
    ((sm & 2) ? ' · подмена' : '');
  $('lgCur').textContent = (STATE.curOk ? STATE.curA.toFixed(1) + ' А' : 'А: нет датчика') +
    ((sm & 4) ? ' · подмена' : '');
}
// Один канал — один холст: своя шкала, своя подпись оси, своя уставка. Общий
// холст на оба канала выходил высоким, а «А» и «об/мин» на одной вертикали
// путались: у каждой величины теперь своя маленькая картинка.
function drawPlot(cv, key, col, marks, noData) {
  const ctx = cv.getContext('2d');
  // Рисуем в «железных» пикселях: на плотном экране сетка и цифры расплываются.
  // Размер берём у CSS и пересоздаём буфер только когда он реально изменился.
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  ctx.font = '10px Consolas, monospace';
  ctx.lineWidth = 1;

  const now = Date.now(), T0 = now - 60000;
  const data = STATE.chart.filter((p) => p.t >= T0);
  // Канал рисуем только при живом датчике: подставленное на стенде значение
  // приравнивать к настоящему нельзя, график соврал бы оператору.
  const live = key === 'rpm' ? !!(STATE.st && STATE.st.sd.ro) : STATE.curOk;
  let top = 1;
  for (const m of marks) top = Math.max(top, m.v);
  for (const p of data) if (live && p[key] > top) top = p[key];
  // Верх шкалы округляем до «красивого» числа, иначе подписи выходят вроде
  // 437 и сетка не читается глазом.
  const step = niceStep(top / 4);
  top = step * Math.max(4, Math.ceil(top / step));

  const L = 34, T = 8, B = 15;   // поля под подписи осей
  const x0 = L, x1 = w - 6, y0 = T, y1 = h - B;
  const X = (t) => x0 + (t - T0) / 60000 * (x1 - x0);
  const Y = (v) => y1 - v / top * (y1 - y0);

  // сетка: вертикали — каждые 10 с, горизонтали — по своей шкале
  ctx.strokeStyle = CH_GRID;
  ctx.beginPath();
  for (let s = 0; s <= 60000; s += 10000) {
    const gx = Math.round(x0 + s / 60000 * (x1 - x0)) + 0.5;
    ctx.moveTo(gx, y0); ctx.lineTo(gx, y1);
  }
  // Число делений считаем, а не копим v += step. Условие «v <= top + 1»
  // пропускало лишнюю линию над верхом шкалы: при уставке тока 2 А получалось
  // top=2, step=0,5 и линии 2,5 — она уезжала выше поля, а её подпись
  // прижималась к краю холста прямо на подпись «2». Две цифры ложились друг на
  // друга и обе читались как каша.
  const nDiv = Math.round(top / step);
  for (let k = 0; k <= nDiv; k++) {
    const gy = Math.round(Y(k * step)) + 0.5;
    ctx.moveTo(x0, gy); ctx.lineTo(x1, gy);
  }
  ctx.stroke();

  // уставки: пунктир — там, где плата ударит аварией
  ctx.setLineDash([4, 4]);
  ctx.strokeStyle = col;
  ctx.fillStyle = col;
  for (const m of marks) {
    if (m.v <= 0 || m.v > top) continue;
    const gy = Math.round(Y(m.v)) + 0.5;
    ctx.beginPath(); ctx.moveTo(x0, gy); ctx.lineTo(x1, gy); ctx.stroke();
    // Подпись всегда внутри поля: у линии у самого верха текст, нарисованный
    // над ней, обрезался краем холста («не выше 2000» вылезало наружу).
    ctx.fillText(m.t, x0 + 3, gy - 3 < y0 + 8 ? gy + 11 : gy - 3);
  }
  ctx.setLineDash([]);

  // подписи осей: слева величина, снизу время. Дробных знаков столько, сколько
  // нужно шагу: при step=0,05 одна цифра после запятой дала «0,1» и «0,1» в
  // соседних строках — то же наложение, только из-за округления.
  const dec = step < 0.1 ? 2 : step < 1 ? 1 : 0;
  ctx.fillStyle = col;
  for (let k = 0; k <= nDiv; k++) {
    const v = k * step;
    ctx.fillText(v.toFixed(dec), 4, Y(v) + 3);
  }
  ctx.fillStyle = CH_TXT;
  for (let s = 0; s <= 60000; s += 10000) {
    const gx = x0 + s / 60000 * (x1 - x0);
    // последнюю подпись (сейчас) прижимаем к правому краю, иначе она уезжает
    ctx.textAlign = s === 60000 ? 'right' : 'center';
    ctx.fillText(clock(T0 + s), Math.min(Math.max(gx, 18), x1), y1 + 12);
  }
  ctx.textAlign = 'left';

  if (!live) {                       // вместо пустого поля — прямое объяснение
    ctx.fillStyle = CH_TXT;
    ctx.textAlign = 'center';
    ctx.fillText(noData, (x0 + x1) / 2, (y0 + y1) / 2);
    ctx.textAlign = 'left';
    return;
  }
  // линия значений. Отрезки, где значение подставлено стендом, идут
  // пунктиром и другим цветом: подмена — не замер, и выдавать её за замер
  // нельзя, особенно когда график смотрят, разбираясь с закусыванием.
  if (data.length < 2) return;
  const flag = key === 'rpm' ? 'sr' : 'sc';
  ctx.lineWidth = 1.5;
  for (let k = 0; k < data.length - 1;) {
    const sim = !!data[k][flag];
    ctx.strokeStyle = sim ? CH_SIM : col;
    ctx.setLineDash(sim ? [4, 3] : []);
    ctx.beginPath();
    ctx.moveTo(X(data[k].t), Y(data[k][key]));
    let n = k + 1;
    while (n < data.length && !!data[n][flag] === sim) {
      ctx.lineTo(X(data[n].t), Y(data[n][key])); n++;
    }
    if (n < data.length) ctx.lineTo(X(data[n].t), Y(data[n][key]));  // точка склейки
    ctx.stroke();
    k = n;
  }
  ctx.setLineDash([]);
  ctx.lineWidth = 1;
}

// ---------- ответы и журнал ----------
function onReply(d) {
  STATE.lastReply = d.text;
  const el = $('lastReply');
  el.textContent = d.text.startsWith('ERR') ? 'плата: ' + d.text : d.text;
  el.title = d.text;          // в шапке строка обрезается — целиком по наведению
  el.className = 'dim ' + (d.text.startsWith('ERR') ? 'bad-text' : 'ok-text');
}
function onLog(d) {
  if (STATE.logPaused) return;
  const pre = $('logList');
  const dt = new Date(d.t);
  // Новые строки встают сверху, поэтому при добавлении строки ползунок
  // прокрутки сам по себе уезжает и оператор читает не ту строку, за которой
  // стоял. Запоминаем, где он был, и держим ту же картинку.
  const wasTop = pre.scrollTop === 0;
  const wasH = pre.scrollHeight;
  pre.textContent = (dt.toTimeString().slice(0, 8) + '  ' + d.s + '\n') + pre.textContent;
  if (pre.textContent.length > 20000) pre.textContent = pre.textContent.slice(0, 20000);
  if (wasTop) pre.scrollTop = 0;
  else pre.scrollTop += pre.scrollHeight - wasH;
}
$('logPause').onclick = (e) => {
  STATE.logPaused = !STATE.logPaused;
  e.target.textContent = STATE.logPaused ? 'пауза ▸' : 'пауза';
};
$('logClear').onclick = () => { $('logList').textContent = ''; };
$('logDl').onclick = () => {
  const blob = new Blob([$('logList').textContent], { type: 'text/plain' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'jmd2l-log.txt';
  a.click();
  URL.revokeObjectURL(a.href);
};

// ---------- защита: вкл/выкл, метод, уставки ----------
// Метод в панели: cfg[0] — 0 выкл, 1..4 метод. Кнопка и список при аварии
// заблокированы: снять защиту в момент закусывания нельзя.
function renderProt(st) {
  const on = STATE.protOn;                 // что показываем (в RAM или из cfg)
  const btn = $('protToggle');
  btn.textContent = on ? 'Защита: ВКЛ' : 'Защита: ВЫКЛ';
  btn.className = 'protbtn' + (on ? '' : ' off');
  btn.disabled = !!st.ft;                  // при аварии защиту не трогаем
  $('protSel').disabled = !!st.ft || !on;  // метод задаём, только когда включена
  // Плашка взвода: пока порог не взят, видно, сколько ждать. Со страховкой
  // (шпиндель не дотянул) — красная: значит порог завышен и защита включится
  // не по делу.
  const thrArm = STATE.cfg ? (STATE.cfg[10] | 0) : 400;
  const rpmArm = st.sd.ro ? st.sd.r : 0;
  const over = thrArm > 0 && rpmArm >= thrArm;
  $('armState').textContent = !on ? 'защита отключена' :
    (st.sd.ar ? (st.sd.aw ? 'взвелась: порог завышен'
                  : (st.sd.al > 0 ? 'взводится, через ' + st.sd.al + ' мс' : 'взведена'))
              : (over ? 'порог взят, но не взведена' : 'ждём ' + thrArm + ' об/мин'));
  $('armState').className = 'tag ' + (!on ? 'bad'
    : (st.sd.ar ? (st.sd.aw ? 'bad' : 'ok') : (over ? 'bad' : 'dim')));
  $('armState').title = st.sd.aw
    ? 'Шпиндель крутится, но до порога взвода не дотянул — включилась страховка. Порог завышен.'
    : (over && !st.sd.ar
      ? 'Обороты выше порога, а взвода нет: скорее всего, плата сбросила его аварией по току. Сбросьте аварию.'
      : '');
  // предупреждение только одно: защиту снял оператор. Состояние датчика
  // тока и так написано рядом с амперажом — второй плашкой не нужно.
  const w = $('protWarn');
  if (!on) {
    w.className = 'warn';
    w.textContent = 'ВНИМАНИЕ: защита отключена — контроль оборотов и тока не выполняется.';
  } else w.classList.add('hidden');
}
// Уставки двигаем сразу в cfg платы (T), кнопка «Применить» пишет EEPROM (TS).
function thrRead() {
  const n = (id, d) => { const v = parseFloat($(id).value); return isFinite(v) ? v : d; };
  return [
    ['1', Math.round(n('thrRpmLo', 400))],
    ['2', Math.round(n('thrRpmHi', 2000))],
    ['5', Math.round(n('thrCur', 7) * 10)],   // в А, плата ждёт ×0.1
    ['9', Math.round(n('thrSpin', 200))],    // задержка после пуска шпинделя
    ['10', Math.round(n('thrArm', 400))],    // порог взвода защиты
  ];
}
// «Применить» в карточке Безопасности пишет ТОЛЬКО то, что в ней же и стоит:
// метод защиты и её уставки. Скорости ползунков и длины хода сохраняются сами
// (saveLater), а пресеты — кнопкой во вкладке «Настройки». Раньше сюда попадали
// ещё и скорости с пресетами: это означало, что смена ползунка не сохранялась,
// пока оператор не зайдёт в «Безопасность» и не нажмёт кнопку, — то есть
// ровно то, от чего он ушёл.
$('thrApply').onclick = () => {
  // Метод живёт в protSel, отдельного поля метода в уставках нет. Без этой
  // строки кнопка записала бы уставки «Обороты и ток», а защита осталась бы в
  // прежнем методе, и панель показывала бы настройку, которая не применяется.
  cmd('T 0 ' + (STATE.protOn ? STATE.protMethod : 0));
  for (const [i, v] of thrRead()) cmd('T ' + i + ' ' + v);
  // На стенде уставки живут только в ОЗУ платы: в EEPROM не пишем, при выходе
  // стенд вернёт рабочие. На станке — как обычно.
  if (!STATE.benchOn) cmd('TS');
  setTimeout(() => cmd('T'), 80);            // перечитать: плата клампит за пределы
  STATE.saved = STATE.benchOn
    ? 'уставки стенда применены (в память платы не писались)'
    : 'настройки безопасности сохранены';
  renderSaved();
};
$('protToggle').onclick = () => {
  STATE.protOn = !STATE.protOn;
  cmd('T 0 ' + (STATE.protOn ? STATE.protMethod : 0));   // в EEPROM не пишем
  renderProt(STATE.st || { sd: {} });
};
$('protSel').onchange = (e) => {
  STATE.protMethod = Number(e.target.value);
  if (!STATE.protOn) STATE.protOn = true;     // выбор метода включает защиту
  cmd('T 0 ' + STATE.protMethod);
  renderProt(STATE.st || { sd: {} });
};

// ---------- глобальные кнопки ----------
$('btnStopAll').onclick = () => cmd('X');
$('btnResetFault').onclick = () => cmd('!');
$('btnChart').onclick = () => {
  STATE.chartOn = !STATE.chartOn;
  $('chartRpmCard').classList.toggle('hidden', !STATE.chartOn);
  $('chartCurCard').classList.toggle('hidden', !STATE.chartOn);
  $('btnChart').textContent = STATE.chartOn ? 'скрыть графики' : 'показать графики';
  if (STATE.chartOn) drawChart();
};
// Холсты держим в «железных» пикселях — после изменения размера буфер надо
// пересоздать, иначе сетка и цифры поплывут.
window.addEventListener('resize', drawChartThrottled);
// То же при смене вкладки и переезде блока: без этого первый кадр рисуется
// на старых размерах и растягивается по высоте.
if (window.ResizeObserver) {
  const ro = new ResizeObserver(drawChartThrottled);
  ro.observe($('chartRpm'));
  ro.observe($('chartCur'));
}
$('tabMain').onclick = () => setTab('main');
$('tabSets').onclick = () => setTab('sets');
$('tabSetup').onclick = () => setTab('setup');
$('tabBench').onclick = () => setTab('bench');
function setTab(t) {
  // «Стенд» — это та же самая страница управления плюс блок имитации сверху.
  // Второй копии страницы нет: одна разметка, одни обработчики, одна картина
  // аварий — ровно как на станке.
  const bench = t === 'bench';
  // Вход/выход стенда — по флагу, а не по видимости блока: benchEnter кладёт
  // в ОЗУ платы «датчики подключены» и «ход при стоящем шпинделе», benchExit
  // возвращает рабочие. В EEPROM стенд не пишет.
  if (STATE.benchOn && !bench) benchExit();
  if (bench && !STATE.benchOn) benchEnter();
  $('viewMain').classList.toggle('hidden', t !== 'main' && !bench);
  $('viewSets').classList.toggle('hidden', t !== 'sets');
  $('viewSetup').classList.toggle('hidden', t !== 'setup');
  $('viewBench').classList.toggle('hidden', !bench);
  // Графики на стенде показываем: подмена на них идёт пунктиром и отдельным
  // цветом, так что подмена не выдаётся за замер. Раньше графики на стенде
  // прятались — толку от них не было, а оператор их и не просил убирать.
  $('chartRpmCard').classList.toggle('hidden', !STATE.chartOn);
  $('chartCurCard').classList.toggle('hidden', !STATE.chartOn);
  $('logCard').classList.remove('hidden');
  $('tabMain').classList.toggle('active', t === 'main');
  $('tabSets').classList.toggle('active', t === 'sets');
  $('tabSetup').classList.toggle('active', t === 'setup');
  $('tabBench').classList.toggle('active', bench);
  if (t === 'sets' || t === 'setup' || bench) cmd('T');   // свежие настройки с платы
  if (t === 'setup') cmd('C');                    // счётчик оборотов с нуля
  if (!bench) drawChart();                         // сетку рисуем сразу, не дожидаясь данных
}

// ---------- клавиатура ----------
document.addEventListener('keydown', (e) => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
  const map = {
    ArrowLeft: { i: 0, d: 0 }, ArrowRight: { i: 0, d: 1 },
    ArrowUp: { i: 1, d: 1 }, ArrowDown: { i: 1, d: 0 },
  };
  const k = map[e.key];
  if (k && !STATE.jogKeys.has(e.key)) {
    e.preventDefault();
    STATE.jogKeys.add(e.key);
    cmd('D ' + (k.i + 1) + ' ' + k.d);
    cmd('G ' + (k.i + 1));
  } else if (e.key === ' ') {
    e.preventDefault();
    if (!e.repeat) cmd('X');
  }
});
document.addEventListener('keyup', (e) => {
  const k = e.key;
  const map = { ArrowLeft: 0, ArrowRight: 0, ArrowUp: 1, ArrowDown: 1 };
  if (k in map && STATE.jogKeys.has(k)) {
    STATE.jogKeys.delete(k);
    const i = map[k];
    // Стоп с клавиатуры - только если ось едет именно джогом. Раньше было
    // безусловно по факту отпускания стрелки: коснулся стрелки во время хода
    // «Выполнить» - отпустил, и ход на 100 мм умирал сам, без всякой кнопки.
    // Проверка на moveSrc, а не на «ось едет»: ехать может и ход, и джог, а
    // останавливать клавиатурой можно только джог.
    if (STATE.moveSrc[i] === 'jog') cmd('S ' + (i + 1));
  }
});

// ---------- старт ----------
buildAxes();
refreshPorts();
setInterval(refreshPorts, 3000);   // автоподхват платы
openSSE();
setTimeout(() => cmd('T'), 300);   // уставки для индикаторов и настроек
drawChart();                        // пустая сетка с подписями — до первых данных
// Настройки в EEPROM пишутся ТОЛЬКО кнопкой «Сохранить» в панели настроек.