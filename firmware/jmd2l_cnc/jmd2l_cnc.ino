/*
  ============================================================================
  JET JMD-2L - мини-ЧПУ стола: 2 оси + защита от закусывания фрезы
  Arduino Nano v3.0 (ATmega328P, 16 МГц), управление с ПК по USB, ASCII, 115200
  ============================================================================

  КАРТА ПИНОВ
  ----------------------------------------------------------------------------
    Ось X:  PUL = D9 (PB1)   DIR = D8 (PB0)   ENA = D7 (PD7)
    Ось Y:  PUL = D6 (PD6)   DIR = D5 (PD5)   ENA = D11 (PB3)
    Тахометр шпинделя:   D2 (PD2, INT0)
    Концевик X-1:        D3 (PD3)
    Концевик X-2:        D4 (PD4)
    Концевик Y-1:        D10 (PB2)
    Концевик Y-2:        D12 (PB4)
    Реле:                D13 (PB5)
    Ток главного привода: A0 (ACS712)
    D0/D1 (RX/TX) заняты USB. A1..A7 свободны.

  ПОДТЯЖКИ - ВНУТРЕННИЕ, на всех пяти входах, резисторы не нужны
  ----------------------------------------------------------------------------
  Все пять входов в setup() включены как INPUT_PULLUP: в покое подтяжка держит
  пин на +5 В, выключатель заземляет его. Поэтому S_LIMITPOL = 0 ("нажатие гасит").

  Раньше здесь стоял вывод, что внутренняя подтяжка не годится: генерация шагов -
  это чтение-изменение-запись порта (PORTB ^= бит), и якобы такая запись
  возвращает в порт состояния всех пинов, включая входы, из-за чего нажатый
  выключатель (LOW) гасит подтяжку и концевик "залипает" навсегда. Это неверно:
  чтение PORTx возвращает содержимое регистра-защёлки, а для входного пина этот
  бит и есть как раз включение подтяжки - он возвращается на место. Гасить
  подтяжку может только запись в DDRx или явный PORTx = 0, и того и другого
  после setup() в коде нет. Внешний резистор 4.7 кОм тоже не повредит: две
  подтяжки вместе дают ту же логику, так что их можно докупить позже, если
  длинные провода у станка начнут ловить наводки, ничего не меняя в настройках.

  Схема включения драйверов: общая анодная. PUL+/DIR+/ENA+ платы на "+"
  драйвера, все "-" на GND платы. Реле активно-LOW (модуль KY-019).

  ПРИНЦИПЫ, КОТОРЫЕ ДЕРЖИТ ЭТОТ КОД
  ----------------------------------------------------------------------------
  1. Прерывание 40 кГц (тик 25 мкс) делает ТОЛЬКО генерацию шагов и рамп.
     Никаких делений, 32x32 и измерений: всё тяжёлое живёт в loop().
  2. Концевики опрашиваются в loop(), не в прерывании: задержка единицы
     миллисекунд - это 0.03 мм хода, а микровыключатель сам имеет 0.5-1 мм
     хода. Класть плату ради такого выигрыша - плохая сделка.
  3. Авария останавливает обе оси МГНОВЕННО. Кнопка "стоп" - с рампой.
  4. Шпиндель мы не включаем и не выключаем, только измеряем.

  НАСТРОЙКИ (EEPROM, переживают отключение питания)
  ----------------------------------------------------------------------------
  Единый массив cfg[] из NSET значений int32, номера - в индексах S_* и A_*.
  Весь массив отдаётся по команде T?, меняется по T <i> <значение>,
  записывается по TS, сбрасывается к умолчаниям по TD.
  ============================================================================
*/

#include <Arduino.h>
#include <EEPROM.h>
#include <avr/wdt.h>
#include <avr/pgmspace.h>

#define FW_VER "2.0"

// ---- такты и окна измерения (не настройки) ----
#define TICK_HZ        40000UL   // частота прерывания Timer1
#define TICK_US        25UL
#define ACC_TOP        20000U    // порог фазового аккумулятора = TICK_HZ/2.
                                   // Вдвое меньше TICK_HZ, поэтому максимум
                                   // acc < 20000 + hz <= 20000 + 20000 = 39999
                                   // влезает в uint16_t без переполнения
#define MAX_HZ         ACC_TOP   // предел шагов/с: на период нужны два
                                   // переключения PUL (фронт + срез)
#define RPM_WINDOW_MS  300       // окно счёта оборотов
#define CUR_SAMPLES    16        // отсчётов АЦП на одно измерение тока
#define CUR_PERIOD_MS  20
#define LIMIT_DEB_MS   20        // дребезг концевиков
// Насколько шпиндель обязан прибавить оборотов, чтобы страховка взвода
// (S_ARMWAIT) начала отсчёт заново. Помеха тахометра — единицы об/мин, а
// разгон идёт десятками: 20 от/мин отсекает дрожь показаний и не даёт
// медленному разгону выглядеть как «шпиндель стоит».
#define SPINUP_EPS 20

// ---- индексы настроек ----
#define S_PROT        0    // метод защиты 0..5
#define S_RPMSTOP     1
#define S_RPMMAX      2
#define S_PPR         3    // импульсов на оборот
#define S_RPMMS       4    // время подтверждения по оборотам
#define S_CUR10       5    // уставка тока, 0.1 А
#define S_CURZERO     6    // ноль датчика тока, мВ
#define S_CURSENS     7    // чувствительность датчика тока, мВ/А
#define S_CURMS       8    // время подтверждения по току
#define S_STARTMS     9    // задержка после пуска шпинделя (в панели — «Вращение»)
#define S_RESTART     10   // порог перезапуска защиты, об/мин
#define S_RELAYMODE   11   // 0 выкл, 1 импульс, 2 удержание
#define S_RELAYPULSE  12
#define S_LIMITPOL    13   // 0 = нажатие даёт LOW (НЗ), 1 = HIGH (НО)
#define S_MOVENOSP    14   // 0 = нельзя двигать стол при стоящем шпинделе
#define S_LINKTO      15   // потеря связи, мс (0 = не контролировать)
#define S_SUSTENA     16   // 1 = держать ENA при остановке (удержание)
#define S_RPMEDGE     17   // 0 = счёт по спаду, 1 = по фронту
#define S_RPMNOISE    18   // фильтр тахометра, мкс
#define S_RELAYPOL    19   // 0 = реле активно-LOW, 1 = активно-HIGH
#define A_BASE        20              // с этого индекса идут настройки осей
#define A_SPR(i)      (A_BASE + 5 * (i))   // шагов на оборот
#define A_UMREV(i)    (A_BASE + 5 * (i) + 1)   // мкм на оборот вала мотора
#define A_ACCEL(i)    (A_BASE + 5 * (i) + 2)   // шагов/с^2, 0 = без рампы
#define A_DIRINV(i)   (A_BASE + 5 * (i) + 3)
#define A_ENAPOL(i)   (A_BASE + 5 * (i) + 4)
#define S_SENS        30              // какие датчики реально подключены, биты
#define SENS_TACH     1               // бит 0: тахометр
#define SENS_CUR      2               // бит 1: датчик тока
#define SENS_LIM      4               // бит 2: концевики
#define S_ARMWAIT     31              // страховка взвода: мс на недобор оборотов
#define S_PRES0       32              // пресеты хода, мм/мин: точная
#define S_PRES1       33              // рабочая
#define S_PRES2       34              // быстрая
#define S_SPD0        35              // скорость оси X, об/мин (как на ползунке)
#define S_SPD1        36              // скорость оси Y, об/мин
#define A_SPD(i)      (S_SPD0 + (i))
#define S_RUN0        37              // длина хода оси X, мкм (поле «ход, мм»)
#define S_RUN1        38              // длина хода оси Y, мкм
#define A_RUN(i)      (S_RUN0 + (i))
// Индексы 39, 40, 41 заняты бывшим «домашним положением» и «скоростью привода
// в дом». Дома на станке нет, но поля оставлены в структуре на своих местах:
// NSET и STORE_VER менять нельзя — сократится запись, не сойдётся CRC, и плата
// возьмёт умолчания, то есть сбросит ВСЕ настройки разом.
#define S_ARMNOSENS   42              // взвод защиты без датчиков: не ждать оборотов
#define NSET          43

// ---- коды аварий ----
#define F_NONE     0
#define F_RPMLOW   1
#define F_RPMHIGH  2
#define F_CURRENT  3
#define F_LIMIT    4
#define F_LINK     5

// ---------------------------------------------------------------------------
// Настройки
// ---------------------------------------------------------------------------
int32_t cfg[NSET];
uint8_t cfgDefaults = 1;          // 1 = приняты умолчания (CRC не сошёлся)

