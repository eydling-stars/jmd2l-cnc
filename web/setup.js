// JMD-2L CNC — вкладка «Пусконаладка». Пошаговые проверки при первом
// подключении станка. Плату не ломаем: только уже существующие команды.
// Отметки «выполнено» живут в браузере и ни на что не влияют.
'use strict';

// Отметки. Ключ — id шага, значение 1.
const done = JSON.parse(localStorage.getItem('jmd2l-setup') || '{}');
const dirTest = { i: -1, p0: 0, n: 0, t0: 0 };   // тест направления: ось, позиция, шаги, время
let rpmMax = 0;                            // максимум оборотов, видели с открытия

function mark(id) {                      // кнопка-переключатель
  if (done[id]) delete done[id]; else done[id] = 1;
  localStorage.setItem('jmd2l-setup', JSON.stringify(done));
  paintDone();
}
function paintDone() {
  let n = 0, all = 0;
  document.querySelectorAll('[data-ok]').forEach((b) => {
    const on = !!done[b.dataset.ok];
    all++;
    if (on) n++;
    b.classList.toggle('done', on);
    b.textContent = on ? '✓ выполнено' : 'отметить выполненным';
    // Закрытый пункт приглушаем: прогресс виден по всей странице, а не только
    // по счётчику в шапке.
    const card = b.closest('.card');
    if (card) card.classList.toggle('okdone', on);
  });
  document.querySelectorAll('[data-state]').forEach((s) => {
    const on = !!done[s.dataset.state];
    s.textContent = on ? 'проверено' : 'не проверено';
    s.className = 'tag ' + (on ? 'ok' : 'dim');
  });
  const p = $('setupProg'), f = $('setupFill');
  if (p) p.textContent = n + ' из ' + all + (n === all && all ? ' — готово' : '');
  if (p) p.className = 'tag ' + (n === all && all ? 'ok' : (n ? 'warn' : 'dim'));
  if (f) f.style.width = (all ? Math.round(n / all * 100) : 0) + '%';
}

// ---------- строки, которые собираются из данных платы ----------
function buildRows() {
  const AXN = ['X', 'Y'];
  // Строка на ось: ось — действие — действие — результат. Отметку «выполнено»
  // (она общая на обе оси) переносим в конец последней строки, чтобы стояла
  // рядом с «Проверить +2 мм», а не отдельной строкой под таблицей.
  $('dirRows').innerHTML = AXN.map((n, i) =>
    '<div class="bar">' +
      '<span class="cell">ось ' + n + '</span>' +
      '<button data-act="dirTest" data-ax="' + i + '">Проверить +2 мм</button>' +
      '<button data-act="dirInv" data-ax="' + i + '">Инвертировать</button>' +
      '<span class="live" id="spDir' + i + '">—</span>' +
    '</div>'
  ).join('');
  const bars = $('dirRows').querySelectorAll('.bar');
  const okBtn = $('dirOk').querySelector('[data-ok]');
  if (bars.length && okBtn) {
    bars[bars.length - 1].appendChild(okBtn);
    $('dirOk').remove();          // пустая полоса-обёртка больше не нужна
  }
  const LN = ['X-1', 'X-2', 'Y-1', 'Y-2'];
  $('limRows').innerHTML = LN.map((n, i) =>
    '<span class="lim" id="spLim' + i + '">' + n + '</span>'
  ).join('');
  paintDone();
}

