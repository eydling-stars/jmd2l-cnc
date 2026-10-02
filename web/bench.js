// JMD-2L CNC — «Мекетный стенд». Копии страницы управления нет: страница одна
// (viewMain), а сверху — подмена датчиков. Защита и приводы ЖИВЫЕ: стенд ничего
// не пишет в EEPROM, меняет настройки только в ОЗУ платы и на выходе возвращает
// рабочие. Кнопка «Эмуляция» включает подмену: обороты и ток идут с ползунков,
// концевики — с кнопок, вместо настоящих датчиков.
'use strict';

const BN_LIM = ['X-1', 'X-2', 'Y-1', 'Y-2'];
// Настройки, которые стенд трогает в ОЗУ платы: метод и уставки защиты, маска
// датчиков, «ход при стоящем шпинделе». Снимок рабочих значений берём на входе и
// возвращаем на выходе — EEPROM не при чём.
const BN_RESTORE = [0, 1, 2, 5, 9, 10, 14, 30];
const BENCH = { sim: false, ctrl: null };

// Ползунок дёргают десятки раз в секунду. Каждое значение в очередь не пишем:
// ждём 120 мс и отправляем последнее — глаз разницы не видит, а плата не
// забивается мусором. Отложенное значение хранится ПО КАНАЛУ: иначе два
// ползунка, задёрганные подряд, съели бы друг друга.
const pend = {}, timer = {};
function feed(key, text) {
  pend[key] = text;
  if (timer[key]) return;
  timer[key] = setTimeout(() => {
    delete timer[key];
    const t = pend[key];
    delete pend[key];
    cmd(t);
  }, 120);
}

function buildBench() {
  $('benchLim').innerHTML = BN_LIM.map((n, i) =>
    '<button class="lim" id="bLim' + i + '" data-act="lim' + i + '">' + n + '</button>'
  ).join('');
  $('smRpm').oninput = () => {
    $('smRpmVal').textContent = $('smRpm').value;
    if (BENCH.sim) feed('r', 'RP ' + ($('smRpm').value | 0));
  };
  $('smCur').oninput = () => {
    $('smCurVal').textContent = ($('smCur').value / 10).toFixed(1);
    if (BENCH.sim) feed('c', 'CU ' + ($('smCur').value | 0));
  };
  $('bnSim').onclick = () => benchSim(!BENCH.sim);
}

// Подмена оборотов и тока. Пока выключена — плата читает настоящие датчики;
// включённая — берёт значения с ползунков.
function benchSim(on) {
  BENCH.sim = on;
  const b = $('bnSim');
  b.textContent = 'Эмуляция: ' + (on ? 'ВКЛ' : 'ВЫКЛ');
  b.className = 'accent mini' + (on ? '' : ' off');
  if (on) {
    cmd('RP ' + ($('smRpm').value | 0));
    cmd('CU ' + ($('smCur').value | 0));
  } else {
    cmd('RP -1');
    cmd('CU -1');
  }
}

// Вход на стенд: снять старую подмену, запомнить рабочие настройки и поставить
// в ОЗУ платы «датчики подключены» и «ход при стоящем шпинделе» — на стенде
// шпинделя нет, а концевики нужны для проверки защиты.
function benchEnter() {
  BENCH.ctrl = STATE.cfg ? STATE.cfg.slice() : null;
  STATE.benchOn = true;
  cmd('T 30 7');
  cmd('T 14 1');
  benchSim(false);
  for (let i = 0; i < 4; i++) cmd('L ' + i + ' -1');
}

// Выход: снять подмену, остановить оси и вернуть плате рабочие настройки.
// В EEPROM ничего не писали, поэтому достаточно ОЗУ.
function benchExit() {
  STATE.benchOn = false;
  benchSim(false);
  for (let i = 0; i < 4; i++) cmd('L ' + i + ' -1');
  cmd('S 1');
  cmd('S 2');
  const c = BENCH.ctrl;
  if (c) {
    for (const i of BN_RESTORE) cmd('T ' + i + ' ' + (c[i] | 0));
    cmd('R 1 ' + (c[35] | 0));      // вернуть рабочую скорость осей
    cmd('R 2 ' + (c[36] | 0));
  }
  BENCH.ctrl = null;
  cmd('T');                          // панель перечитает возвращённые настройки
}

function renderBench(st) {
  if ($('viewBench').classList.contains('hidden')) return;
  for (let i = 0; i < 4; i++) $('bLim' + i).classList.toggle('on', !!(st.lm & (1 << i)));
}

// ---------- кнопки ----------
function benchAct(a) {
  switch (a) {
    case 'smLimOff':
      for (let i = 0; i < 4; i++) cmd('L ' + i + ' -1');
      break;
    case 'lim0': case 'lim1': case 'lim2': case 'lim3': {
      const i = Number(a.slice(3));
      const on = !(STATE.st && (STATE.st.lm & (1 << i)));
      cmd('L ' + i + ' ' + (on ? 1 : -1));
      break;
    }
  }
}

document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-act]');
  if (b && b.dataset.act.match(/^(sm|lim)/)) benchAct(b.dataset.act);
});

buildBench();