const int32_t DEFAULTS[NSET] PROGMEM = {
  4,        // S_PROT       по умолчанию RPM+ТОК
  400,      // S_RPMSTOP
  2000,     // S_RPMMAX
  100,      // S_PPR
  350,      // S_RPMMS
  70,       // S_CUR10      7.0 А
  2500,     // S_CURZERO
  100,      // S_CURSENS    мВ/А
  350,      // S_CURMS
  1500,     // S_STARTMS
  400,      // S_RESTART
  1,        // S_RELAYMODE  импульс
  300,      // S_RELAYPULSE
  0,        // S_LIMITPOL   НЗ (нажатие гасит) — подтяжка INPUT_PULLUP
  0,        // S_MOVENOSP
  3000,     // S_LINKTO
  1,        // S_SUSTENA
  0,        // S_RPMEDGE    счёт по спаду
  150,      // S_RPMNOISE   мкс
  0,        // S_RELAYPOL   активно LOW
  400,      // X шагов/об
  100000,   // X мкм на оборот
  2000,     // X ускорение
  0,        // X инверсия направления
  0,        // X ENA активно LOW — проверено на стенде: с HIGH мотор стоял,
            // ENA на панели показывался «вкл», а драйвер держал выключенным
  400,      // Y
  100000,   // Y
  2000,     // Y
  0,        // Y
  0,        // Y ENA активно LOW
  7,        // S_SENS    все датчики подключены
  3000,     // S_ARMWAIT страховка: 3 с на недобор до порога
  150,      // S_PRES0   точная, об/мин
  500,      // S_PRES1   рабочая, об/мин
  1500,     // S_PRES2   быстрая, об/мин
  300,      // S_SPD0    ось X, об/мин — ползунок после перезагрузки
  300,      // S_SPD1    ось Y
  100000,   // S_RUN0    длина хода X, мкм (поле «ход, мм»)
  100000,   // S_RUN1    длина хода Y
  0,        // 39        резерв (было домашнее положение X)
  0,        // 40        резерв (было домашнее положение Y)
  60,       // 41        резерв (была скорость привода в дом)
  0         // S_ARMNOSENS взвод без датчиков: выключен
};

// Границы значений: защита от мусора из панели и от деления на ноль.
// int32, потому что микрометров на оборот бывает больше 32767.
const int32_t RLO[NSET] PROGMEM = {
  0, 0, 0, 1, 10, 1, 0, 1, 10, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 0, 0, 0, 1, 1, 0, 0, 0,
  0,
  0,
  1, 1, 1,
  0, 0,
  0, 0,
  0, 0,
  1,
  0
};
// Шаги на оборот (20 и 25) держат 25600 — верх диапазона DIP DM542, чтобы
// любой переключатель записывался без обрезки и панель не врала в миллиметрах.
const int32_t RHI[NSET] PROGMEM = {
  5, 6000, 6000, 2000, 60000, 200, 4095, 400, 60000, 60000, 6000, 2, 60000,
  1, 1, 600000, 1, 1, 2000, 1,
  25600, 4000000, 100000, 1, 1, 25600, 4000000, 100000, 1, 1,
  7,
  60000,
  6000, 6000, 6000,      // пресеты и сохранённые скорости — об/мин, тот же
                          // верхний край, что у оборотов; в мм/мин панель
                          // записывала бы 60000, а плата резала бы по оборотам
  6000, 6000,
  4000000, 4000000,       // длина хода, мкм (те же 4000 мм, что и у мкм/об)
  1, 1,                   // резерв (было домашнее положение: концевик и
                          // сторона, с которой ось к нему ехала, 0..3)
  6000,                   // резерв (была скорость привода в дом, мм/мин)
  1                       // взвод без датчиков: 0/1
};

#define STORE_MAGIC 0xA3C7
// Дома с 2026-10-02 на станке нет: команды H и HC, обнуление Z и поля 39..41
// из структуры убраны, но NSET и версия остались. Иначе запись сократилась бы,
// не сошёлся CRC, и плата взяла бы умолчания, сбросив ВСЕ настройки разом:
// версию поднимать нельзя, пока sizeof(Store) прежний. Разбор версии 9 работает
// с записью той же длины, поэтому STORE_VER не трогаем.
// 9: добавлен взвод защиты без датчиков S_ARMNOSENS.
// 8: добавлена скорость привода в дом S_HOMESPD.
// 7: добавлен выбор домашнего концевика S_HOME0..1 (№1 или №2 на каждую ось)
// и новый привод в дом: один подход и отход до отпускания концевика.
// 6: добавлены длины хода S_RUN0..1; пресеты и сохранённые скорости переведены
// в об/мин; ENA по умолчанию активно LOW (проверено на стенде).
// 5: сохранённые скорости осей S_SPD0..1 — ползунок переживает перезагрузку.
// 4: пресеты хода S_PRES0..2. Версия растёт при каждом расширении NSET:
// sizeof(Store) меняется, CRC старой записи не сходится, и плата
// честно берёт умолчания, вместо того чтобы читать мусор на месте новых полей.
// Здесь раньше стоял второй #define STORE_VER 4, и он перебивал номер: плата
// считала себя версией 4, отвергала свежую запись и сбрасывала настройки в
// умолчания. Один #define — одна версия.
#define STORE_VER   9
struct Store {
  uint16_t magic;
  uint8_t  ver;
  int32_t  v[NSET];
  uint16_t crc;
} __attribute__((packed));

static uint16_t crc16(const uint8_t *d, uint16_t n) {
  uint16_t c = 0xFFFF;
  while (n--) {
    c ^= *d++;
    for (uint8_t i = 0; i < 8; i++) c = (c & 1) ? (c >> 1) ^ 0xA001 : (c >> 1);
  }
  return c;
}

static void settingsDefaults() {
  for (uint8_t i = 0; i < NSET; i++)
    cfg[i] = (int32_t)pgm_read_dword(&DEFAULTS[i]);
  cfgDefaults = 1;
}

static void settingsLoad() {
  Store st;
  EEPROM.get(0, st);
  const uint8_t *raw = (const uint8_t *)&st;
  if (st.magic == STORE_MAGIC && st.ver == STORE_VER &&
      crc16(raw, sizeof(Store) - 2) == st.crc) {
    memcpy(cfg, st.v, sizeof(cfg));
    cfgDefaults = 0;
  } else {
    settingsDefaults();
  }
}

static void settingsSave() {
  Store st;
  st.magic = STORE_MAGIC;
  st.ver = STORE_VER;
  memcpy(st.v, cfg, sizeof(cfg));
  st.crc = crc16((const uint8_t *)&st, sizeof(Store) - 2);
  EEPROM.put(0, st);
}

// ---------------------------------------------------------------------------
// Ось
// ---------------------------------------------------------------------------
struct Axis {
  uint8_t dport, dbit;             // DIR
  uint8_t eport, ebit;             // ENA
  float   spm;                     // шагов на мм, посчитано из настроек
  uint8_t dirInv, enaPol, enaOn;

  volatile uint8_t  dir, running, targetActive, enaGuard, rampOn;
  volatile uint16_t hz, hzNow;     // заданная и мгновенная частота, шаг/с
  uint16_t           acc;          // фазовый аккумулятор. НЕ volatile: только
                                   // ISR. Иначе каждое обращение разбивается
                                   // на 2 байтовых, а 25 мкс на это не хватает
  volatile long     pos, target;

  uint32_t hzFp;                   // рамп: hzNow в 1/65536
  uint16_t hzGoal;                 // куда разгоняемся (0 = тормозим)
  uint32_t rampInc, brakeAt;       // прирост за тик, с какого остатка тормозим
  uint16_t accel;
};

// порядок полей: dport dbit eport ebit spm dirInv enaPol enaOn
//                dir running targetActive enaGuard rampOn hz hzNow acc pos target
//                hzFp hzGoal rampInc brakeAt accel
Axis axes[2] = {
  { 0, _BV(0), 1, _BV(7), 4.0f, 0, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0L, 0L, 0L, 0, 0L, 0L, 0, 0 },
  { 1, _BV(5), 0, _BV(3), 4.0f, 0, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0L, 0L, 0L, 0, 0L, 0L, 0, 0 }
};

volatile uint8_t *pOut[2] = { &PORTB, &PORTD };

// Счётчики для проверки, что ISR укладывается в 25 мс: если таймер начнёт
// терять тики, плата замрёт - это заметно раньше, чем повредится механика.
// uint16_t, а не uint8_t: если цикл хоть раз простоит дольше 6.4 мс, байт
// переполнится и мы насчитаем несуществующие "потери тиков"
volatile uint16_t dbgN = 0;        // входы в ISR с прошлой сводки
volatile uint32_t dbgIsr = 0;
volatile uint32_t dbgLoops = 0;
volatile uint32_t dbgT0 = 0;
uint32_t loopMaxUs = 0;            // худший период основного цикла, мкс
uint32_t isrGapMaxUs = 0;          // макс. пауза ISR (время цикла без набежавших тиков)

