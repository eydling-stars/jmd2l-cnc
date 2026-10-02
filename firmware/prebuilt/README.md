# Готовая прошивка

`jmd2l_cnc.ino.hex` — собрана из `jmd2l_cnc.ino` в этом же репозитории.
Прошить можно без Arduino IDE, без компилятора и без интернета:

```
powershell -ExecutionPolicy Bypass -File bench\flash.ps1 -Port COM4 -SkipBuild -BuildPath firmware\prebuilt
```

Признак успеха — строка `N bytes of flash verified`. Код возврата `avrdude`
бывает равен 1 даже при удачной заливке.

Править содержимое этой папки не нужно: при каждой публикации `make-public.ps1`
собирает `.hex` из текущего исходника, так что рассинхрона с `jmd2l_cnc.ino`
не будет.

- SHA256: `38794ddfb1cf88f902a895d9a276c96c025d3148576e59469e9c793ee0b8f8a5`
- Плата: Arduino Nano, **ATmega328P (Old Bootloader)**
- Частота платы: 16 МГц