// ---------- действия ----------
function act(a, b) {
  const i = b.dataset.ax ? Number(b.dataset.ax) : 0;
  const ax = i + 1;
  const cfg = STATE.cfg || [];
  switch (a) {
    case 'curCal':
      $('spCur0').textContent = 'меряем…';
      cmd('K');
      setTimeout(() => cmd('T'), 300);   // вернётся новый ноль — обновить подпись
      break;
    case 'tachSave': {
      const v = Math.round(Number($('spPpr').value) || 0);
      if (v > 0) { cmd('T 3 ' + v); cmd('TS'); $('spRpm').textContent = 'записано: ' + v; }
      else $('spRpm').textContent = 'впишите число прорезей';
      break;
    }
    case 'tachClr':
      cmd('C');
      $('spRpm').textContent = 'счётчик обнулён';
      break;
    case 'turn':   // ровно один оборот мотора: столько шагов, сколько в DIP
      cmd('D ' + ax + ' 0');
      cmd('V ' + ax + ' 300');
      cmd('N ' + ax + ' ' + (cfg[20 + i * 5] || 400));
      $('spCalc' + i).textContent = 'ось едет, измерьте путь';
      break;
    case 'calc': {  // мкм на оборот = измеренный путь в мм × 1000
      const l = Number($('spLen' + i).value);
      if (!(l > 0)) { $('spCalc' + i).textContent = 'впишите путь в мм'; break; }
      const um = Math.round(l * 1000);
      cmd('T ' + (21 + i * 5) + ' ' + um);
      cmd('TS');
      $('spCalc' + i).textContent = 'записано ' + um + ' мкм/об';
      break;
    }
    case 'dirTest': {
      const st = STATE.st;
      if (!st) { $('spDir' + i).textContent = 'нет связи с платой'; break; }
      const n = Math.max(20, Math.round(st.ax[i].sp * 2));
      cmd('D ' + ax + ' 0');
      cmd('V ' + ax + ' 300');
      dirTest.i = i; dirTest.p0 = st.ax[i].p; dirTest.n = n; dirTest.t0 = Date.now();
      cmd('N ' + ax + ' ' + n);
      $('spDir' + i).textContent = 'едем +2 мм…';
      break;
    }
    case 'dirInv': {
      const v = cfg[23 + i * 5] ? 0 : 1;
      cmd('T ' + (23 + i * 5) + ' ' + v);
      $('spDir' + i).textContent = 'инверсия ' + v + ' — проверьте ход ещё раз';
      break;
    }
    case 'limPol': {
      const v = cfg[13] ? 0 : 1;
      cmd('T 13 ' + v);
      cmd('TS');
      $('limRows').title = 'полярность ' + v;
      break;
    }
    case 'relOn': cmd('RL 1'); break;
    case 'relOff': cmd('RL -1'); break;
    case 'toMain': setTab('main'); break;
  }
}

document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-ok],[data-act]');
  if (!b) return;
  if (b.dataset.ok) mark(b.dataset.ok);
  else act(b.dataset.act, b);
});

// ---------- живые значения ----------
function renderSetup(st) {
  // Тест направления доводим до конца всегда, даже если оператор ушёл на
  // другую вкладку: иначе результат потеряется.
  if (dirTest.i >= 0) {
    const i = dirTest.i, a = st.ax[i];
    if (!a.r && !a.g && Date.now() - dirTest.t0 > 400) {
      const d = a.p - dirTest.p0;
      $('spDir' + i).textContent =
        d === 0 ? 'позиция не изменилась — ось не поехала'
        : d > 0 ? 'позиция выросла на ' + d + ' шаг — верно'
        : 'позиция упала на ' + (-d) + ' шаг — нажмите «Инвертировать»';
      dirTest.i = -1;
    }
  }
  if ($('viewSetup').classList.contains('hidden')) return;   // на других вкладках не считаем
  const cfg = STATE.cfg || [];
  $('spCur0').textContent = st.sd.co
    ? 'сейчас ' + (st.sd.c / 10).toFixed(1) + ' А, ноль ' + (cfg[6] || 0) + ' мВ'
    : 'датчик не отвечает';
  if (st.sd.r > rpmMax) rpmMax = st.sd.r;
  $('spRpm').textContent = st.sd.ro ? st.sd.r + ' об/мин, максимум ' + rpmMax : 'нет импульсов';
  $('spMmX').textContent = st.ax[0].sp.toFixed(3) + ' шаг/мм';
  $('spMmY').textContent = st.ax[1].sp.toFixed(3) + ' шаг/мм';
  let lp = 0;
  for (let i = 0; i < 4; i++) {
    $('spLim' + i).classList.toggle('on', !!(st.lm & (1 << i)));
    if (st.lm & (1 << i)) lp++;
  }
  $('spLimN').textContent = 'нажато: ' + lp + ' из 4';
  $('spRel').textContent = st.rl ? 'реле ВКЛ' : 'реле выключено';
}

buildRows();