// ---------------------------------------------------------------------------
// Прерывание 40 кГц: фазовый аккумулятор -> фронты PUL + рампа
// ---------------------------------------------------------------------------
// Тело одной оси. Макрос, а не функция: вызов добавил бы свой
// пролог/эпилог, а это самый дорогой ресурс. Две оси развёрнуты явно.
#define AXIS_STEP(A, PR, BIT)                                                  \
  do {                                                                         \
    Axis &a = (A);                                                             \
    if (a.running) {                                                           \
      /* Рамп: цель в hzGoal, аккумулятор крутит hzNow. Пока рампа выключена,  \
         блок не выполняется вовсе. */                                         \
      if (a.rampOn) {                                                          \
        uint32_t rem = a.dir ? (uint32_t)(a.target - a.pos)                    \
                             : (uint32_t)(a.pos - a.target);                  \
        /* Тормозим только когда есть куда тормозить. При непрерывном        \
           вращении (G) target == pos, rem == 0, и без этой проверки рампа     \
           сразу уходит в спуск: ось стоит, а разгон не идёт. */              \
        if (a.targetActive && rem <= a.brakeAt) {                              \
          /* торможение: симметрично разгону. Раньше здесь был мгновенный     \
             сброс hzFp в ноль: ось замирала за ~d шагов до цели с r=1,g=1  */ \
          if (a.hzFp < a.rampInc) a.hzFp = a.rampInc;                          \
          else a.hzFp -= a.rampInc;                                            \
        } else {                                                               \
          uint32_t g = (uint32_t)a.hzGoal << 16;                              \
          if (a.hzFp < g) {                                                    \
            uint32_t n = a.hzFp + a.rampInc;                                   \
            a.hzFp = (n > g) ? g : n;                                          \
          } else if (a.hzFp > g) {                                             \
            /* Спуск - тоже рампой. Раньше здесь стояло безусловное          \
               a.hzFp = g: при снижении скорости на ходу (ползунок в панели)  \
               разгон обрывался, и ось прыгала на новую скорость одним шагом. \
               На большой разнице это срывало мотор. */                      \
            uint32_t n = (a.hzFp > a.rampInc) ? (a.hzFp - a.rampInc) : 0;     \
            a.hzFp = (n < g) ? g : n;                                          \
          } else a.hzFp = g;                                                   \
        }                                                                      \
        a.hzNow = (uint16_t)(a.hzFp >> 16);                                    \
        if (!a.hzNow) a.hzNow = 1;   /* ползём последние шаги, не глохнем */   \
      }                                                                        \
      /* после смены ENA пропускаем тик: 25 мкс > t1 (5 мкс) из требований */   \
      if (a.enaGuard) a.enaGuard = 0;                                         \
      else {                                                                   \
        uint8_t isHigh = (PR & (BIT)) != 0;                                   \
        a.acc += a.hzNow;                                                     \
        if (a.acc >= ACC_TOP) {                                               \
          a.acc -= ACC_TOP;                                                   \
          PR ^= (BIT);                                                        \
          if (!isHigh) {                       /* нарастающий фронт = 1 шаг */\
            if (a.dir) a.pos++; else a.pos--;                                 \
            if (a.targetActive) {                                             \
              if (a.dir ? (a.pos >= a.target) : (a.pos <= a.target)) {        \
                a.running = 0; a.targetActive = 0; a.rampOn = 0;              \
                a.hzNow = a.hz;                                               \
              }                                                               \
            }                                                                 \
          }                                                                   \
        }                                                                     \
      }                                                                       \
    }                                                                         \
  } while (0)

ISR(TIMER1_COMPA_vect) {
  dbgN++;                      // ровно один байт: суммируется в loop()
  AXIS_STEP(axes[0], PORTB, _BV(1));   // PUL X = D9
  AXIS_STEP(axes[1], PORTD, _BV(6));   // PUL Y = D6
}

// ---- тахометр: счёт импульсов с фильтром помех ----
volatile uint32_t tachCnt = 0;
volatile uint32_t tachLast = 0;

// Имя нужно, чтобы можно было перевесить прерывание на другой фронт при
// смене настройки S_RPMEDGE.
void isrTach() __attribute__((signal, used, externally_visible));
void isrTach() {
  uint32_t n = micros();
  if (n - tachLast > (uint32_t)cfg[S_RPMNOISE]) { tachLast = n; tachCnt++; }
}

static void attachTach() {
  attachInterrupt(0, isrTach, cfg[S_RPMEDGE] ? RISING : FALLING);
}

// ---------------------------------------------------------------------------
// Состояние системы
// ---------------------------------------------------------------------------
uint8_t fault = F_NONE;
uint8_t armed = 0;              // защита взведена
uint8_t armWarn = 0;            // взвелась по страховке, а не по порогу
uint8_t spinSeen = 0;           // шпиндель хоть раз показал обороты
uint32_t armT0 = 0;             // момент взвода, отсчёт задержки пуска
uint32_t spinT0 = 0;            // момент первых оборотов, отсчёт страховки
uint32_t spinBase = 0;           // обороты на момент последнего продления отсчёта
uint32_t rpmBadT0 = 0, rpmHiT0 = 0, curBadT0 = 0;
uint8_t rpmBad = 0, rpmHiBad = 0, curBad = 0;

uint32_t rpm = 0;               // обороты шпинделя
uint8_t  rpmOk = 0;             // были импульсы в последнем окне
uint32_t pps = 0;               // импульсов в секунду
uint32_t tachPrev = 0, tachT0 = 0;
uint16_t cur10 = 0;             // ток, 0.1 А
uint8_t  curOk = 0;
uint32_t curT0 = 0;

uint8_t relayOn = 0;
uint32_t relayT0 = 0;
uint8_t relayManual = 0;

uint8_t limStable = 0, limPrev = 0xFF, limForce = 0;   // маска нажатых
uint32_t limT0 = 0;
uint8_t limDir[2] = { 2, 2 };  // в какую сторону ехали, когда сработал
                                // концевик: 2 = ещё не знаем

int32_t simRpm = -1, simCur = -1;   // подмена показаний для проверок
uint8_t simBits = 0;                // что подменяем, для панели

uint32_t lastCmdMs = 0;
uint8_t  wdReset = 0;               // плату перезагрузил сторожевой таймер

// ---- опережающие объявления ----
static void axisApplyEna(uint8_t i);
static void ok();
static void err(const __FlashStringHelper *m);
static inline char upper(char c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }

// ---------------------------------------------------------------------------
// Служебное
// ---------------------------------------------------------------------------
static inline void writePin(uint8_t port, uint8_t bit, uint8_t value) {
  uint8_t s = SREG;
  cli();
  if (value) *pOut[port] |= bit; else *pOut[port] &= (uint8_t)~bit;
  SREG = s;
}

static void relayWrite(uint8_t on) {
  digitalWrite(13, cfg[S_RELAYPOL] ? on : (uint8_t)!on);   // модуль включает LOW
  relayOn = on;
}

static uint32_t isqrt(uint32_t v) {
  uint32_t r = 0, bit = 1UL << 30;
  while (bit > v) bit >>= 2;
  while (bit) {
    if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; }
    else r >>= 1;
    bit >>= 2;
  }
  return r;
}

static void axisApplyEna(uint8_t i) {
  Axis &a = axes[i];
  uint8_t v = a.enaOn ? 1 : 0;
  if (!a.enaPol) v = (uint8_t)!v;
  writePin(a.eport, a.ebit, v);
  a.enaGuard = 1;               // выдержать t1 перед первым шагом
}

// Пересчёт оси из настроек. Вызывается при старте и при изменении любой
// настройки с индексом >= A_BASE.
static void applyAxis(uint8_t i) {
  Axis &a = axes[i];
  int32_t spr = cfg[A_SPR(i)], um = cfg[A_UMREV(i)];
  if (spr < 1) spr = 1;
  if (um < 1) um = 1;
  // шагов на мм = шагов на оборот / (мкм на оборот / 1000)
  a.spm = (float)spr * 1000.0f / (float)um;
  a.dirInv = (uint8_t)cfg[A_DIRINV(i)];
  a.enaPol = (uint8_t)cfg[A_ENAPOL(i)];
  a.accel = (uint16_t)cfg[A_ACCEL(i)];
  // прирост фиксированной точки за тик, чтобы разгон не округлялся в ноль
  a.rampInc = (uint32_t)a.accel * 65536UL / TICK_HZ;
  axisApplyEna(i);
}

// Скорость оси в об/мин -> шаги/с. Вынесено отдельно от applyAxis, потому что
// сохранённая скорость не пересчитывается от шагов на оборот сама: при смене
// микрошага те же 1500 об/мин должны означать 1500, а не «столько, сколько
// вышло по старым шагам на оборот». Поэтому пересчёт идёт от числа оборотов.
static void axisApplySpeed(uint8_t i) {
  Axis &a = axes[i];
  float rpmMotor = (float)cfg[A_SPD(i)];
  float hz = rpmMotor * (float)cfg[A_SPR(i)] / 60.0f;
  if (hz > (float)MAX_HZ) hz = (float)MAX_HZ;
  a.hz = (uint16_t)(hz + 0.5f);
  if (a.running && a.rampOn) a.hzGoal = a.hz;
  else { a.hzNow = a.hz; a.rampOn = 0; }
}

static void axisStart(uint8_t i) {
  Axis &a = axes[i];
  // PUL НЕ принудительно опускаем: обрыв импульса = потерянный шаг
  a.acc = 0;
  a.running = 1;
}

// ---------------------------------------------------------------------------
// Журнал событий
//
// Плата до сих пор не сообщала наружу ни одного изменения состояния: авария и
// стоп по концевику срабатывали молча. По журналу панели прошлого прогона
// пришлось гадать, кто именно остановил ось: оставалось три возможные
// причины, и все три были в коде.
//
// Теперь каждое событие печатается строкой с '#' в начале, сервер их
// логирует. Печать только из основного цикла: из прерывания выводить нельзя,
// там нельзя ждать окончания передачи байта.
// ---------------------------------------------------------------------------
static const __FlashStringHelper *evAxis(uint8_t i) { return i ? F("Y") : F("X"); }

static const __FlashStringHelper *evFaultName(uint8_t c) {
  switch (c) {
    case F_RPMLOW:  return F("обороты ниже уставки");
    case F_RPMHIGH: return F("обороты выше уставки");
    case F_CURRENT: return F("ток выше уставки");
    case F_LIMIT:   return F("концевик");
    case F_LINK:    return F("потеря связи с панелью");
    default:        return F("код без названия");
  }
}

uint8_t goalPrev[2] = { 0, 0 };   // флаг цели снимается и при её достижении, и при
                                  // стопе, и при аварии — по нему ловим конец хода

// #АВАРИЯ <код> <имя>: <подробности>. Обе оси остановлены.
static void evFault(uint8_t code) {
  Serial.print(F("#АВАРИЯ "));
  Serial.print((uint8_t)code);
  Serial.print(' ');
  Serial.print(evFaultName(code));
  if (code == F_RPMLOW || code == F_RPMHIGH) {
    Serial.print(F(": "));
    Serial.print((long)rpm);
    Serial.print(F(" об/мин, уставка "));
    Serial.print((long)cfg[S_RPMSTOP]);
    if (code == F_RPMHIGH) {
      Serial.print(F(".."));
      Serial.print((long)cfg[S_RPMMAX]);
    }
    if (!rpmOk) Serial.print(F(", датчик молчит"));
    Serial.print(F(", держится "));
    Serial.print((uint32_t)cfg[S_RPMMS]);
    Serial.print(F(" мс"));
  } else if (code == F_CURRENT) {
    Serial.print(F(": ток "));
    Serial.print((uint16_t)(cur10 / 10));
    Serial.print('.');
    Serial.print((uint16_t)(cur10 % 10));
    Serial.print(F(" А, уставка "));
    Serial.print((uint16_t)(cfg[S_CUR10] / 10));
    Serial.print('.');
    Serial.print((uint16_t)(cfg[S_CUR10] % 10));
    Serial.print(F(" А, держится "));
    Serial.print((uint32_t)cfg[S_CURMS]);
    Serial.print(F(" мс"));
  } else if (code == F_LIMIT) {
    Serial.print(F(": нажаты"));
    if (limStable & 1) Serial.print(F(" X-1"));
    if (limStable & 2) Serial.print(F(" X-2"));
    if (limStable & 4) Serial.print(F(" Y-1"));
    if (limStable & 8) Serial.print(F(" Y-2"));
  }
  Serial.println(F(". Обе оси остановлены"));
}

// #КОНЦЕВИК X-1 НАЖАТ/ОТПУЩЕН + что стало с осью
static void evLimit(uint8_t axis, uint8_t n, uint8_t pressed, uint8_t wasRunning) {
  Serial.print(F("#КОНЦЕВИК "));
  Serial.print(evAxis(axis));
  Serial.print('-');
  Serial.print((uint8_t)n);
  Serial.print(pressed ? F(" НАЖАТ") : F(" ОТПУЩЕН"));
  if (pressed) {
    if (wasRunning) Serial.print(F(": ось ехала, стоп, отвод только в другую сторону"));
    else            Serial.print(F(": ось стояла, первый ход сам задаст сторону"));
  }
  Serial.println();
}

// Страховка в scanLimits: путь закрыт, но состояние концевика не менялось.
static void evBlock(uint8_t i) {
  Serial.print(F("#СТРАХОВКА: путь к концевику закрыт, стоп "));
  Serial.print(evAxis(i));
  Serial.println();
}

static void evMoveStart(uint8_t i, long n) {
  Axis &a = axes[i];
  uint8_t s = SREG; cli();
  long p = a.pos, t = a.target;
  SREG = s;
  Serial.print(F("#ХОД "));
  Serial.print(evAxis(i));
  Serial.print(F(" НАЧАЛО "));
  Serial.print(n);
  Serial.print(F(" шаг, с "));
  Serial.print(p);
  Serial.print(F(" на "));
  Serial.print(t);
  Serial.println();
}

static void evMoveEnd(uint8_t i) {
  Axis &a = axes[i];
  uint8_t s = SREG; cli();
  long p = a.pos, t = a.target;
  uint8_t d = a.dir;
  SREG = s;
  // К «достиг цели» отнести и перелёт на шаг: округление цели вниз даёт и
  // ровно, и на шаг дальше — оба случая это нормальное завершение хода.
  bool done = d ? (p >= t) : (p <= t);
  Serial.print(F("#ХОД "));
  Serial.print(evAxis(i));
  Serial.print(done ? F(" ОКОНЧЕН") : F(" ПРЕРВАН"));
  if (!done && fault != F_NONE) {
    Serial.print(F(", авария "));
    Serial.print((uint8_t)fault);
    Serial.print(' ');
    Serial.print(evFaultName(fault));
  }
  Serial.print(F(": цель "));
  Serial.print(t);
  Serial.print(F(", p "));
  Serial.print(p);
  Serial.println();
}

// Вызывать из основного цикла один раз: ловит момент, когда флаг цели сняли.
static void evMoveGoal(void) {
  for (uint8_t i = 0; i < 2; i++) {
    uint8_t g = axes[i].targetActive;
    if (goalPrev[i] && !g) evMoveEnd(i);
    goalPrev[i] = g;
  }
}

static void evZero(uint8_t i, long was) {
  Serial.print(F("#ОБНУЛЕНА "));
  Serial.print(evAxis(i));
  Serial.print(F(": было "));
  Serial.print(was);
  Serial.println(F(", стало 0"));
}

static void evJog(uint8_t i, uint8_t dir) {
  Serial.print(F("#ДЖОГ "));
  Serial.print(evAxis(i));
  Serial.print(dir ? F(" ВКЛ, в сторону 1") : F(" ВКЛ, в сторону 0"));
  Serial.println();
}

static void evLink(uint32_t ms) {
  Serial.print(F("#ПОТЕРЯ СВЯЗИ: "));
  Serial.print(ms);
  Serial.println(F(" мс без команд, а стол едет"));
}

static void evForce(uint8_t bit, uint8_t on) {
  Serial.print(F("#ПОДМЕНА КОНЦЕВИКА "));
  Serial.print(evAxis((uint8_t)(bit >> 1)));
  Serial.print('-');
  Serial.print((uint8_t)((bit & 1) + 1));
  Serial.println(on ? F(" = НАЖАТ") : F(" = ОТПУЩЕН"));
}

static void axisStop(uint8_t i) {
  Axis &a = axes[i];
  a.running = 0;
  a.targetActive = 0;
  a.rampOn = 0;
  a.hzNow = a.hz;               // вернуться к заданной скорости
  // a.hz не обнуляем: это "заданная скорость" для следующего пуска
  if (!cfg[S_SUSTENA] && a.enaOn) { a.enaOn = 0; axisApplyEna(i); }
}

// ---- блокировка движения в сторону нажатого концевика -----------------------
// Бит 0 ответа = нельзя в dir 0, бит 1 = нельзя в dir 1. 0 = можно в обе.
// Ось упёрлась в концевик на ходу: закрывается ровно одна сторона — та, с которой
// пришла, — и отводить можно только в другую.
static uint8_t blockDir(uint8_t i) {
  if (!(limStable & (3 << (i * 2)))) return 0;   // ни один не нажат
  if (limDir[i] > 1) return 3;                  // не знаем, куда он: закрываем всё
  return (uint8_t)(1 << limDir[i]);
}

// Концевик задели рукой, когда ось стояла: с какой стороны он, плата не знает, и
// blockDir закрывает обе стороны — отвести ось было бы нечем. Первый ход после
// такого считаем ОТВОДОМ: куда оператор ведёт, там выход, и закрываем обратную
// сторону. Звать это перед проверкой пути в командах G и N.
static void resolveLimitSide(uint8_t i) {
  if (!(limStable & (3 << (i * 2)))) return;   // ничего не нажато
  if (limDir[i] < 2) return;                   // сторона уже известна
  limDir[i] = (uint8_t)(axes[i].dir ^ 1);
}

// ---- можно ли запустить стол при висящей аварии ------------------------------
// Пуск привода при аварии запрещён: сначала сброс, потом движение. Раньше G и N
// про аварию не спрашивали вовсе, и привод запускался на любом зависшем ft.
//
// Исключение ровно одно — отвод от нажатого концевика. Сброс при нажатом
// выключателе не проходит («КОНЦЕВИК ЕЩЁ НАЖАТ»), так что единственный способ
// уйти с концевика — джогнуть прочь, а авария 4 при этом ещё висит. Запретить
// и это нельзя: ось навсегда упирается в выключатель, и перезагрузка не спасает
// (после неё авария 4 встаёт сразу, выключатель-то нажат).
//
// Отвод отличается от запуска «просто так» двумя признаками: концевик всё ещё
// нажат и путь в сторону выключателя закрыт. В сторону выключателя blockDir
// не пускает и без нас, поэтому проверить надо только второй признак.
//
// Звать ПОСЛЕ проверки blockDir в G и N: «путь к концевику закрыт» — сообщение
// точнее, чем «сбрось аварию», и тест на закрытый путь ждёт именно его.
static uint8_t startDenied(uint8_t i) {
  if (fault == F_NONE) return 0;
  if (fault == F_LIMIT && (limStable & (3 << (i * 2))))
    return (uint8_t)(blockDir(i) & (1 << axes[i].dir));
  return 1;
}

// ---- можно ли двигать стол --------------------------------------------------
static bool moveAllowed() {
  if (cfg[S_MOVENOSP]) return true;
  if (rpmOk && (int32_t)rpm > cfg[S_RESTART]) return true;
  return false;
}

static void faultSet(uint8_t code) {
  if (fault != F_NONE) return;
  fault = code;
  armed = 0;
  armWarn = 0; spinSeen = 0; spinT0 = 0; spinBase = 0;
  rpmBad = rpmHiBad = curBad = 0;
  axisStop(0); axisStop(1);
  if (cfg[S_RELAYMODE]) { relayWrite(1); relayT0 = millis(); }
  else relayWrite(0);
  evFault(code);        // до этого момента авария была полностью молчаливой
}

// ---- относительный ход с рампой -------------------------------------------
static void moveSteps(uint8_t i, long n) {
  Axis &a = axes[i];
  a.target = a.pos + (a.dir ? n : -n);
  a.targetActive = 1;
  evMoveStart(i, n);
  if (a.accel > 0) {
    a.rampOn = 1;
    a.hzFp = 0;
    a.hzNow = 0;
    // Весь профиль считаем ОДИН раз здесь, в loop. В ISR остаётся сложение и
    // сравнение: деление там - ровно то, из-за чего ось когда-то переставала
    // отвечать.
    // Темп шагов = hzNow: один шаг = один период PUL = два переключения
    // (фронт + срез), поэтому аккумулятор с порогом ACC_TOP считает ровно
    // hzNow шагов/с. Путь разгона равен пути торможения: d = v^2/(2a).
    // Тормозим, когда до цели останется d шагов (rem <= d): рампа вниз
    // точно доводит до цели. Раньше было brakeAt = tot - d - торможение
    // начиналось сразу после разгона, и до цели ось доползала на ~1 Гц.
    uint32_t acc = a.accel, v = a.hz, tot = (uint32_t)n;
    uint32_t d = (v * v) / (2UL * acc);
    if (d >= tot) {
      // Ход короче разгона: пик ограничиваем треугольным профилем n = v^2/a.
      // Эту ветку берём только при d >= tot, то есть a*tot <= v^2/2 <= 2e8,
      // поэтому переполнения 32 бит не будет.
      v = isqrt(acc * tot);
      if (v < 1) v = 1;
      d = (v * v) / (2UL * acc);
      if (d > tot) d = tot;
    }
    a.hzGoal = (uint16_t)v;
    a.brakeAt = d;
  } else {
    a.rampOn = 0;
    a.hzNow = a.hz;
  }
  axisStart(i);
}

// ---------------------------------------------------------------------------
// Измерения
// ---------------------------------------------------------------------------
static void measureRpm(uint32_t now) {
  if ((uint32_t)(now - tachT0) < RPM_WINDOW_MS) return;
  uint8_t s = SREG; cli();
  uint32_t c = tachCnt;
  SREG = s;
  uint32_t n = c - tachPrev;
  uint32_t el = now - tachT0;
  if (el == 0) return;
  tachPrev = c;
  tachT0 = now;
  uint32_t ppr = (uint32_t)(cfg[S_PPR] > 0 ? cfg[S_PPR] : 1);
  pps = n * 1000UL / el;
  rpm = n * 60000UL / el / ppr;
  rpmOk = (n > 0);
  if (simRpm >= 0) { rpm = (uint32_t)simRpm; rpmOk = 1; }
  // Тахометр снят: читать нечего, плата видит «шпиндель не крутится». Подмена
  // важнее флага — на стенде так проверяют защиту без датчика.
  else if (!(cfg[S_SENS] & SENS_TACH)) { rpm = 0; rpmOk = 0; pps = 0; }
}

static void measureCurrent(uint32_t now) {
  if ((uint32_t)(now - curT0) < CUR_PERIOD_MS) return;
  curT0 = now;
  uint16_t sum = 0;
  for (uint8_t i = 0; i < CUR_SAMPLES; i++) sum += (uint16_t)analogRead(A0);
  uint16_t adc = (uint16_t)(sum / CUR_SAMPLES);
  uint16_t mv = (uint16_t)((uint32_t)adc * 5000UL / 1023UL);
  int32_t sens = cfg[S_CURSENS] > 0 ? cfg[S_CURSENS] : 1;
  int32_t d = (int32_t)mv - cfg[S_CURZERO];
  if (d < 0) d = -d;
  cur10 = (uint16_t)(d * 10 / sens);
  // Датчик вне 0.3..4.7 В - это не ток, а обрыв или замыкание. Пока ноль не
  // откалиброван (2500 мВ из запаса), читать ток нельзя: мусор на висящем
  // пине выглядел как 15 А. Без калибровки доверяем только показаниям у
  // нуля (±0.4 В) - там ток всё равно около нуля.
  int32_t z = cfg[S_CURZERO];
  uint8_t cal = (z != 2500);
  curOk = (mv > 300 && mv < 4700) && (cal || (mv > z - 400 && mv < z + 400));
  if (simCur >= 0) { cur10 = (uint16_t)simCur; curOk = 1; }
  else if (!(cfg[S_SENS] & SENS_CUR)) curOk = 0;   // датчика нет по настройке
}

// ---------------------------------------------------------------------------
// Защита
// ---------------------------------------------------------------------------
static void checkProtection(uint32_t now) {
  if (fault != F_NONE) return;
  uint8_t type = (uint8_t)cfg[S_PROT];
  if (type == 0) { armed = 0; armWarn = 0; spinSeen = 0; spinT0 = 0; spinBase = 0; return; }

  // Взвод: ждём, пока шпиндель реально раскрутится. После этого идёт задержка
  // пуска: пусковой бросок мотора 750 Вт даёт 15-20 А, без паузы защита
  // сработала бы на пустом месте.
  if (!armed) {
    // Взвод без датчиков (настройка S_ARMNOSENS): читать обороты нечем, значит и
    // ждать нечего — взводим сразу, а задержка пуска (S_STARTMS) работает дальше
    // как обычно. Это разрешает взвод, но не отменяет сами проверки: методу
    // «Ток» достаточно датчика тока (`curOk`), а метод с оборотами без тахометра
    // честно сработает на нуле — там выход один: подключить тахометр.
    if (cfg[S_ARMNOSENS]) { armed = 1; armT0 = now; armWarn = 0; rpmBad = rpmHiBad = curBad = 0; return; }
    // Страховка взвода ловит «шпиндель крутится, но до порога не дотянул»,
    // а не «шпиндель ещё разгоняется». Отсчёт от первого импульса, без оглядки
    // на рост оборотов, срабатывал на середине разгона: стоило разгону
    // продлиться дольше S_ARMWAIT, и защита взводилась ниже порога взвода и
    // ниже «об/мин MIN». Через задержку пуска любое падение оборотов давало
    // аварию «обороты упали» на неразогнанном шпинделе — замерено на стенде:
    // страховка сработала на 80 об/мин при пороге 100 и через 2 с дала аварию
    // на 130 об/мин. Поэтому пока обороты растут, отсчёт продлевается:
    // страховка срабатывает, только когда они стоят.
    if (rpmOk && (int32_t)rpm > 0) {
      if (!spinSeen || (int32_t)rpm > (int32_t)spinBase + SPINUP_EPS) {
        spinT0 = now;
        spinBase = rpm;
      }
      spinSeen = 1;
    }
    if (rpmOk && (int32_t)rpm > cfg[S_RESTART]) {
      armed = 1; armT0 = now;
    } else if (spinSeen && cfg[S_ARMWAIT] &&
               (uint32_t)(now - spinT0) >= (uint32_t)cfg[S_ARMWAIT]) {
      // Страховка: шпиндель крутится, а до порога так и не дотянул. Молчать
      // нельзя — с завышенным порогом защита не взвелась бы никогда, и
      // оператор об этом не узнал бы. Взводим и помечаем: панель пишет
      // «порог завышен», оператор поправит уставку.
      armed = 1; armT0 = now; armWarn = 1;
    }
    rpmBad = rpmHiBad = curBad = 0;
    return;
  }
  if ((uint32_t)(now - armT0) < (uint32_t)cfg[S_STARTMS]) return;

  // --- по оборотам ---
  // type 5 — «Обороты MIN + Ток»: по оборотам только НИЖНЯЯ граница, максимум
  // не проверяется. Верхнюю границу проверяют только методы 2 и 4.
  if (type == 1 || type == 2 || type == 4 || type == 5) {
    uint8_t hi = (uint8_t)((type == 2 || type == 4) && cfg[S_RPMMAX] > 0 &&
                           (int32_t)rpm >= cfg[S_RPMMAX]);
    if (!rpmOk || (int32_t)rpm <= cfg[S_RPMSTOP]) {
      if (!rpmBad) { rpmBad = 1; rpmBadT0 = now; }
      else if ((uint32_t)(now - rpmBadT0) >= (uint32_t)cfg[S_RPMMS]) {
        faultSet(hi ? F_RPMHIGH : F_RPMLOW);
        return;
      }
    } else rpmBad = 0;

    if (hi) {
      if (!rpmHiBad) { rpmHiBad = 1; rpmHiT0 = now; }
      else if ((uint32_t)(now - rpmHiT0) >= (uint32_t)cfg[S_RPMMS]) {
        faultSet(F_RPMHIGH);
        return;
      }
    } else rpmHiBad = 0;
  } else { rpmBad = 0; rpmHiBad = 0; }

  // --- по току ---
  if (type == 3 || type == 4 || type == 5) {
    // Без датчика (обрыв или не откалиброван) ловить нечего: иначе плата
    // аварила бы по мусору на висящем пине. Панель пишет, что датчика нет.
    if (curOk && (int32_t)cur10 >= cfg[S_CUR10]) {
      if (!curBad) { curBad = 1; curBadT0 = now; }
      else if ((uint32_t)(now - curBadT0) >= (uint32_t)cfg[S_CURMS]) {
        faultSet(F_CURRENT);
        return;
      }
    } else curBad = 0;
  } else curBad = 0;
}

// ---------------------------------------------------------------------------
// Концевики
// ---------------------------------------------------------------------------
static uint8_t readLimits() {
  if (!(cfg[S_SENS] & SENS_LIM)) return 0;   // концевики не подключены
  uint8_t pd = PIND, pb = PINB;
  uint8_t m = 0;
  if (pd & _BV(3)) m |= 1;      // X-1
  if (pd & _BV(4)) m |= 2;      // X-2
  if (pb & _BV(2)) m |= 4;      // Y-1
  if (pb & _BV(4)) m |= 8;      // Y-2
  if (cfg[S_LIMITPOL] == 0) m = (uint8_t)((~m) & 0x0F);   // НЗ: нажатие = LOW
  // Принудительное нажатие (команда L) форсирует бит В НАЖАТОМ состоянии.
  // Раньше было (m & ~limForce) | (limForce & m): бит требовал и физического
  // нажатия, поэтому L 0 1 ничего не нажимал.
  if (limForce) m |= limForce;
  return m;
}

// was — маска до изменения: по ней видно, какой именно концевик оси переключился,
// иначе нажатие Y забывало бы сторону, выученную осью X.
static void limitChanged(uint8_t m, uint8_t was) {
  for (uint8_t i = 0; i < 2; i++) {
    uint8_t own = (uint8_t)((m >> (i * 2)) & 3);
    if (own == (uint8_t)((was >> (i * 2)) & 3)) continue;
    // wasRunning читаем ДО axisStop: после стопа он уже 0, и в журнале враньё
    // было бы «ось стояла» на самом деле едущей оси.
    uint8_t wasRun = axes[i].running;
    for (uint8_t k = 0; k < 2; k++) {
      uint8_t bit = (uint8_t)((own >> k) & 1);
      if (bit == (uint8_t)((((uint8_t)((was >> (i * 2)) & 3)) >> k) & 1)) continue;
      evLimit(i, (uint8_t)(k + 1), bit, wasRun);
    }
    if (!own) { limDir[i] = 2; continue; }   // отпустили: сторона снова неизвестна
    // Ось ехала и упёрлась: закрываем ровно ту сторону, с которой она пришла,
    // отводить можно будет только в другую.
    if (wasRun) limDir[i] = axes[i].dir;
    axisStop(i);
  }
  if (m) faultSet(F_LIMIT);
}

static void scanLimits(uint32_t now) {
  uint8_t m = readLimits();
  if (m != limPrev) { limPrev = m; limT0 = now; return; }
  if (m != limStable && (uint32_t)(now - limT0) >= LIMIT_DEB_MS) {
    uint8_t was = limStable;
    limStable = m;
    limitChanged(m, was);
  }
  // Страховка: оседёт ось в сторону нажатого концевика - стоп немедленно, даже
  // если состояние не изменилось (например, концевик был нажат при включении).
  for (uint8_t i = 0; i < 2; i++)
    if (axes[i].running && (blockDir(i) & (1 << axes[i].dir))) { evBlock(i); axisStop(i); }
}

// ---------------------------------------------------------------------------
// Протокол
// ---------------------------------------------------------------------------
static void ok() { Serial.println(F("OK")); }
static void okNum(long v) { Serial.print(F("OK ")); Serial.println(v); }
static void err(const __FlashStringHelper *m) { Serial.print(F("ERR ")); Serial.println(m); }

static void printAxis(uint8_t i) {
  Axis &a = axes[i];
  long p, tg;
  uint16_t h, n;
  uint8_t r, e, g;
  uint8_t s = SREG; cli();          // снимок, чтобы не показать рваное число
  p = a.pos; tg = a.target;
  h = a.hz; n = a.hzNow;
  r = a.running; e = a.enaOn; g = a.targetActive;
  SREG = s;
  Serial.print(F("{\"p\":"));   Serial.print(p);
  Serial.print(F(",\"h\":"));   Serial.print(h);
  Serial.print(F(",\"n\":"));   Serial.print(n);
  Serial.print(F(",\"r\":"));   Serial.print(r);
  Serial.print(F(",\"e\":"));   Serial.print(e);
  Serial.print(F(",\"g\":"));   Serial.print(g);
  Serial.print(F(",\"tr\":"));  Serial.print(tg);
  Serial.print(F(",\"dr\":"));  Serial.print(a.dir);
  Serial.print(F(",\"sp\":"));  Serial.print(a.spm, 2);
  Serial.print('}');
}

static void printStatus() {
  Serial.print(F("{\"fw\":\"" FW_VER "\",\"d\":")); Serial.print(cfgDefaults);
  Serial.print(F(",\"ft\":"));  Serial.print(fault);
  Serial.print(F(",\"lm\":"));  Serial.print(limStable);
  Serial.print(F(",\"rl\":"));  Serial.print(relayOn);
  Serial.print(F(",\"lk\":"));  Serial.print((uint32_t)(millis() - lastCmdMs));
  Serial.print(F(",\"lw\":"));  Serial.print(loopMaxUs);
  Serial.print(F(",\"sm\":"));  Serial.print(simBits);
  Serial.print(F(",\"sn\":"));  Serial.print(cfg[S_SENS]);
  Serial.print(F(",\"wd\":"));  Serial.print(wdReset);
  Serial.print(F(",\"ax\":["));
  printAxis(0);
  Serial.print(',');
  printAxis(1);
  Serial.print(F("],\"sd\":{\"r\":")); Serial.print(rpm);
  Serial.print(F(",\"ro\":"));  Serial.print(rpmOk);
  Serial.print(F(",\"c\":"));   Serial.print(cur10);
  Serial.print(F(",\"co\":"));  Serial.print(curOk);
  Serial.print(F(",\"ar\":"));  Serial.print(armed);
  Serial.print(F(",\"aw\":"));  Serial.print(armWarn);
  Serial.print(F(",\"awm\":")); Serial.print((int32_t)cfg[S_ARMWAIT]);
  Serial.print(F(",\"al\":"));
  if (armed) {
    uint32_t el = (uint32_t)cfg[S_STARTMS] - (uint32_t)(millis() - armT0);
    Serial.print(el > (uint32_t)cfg[S_STARTMS] ? 0 : el);
  } else Serial.print(-1);
  Serial.print(F(",\"ps\":"));  Serial.print(pps);
  // конец: "}" закрывает sd, "}" закрывает корень. Одиночная "]" раньше здесь
  // была лишней - JSON получался невалидным, и ConvertFrom-Json (PS 5.1)
  // падал на последнем символе статуса.
  Serial.print(F("}}\n"));
}

static void printSettings() {
  Serial.print(F("{\"v\":["));
  for (uint8_t i = 0; i < NSET; i++) {
    if (i) Serial.print(',');
    Serial.print(cfg[i]);
  }
  Serial.print(F("]}\n"));
}

static bool axisIndex(char c, uint8_t &idx) {
  if (c == '1') { idx = 0; return true; }
  if (c == '2') { idx = 1; return true; }
  return false;
}

static void handle(char *line) {
  char *tok[3] = { nullptr, nullptr, nullptr };
  uint8_t nt = 0;
  char *p = line;

  while (*p && nt < 3) {
    while (*p == ' ' || *p == '\t') p++;
    if (!*p) break;
    tok[nt++] = p;
    while (*p && *p != ' ' && *p != '\t') p++;
    if (*p) *p++ = 0;
  }
  if (nt == 0) return;
  for (uint8_t i = 0; i < nt; i++)
    for (char *q = tok[i]; *q; q++) *q = upper(*q);

  // Номер оси может быть слит с командой: "V1 200" = команда V, ось 1.
  // Без этого "V1"/"G1"/"H1" не совпали бы ни с одной командой.
  char axbuf[2] = { 0, 0 };
  {
    char *c0 = tok[0];
    uint8_t l0 = strlen(c0);
    if (l0 >= 2 && c0[l0 - 1] >= '1' && c0[l0 - 1] <= '9') {
      axbuf[0] = c0[l0 - 1];
      c0[l0 - 1] = 0;
      if (nt < 3) {
        for (uint8_t i = nt; i > 1; i--) tok[i] = tok[i - 1];
        nt++;
      }
      tok[1] = axbuf;
    }
  }

  const char *cmd = tok[0];
  uint8_t ax;
  Axis *a = nullptr;

  // ---- команды без номера оси ----
  if (!strcmp(cmd, "PING")) { Serial.println(F("PONG")); return; }
  if (!strcmp(cmd, "?"))    { printStatus(); return; }
  if (!strcmp(cmd, "X"))    { Serial.println(F("#СТОП ОБЕИХ ОСЕЙ: команда")); axisStop(0); axisStop(1); ok(); return; }
  if (!strcmp(cmd, "TS"))   { settingsSave(); ok(); return; }
  if (!strcmp(cmd, "TD")) {
    settingsDefaults();
    applyAxis(0); applyAxis(1);
    attachTach();
    ok(); return;
  }

  if (!strcmp(cmd, "!")) {                              // сброс аварии
    if (fault == F_LIMIT && limStable) {
      Serial.println(F("#СБРОС ОТКАЗАЛ: концевик ещё нажат"));
      err(F("КОНЦЕВИК ЕЩЁ НАЖАТ")); return;
    }
    fault = F_NONE;
    armed = 0; armWarn = 0; spinSeen = 0; spinT0 = 0; spinBase = 0;
    rpmBad = rpmHiBad = curBad = 0;
    relayManual = 0;
    relayWrite(0);
    Serial.println(F("#АВАРИЯ СБРОШЕНА"));
    ok(); return;
  }

  if (!strcmp(cmd, "K")) {                              // калибровка нуля тока
    if (simCur >= 0) { err(F("ТОК ПОДМЕНЁН")); return; }
    if (axes[0].running || axes[1].running) { err(F("ОСЬ ЗАНЯТА")); return; }
    uint32_t t0 = millis();
    uint32_t sum = 0;
    uint16_t n = 0;
    do {
      for (uint8_t i = 0; i < CUR_SAMPLES; i++) sum += (uint16_t)analogRead(A0);
      n += CUR_SAMPLES;
    } while ((uint32_t)(millis() - t0) < 400);
    uint16_t mv = (uint16_t)((uint32_t)(sum / n) * 5000UL / 1023UL);
    cfg[S_CURZERO] = mv;
    okNum(mv);                                         // панель покажет и сохранит
    return;
  }

  if (!strcmp(cmd, "C")) {                              // сброс счётчика тахометра
    uint8_t s = SREG; cli();
    tachCnt = 0; tachLast = micros(); tachPrev = 0; tachT0 = millis();
    SREG = s;
    ok(); return;
  }

  if (!strcmp(cmd, "RL")) {                             // реле руками
    if (nt < 2) { err(F("RL 0|1|-1")); return; }
    long v = strtol(tok[1], nullptr, 10);
    if (v < 0) { relayManual = 0; simBits &= ~0x08; }
    else { relayManual = 1; simBits |= 0x08; }
    relayWrite(v > 0 ? 1 : 0);
    ok(); return;
  }

  if (!strcmp(cmd, "RP")) {                             // подмена оборотов
    if (nt < 2) { err(F("RP <об/мин|-1>")); return; }
    simRpm = strtol(tok[1], nullptr, 10);
    if (simRpm < 0) { simBits &= ~0x02; rpm = 0; rpmOk = 0; }
    else simBits |= 0x02;
    ok(); return;
  }

  if (!strcmp(cmd, "CU")) {                             // подмена тока
    if (nt < 2) { err(F("CU <0.1A|-1>")); return; }
    simCur = strtol(tok[1], nullptr, 10);
    if (simCur < 0) simBits &= ~0x04; else simBits |= 0x04;
    ok(); return;
  }

  if (!strcmp(cmd, "L")) {                              // принудительный концевик
    if (nt < 3) { err(F("L <0..3> <0|1|-1>")); return; }
    long i = strtol(tok[1], nullptr, 10);
    long v = strtol(tok[2], nullptr, 10);
    if (i < 0 || i > 3) { err(F("L 0..3")); return; }
    if (v > 0) limForce = (uint8_t)(limForce | (1 << i));
    else limForce = (uint8_t)(limForce & ~(1 << i));
    evForce((uint8_t)i, (uint8_t)(v > 0));
    if (limForce) simBits |= 0x01; else simBits &= ~0x01;
    ok(); return;
  }

  if (!strcmp(cmd, "T")) {                              // настройки
    if (nt == 1) { printSettings(); return; }
    if (nt >= 3) {
      long i = strtol(tok[1], nullptr, 10);
      long v = strtol(tok[2], nullptr, 10);
      // Верхний индекс берём из NSET: строка с зашитым «31» устарела, когда
      // добавились пресеты, и врала оператору о границе.
      if (i < 0 || i >= NSET) {
        Serial.print(F("ERR T 0..")); Serial.println((int8_t)(NSET - 1));
        return;
      }
      int32_t lo = (int32_t)pgm_read_dword(&RLO[i]);
      int32_t hi = (int32_t)pgm_read_dword(&RHI[i]);
      if (v < lo) v = lo;
      if (v > hi) v = hi;
      cfg[i] = v;
      cfgDefaults = 0;
      // S_SENS лежит после настроек осей, но к осям не относится: applyAxis(2)
      // писал бы за пределы массива осей. Пересчитывать тут нечего - датчики
      // читаются по флагу на каждом замере.
      if (i >= A_BASE && i < S_SENS) applyAxis((uint8_t)((i - A_BASE) / 5));
      else if (i == S_RPMEDGE) attachTach();
      // Скорости осей лежат после S_SENS и на 5 делятся не так: по одной на
      // ось. Без этой ветки «Сохранить» записал бы новые об/мин, а ползунок
      // остался бы на старом — сохранилось бы не то, что показано.
      else if (i == S_SPD0 || i == S_SPD1)
        axisApplySpeed((uint8_t)(i - S_SPD0));
      ok(); return;
    }
    err(F("T | T <i> <знач> | TS | TD")); return;
  }

  if (!strcmp(cmd, "W") || !strcmp(cmd, "W0")) {        // диагностика времени
    // Сброс по "W 0" или "W0": раньше строка "W0" без пробела сюда не
    // доходила и попадала в "НЕТ ОСИ", поэтому счётчики не обнулялись.
    if ((nt >= 2 && tok[1][0] == '0') || !strcmp(cmd, "W0")) {
      uint8_t s = SREG; cli();
      dbgN = 0; dbgIsr = 0; dbgLoops = 0; dbgT0 = millis(); loopMaxUs = 0;
      isrGapMaxUs = 0;
      SREG = s;
      ok(); return;
    }
    uint8_t s = SREG; cli();
    uint32_t isr = dbgIsr, lp = dbgLoops, t0 = dbgT0;
    SREG = s;
    uint32_t dtms = millis() - t0;
    Serial.print(F("{\"ms\":")); Serial.print(dtms);
    Serial.print(F(",\"isr_hz\":"));
    if (dtms) Serial.print((uint32_t)((uint64_t)isr * 1000UL / dtms)); else Serial.print(0);
    // lost > 0 = ISR не уложился в 25 мкс. Это тот самый признак, при котором
    // плата перестаёт отвечать. Знак: -N = насчитали больше номинала
    // (погрешность привязки millis к реальному времени), это не потеря.
    Serial.print(F(",\"lost\":"));
    if (dtms) {
      long l = (long)((uint64_t)TICK_HZ * dtms / 1000UL) - (long)isr;
      Serial.print(l);
    } else Serial.print(0);
    Serial.print(F(",\"loop_hz\":"));
    if (dtms) Serial.print((uint32_t)((uint64_t)lp * 1000UL / dtms)); else Serial.print(0);
    Serial.print(F(",\"loop_max_us\":")); Serial.print(loopMaxUs);
    Serial.print(F(",\"isr_gap_us\":")); Serial.print(isrGapMaxUs);
    Serial.print(F("}\n"));
    return;
  }

  // ---- команды с номером оси ----
  if (nt < 2 || !axisIndex(tok[1][0], ax)) { err(F("НЕТ ОСИ")); return; }
  a = &axes[ax];

  if (!strcmp(cmd, "V") && nt >= 3) {
    long hz = strtol(tok[2], nullptr, 10);
    if (hz < 0) hz = 0;
    if (hz > (long)MAX_HZ) hz = MAX_HZ;
    a->hz = (uint16_t)hz;
    if (a->running && a->rampOn) a->hzGoal = a->hz;   // едем: меняем цель, разгон не рвём
    else { a->hzNow = a->hz; a->rampOn = 0; }          // стоим: применяем сразу
    ok(); return;
  }
  if (!strcmp(cmd, "R") && nt >= 3) {
    float rpmMotor = atof(tok[2]);
    if (rpmMotor < 0) rpmMotor = 0;
    float hz = rpmMotor * (float)cfg[A_SPR(ax)] / 60.0f;
    if (hz > (float)MAX_HZ) hz = (float)MAX_HZ;
    a->hz = (uint16_t)(hz + 0.5f);
    if (a->running && a->rampOn) a->hzGoal = a->hz;
    else { a->hzNow = a->hz; a->rampOn = 0; }
    ok(); return;
  }
  if (!strcmp(cmd, "D") && nt >= 3) {
    if (a->running) { err(F("СНАЧАЛА СТОП")); return; }
    uint8_t v = (tok[2][0] == '0') ? 0 : 1;
    if (a->dirInv) v = (uint8_t)!v;
    a->dir = v;
    writePin(a->dport, a->dbit, v);
    ok(); return;
  }
  if (!strcmp(cmd, "G")) {
    resolveLimitSide(ax);
    if (blockDir(ax) & (1 << a->dir)) { err(F("ПУТЬ К КОНЦЕВИКУ ЗАКРЫТ")); return; }
    if (startDenied(ax)) { err(F("СБРОСЬ АВАРИЮ")); return; }
    if (!moveAllowed()) { err(F("ШПИНДЕЛЬ НЕ ВРАЩАЕТСЯ")); return; }
    if (a->hz == 0) { err(F("СКОРОСТЬ НЕ ЗАДАНА")); return; }   // иначе ползём 1 шаг/с
    if (!a->running) {
      // Непрерывное вращение разгоняем рампой, ровно как ход на число шагов.
      // Раньше разгона здесь не было и скорость применялась рывком: на
      // 1000+ об/мин мотор вставал и гудел на месте, а плата исправно слала
      // шаги, и по счётчику это не было видно ничем.
      // hzFp = 0: стартуем от нуля, а не от a->hzNow - в axisStop() hzNow
      // возвращается к заданной скорости, и рампы не было бы вовсе.
      a->rampOn = 1;
      a->hzFp = 0;
      a->hzGoal = a->hz;
      a->rampInc = (uint32_t)a->accel * 65536UL / TICK_HZ;
      axisStart(ax);
      evJog(ax, a->dir);
    }
    ok(); return;
  }
  if (!strcmp(cmd, "S")) {
    Serial.print(F("#СТОП ")); Serial.print(evAxis(ax)); Serial.println(F(": команда"));
    axisStop(ax); ok(); return;
  }
  if (!strcmp(cmd, "Z")) {
    // Обнуление счётчика в точке, которую выбрал оператор. Дома на станке нет,
    // и это единственный способ сказать «здесь ноль»: подводим привод джогом
    // в нужную точку, жмём «обнулить» — и ход, заданный кнопкой «выполнить»,
    // считается отсюда. Значение, которое видит оператор, это ровно pos: и
    // «N шаг» в заголовке, и миллиметры по центру карточки.
    // На ходу запрещено: цель хода задана шагами от pos, и обнуление посреди
    // хода сдвинуло бы цель на всю пройденную длину — ось уехала бы мимо.
    if (a->running) { err(F("СНАЧАЛА СТОП")); return; }
    long was = a->pos;
    a->pos = 0;
    a->target = 0;
    evZero(ax, was);
    ok(); return;
  }
  if (!strcmp(cmd, "A") && nt >= 3) {
    a->enaOn = (tok[2][0] == '0') ? 0 : 1;
    axisApplyEna(ax);
    ok(); return;
  }
  if (!strcmp(cmd, "N") && nt >= 3) {
    if (a->running) { err(F("СНАЧАЛА СТОП")); return; }
    long n = strtol(tok[2], nullptr, 10);
    // Направление задаёт ЗНАК, а не переключение. Раньше минус переворачивал
    // a->dir, из-за чего два хода подряд со знаком «минус» уезжали в одну
    // сторону, а «плюс» всегда в другую — выбрать сторону было нельзя.
    // Инверсию направления применяем, как в команде D: ход её раньше
    // игнорировал, и после переворота разъёма ход ехал не туда, куда джог.
    uint8_t d = (n < 0) ? 1 : 0;
    if (a->dirInv) d = (uint8_t)!d;
    a->dir = d;
    writePin(a->dport, a->dbit, d);
    if (n < 0) n = -n;
    if (n == 0) { err(F("N = 0")); return; }
    resolveLimitSide(ax);
    if (blockDir(ax) & (1 << a->dir)) { err(F("ПУТЬ К КОНЦЕВИКУ ЗАКРЫТ")); return; }
    if (startDenied(ax)) { err(F("СБРОСЬ АВАРИЮ")); return; }
    if (!moveAllowed()) { err(F("ШПИНДЕЛЬ НЕ ВРАЩАЕТСЯ")); return; }
    if (a->hz == 0) { err(F("СКОРОСТЬ НЕ ЗАДАНА")); return; }   // иначе ползём 1 шаг/с
    moveSteps(ax, n);
    ok(); return;
  }

  err(F("НЕИЗВЕСТНАЯ КОМАНДА"));
}

// ---------------------------------------------------------------------------
void setup() {
  uint8_t s = SREG; cli();
  wdReset = (MCUSR & _BV(WDRF)) ? 1 : 0;
  MCUSR = 0;
  SREG = s;
  wdt_enable(WDTO_2S);

  // Выходы: D5, D6, D7, D8, D9, D11, D13. Входы D2, D3, D4, D10, D12 - с
  // ВНУТРЕННЕЙ подтяжкой на +5 В: выключатель замыкает пин на GND, резистор на
  // монтаже не нужен. Поэтому полярность концевиков - "нажатие гасит (LOW)".
  // D0/D1 не трогаем.
  DDRB = (uint8_t)(0xFF & ~(_BV(2) | _BV(4)));      // PB2 = D10, PB4 = D12
  PORTB = 0;
  DDRD = (uint8_t)(0xFF & ~(_BV(0) | _BV(1) | _BV(2) | _BV(3) | _BV(4)));
  PORTD = 0;

  pinMode(A0, INPUT);
  pinMode(2, INPUT_PULLUP);
  pinMode(3, INPUT_PULLUP);
  pinMode(4, INPUT_PULLUP);
  pinMode(10, INPUT_PULLUP);
  pinMode(12, INPUT_PULLUP);
  pinMode(13, OUTPUT);
  relayWrite(0);

  settingsLoad();
  for (uint8_t i = 0; i < 2; i++) {
    axes[i].hz = 0;
    axes[i].hzNow = 0;
    axes[i].acc = 0;
    axes[i].enaOn = 1;
    applyAxis(i);
    // Скорость, которую оператор оставил в прошлый раз. Без этого строки
    // ползунка вставали в ноль при каждом включении, и движение ползлось
    // 1 шаг/с — выглядит как заедание привода, а на деле пустая скорость.
    axisApplySpeed(i);
  }

  // Timer1: CTC, clk/8, OCR1A = 49 -> 40 кГц (тик 25 мкс)
  TCCR1A = 0;
  TCCR1B = (1 << WGM12) | (1 << CS11);
  OCR1A = 49;
  TIMSK1 |= (1 << OCIE1A);

  attachTach();

  tachT0 = millis();
  curT0 = millis();
  lastCmdMs = millis();

  Serial.begin(115200);
  Serial.print(F("\n! JMD-2L CNC " FW_VER " ready"));
  if (wdReset) Serial.print(F(" (сброс сторожевым)"));
  Serial.println();
}

void loop() {
  static char line[96];
  static uint8_t len = 0;
  static uint32_t prevStart = 0;
  static uint8_t firstRun = 1;
  uint32_t tStart = micros();

  // Худший период основного цикла = задержка реакции на концевик.
  // Первую итерацию пропускаем: prevStart обнулён, а micros() считает от
  // включения питания, и туда попадает всё время setup().
  if (firstRun) { firstRun = 0; prevStart = tStart; }
  else {
    uint32_t d = tStart - prevStart;
    if (d > loopMaxUs) loopMaxUs = d;
    prevStart = tStart;
  }

  wdt_reset();                     // цикл жив, сторож не должен срабатывать
  dbgLoops++;
  // Забираем счётчик под cli: иначе прерывание, попавшее между чтением и
  // обнулением, теряется, и мы насчитываем недоказанные "потери тиков".
  { uint8_t s = SREG; cli();
    uint16_t n = dbgN; dbgN = 0;
    if (n) dbgIsr += n;
    SREG = s; }

  // Максимальная пауза между входными сигналами ISR, время основного цикла.
  // Показывает, замирал ли таймер (тики пропадали кучно), в отличие от
  // loopMaxUs, который ловит застревания самого цикла.
  { static uint32_t lastIsr = 0, lastIsrUs = 0;
    uint32_t isrNow = dbgIsr;
    if (isrNow != lastIsr) { lastIsr = isrNow; lastIsrUs = tStart; }
    else {
      uint32_t g = tStart - lastIsrUs;
      if (g > isrGapMaxUs && lastIsrUs != 0) isrGapMaxUs = g;
    } }

  uint32_t now = millis();

  // ---- потеря связи с панелью: команд нет, а стол едет ----
  // Проверяем ДО разбора команд: иначе свежий опрос статуса успевает продлить
  // связь, и пропавший ПК никогда не будет замечен.
  if (cfg[S_LINKTO] > 0 && fault == F_NONE &&
      (axes[0].running || axes[1].running) &&
      (uint32_t)(now - lastCmdMs) > (uint32_t)cfg[S_LINKTO]) {
    evLink((uint32_t)(now - lastCmdMs));
    faultSet(F_LINK);
  }

  // ---- команды ----
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (len > 0) {
        line[len] = 0;
        lastCmdMs = millis();
        handle(line);
        len = 0;
      }
    } else if (len < sizeof(line) - 1) {
      line[len++] = c;
    }
  }

  measureRpm(now);
  measureCurrent(now);
  scanLimits(now);
  checkProtection(now);
  // После них, а не между: к этому моменту и стоп по концевику, и авария уже
  // напечатаны, поэтому «ход прерван» идёт с готовым названием причины.
  evMoveGoal();

  // ---- реле: отпускаем импульс по окончании времени ----
  if (relayOn && !relayManual && cfg[S_RELAYMODE] == 1 &&
      (uint32_t)(millis() - relayT0) >= (uint32_t)cfg[S_RELAYPULSE]) {
    relayWrite(0);
  }
}
