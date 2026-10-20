# Design notes

Condensed rationale for the non-obvious decisions in this driver. All of it was learned the
hard way on live panels controlling real heaters.

## Control belongs on the panel

The Berry script owns the control loop end to end: sensor → hysteresis → relay. Home
Assistant, MQTT, and the touchscreen are all just ways to *adjust* it. Every safety
mechanism below exists because a wall panel controlling a heater cannot afford to depend
on anything it doesn't run itself.

## The stale-sensor watchdog

`lasttemp_at` is seeded with `tasmota.millis()` at boot and refreshed on every valid
reading. If it ages past ~10 min (`2 × idle TelePeriod`), the heater is forced off.

Two subtleties:

- **Seeded at boot, not at first reading** — otherwise a panel that boots with the heater
  already on (PowerOnState restore, or a remote heater that was simply left running) and a
  dead sensor would run heat unsupervised forever.
- **Re-armed after firing** — the watchdog re-checks every 10 min rather than every minute.
  On the remote variant each firing is also a re-transmit of OFF across the lossy link.

## Bogus boot readings

Some panels emit `Temperature1: 0.0` for a second or two after reset before the ADC
stabilises. On the local variant `0.0` is treated as "no valid reading": the heat fails
toward off rather than toward frost-protect-on. This produces a brief relay toggle pair at
boot if the relay was restored ON — safe-direction chatter, accepted deliberately.

The remote variant does **not** have this guard: `0.0 °C` is a real outdoor temperature on
a shed in winter, so it uses `-255` as its no-data sentinel instead.

## Remote variant: fire-and-forget is a feature

The remote relay forwards POWER over an unreliable 2.4 GHz link to a heater that gives no
feedback. So:

- The POWER command is republished on **every** thermostat evaluation — the steady-state
  publish rate is the retry mechanism, not a bug.
- `heaterstate` tracks only the last *commanded* state. It exists to detect transitions
  (so remote/local TelePeriod can switch between 60 s heating / 300 s idle), never to
  confirm the heater is actually running.
- The watchdog forcing OFF periodically means a dead sensor eventually wins even if
  individual packets are dropped.

## Wide deadband for the diesel heater

Frost 1.0 °C, hysteresis ±1.0 °C, plus a 1.0 °C overshoot (`heat_over_temp`) before
switching off. A diesel heater has no thermal capacity: the room starts cooling the moment
it stops, and short-cycling it is both noisy and hard on the hardware. The local variant
keeps a conventional ±0.2 °C around the setpoint.

## Flash is a consumable

`persist.*` writes are debounced (5 s) because the screen's thermostat page and MQTT
commands can arrive in bursts. The driver normalises persisted types at boot
(`int()`/`number()`) — a string `"0"` persisted by an older version compares false against
numeric `0` otherwise.

## Serial framing

The NSPanel wire format is `55 AA | type | len(LE16) | payload | CRC16/MODBUS(LE)`, with a
stray `00` pad byte appended after some frames. The original upstream code split on `55 AA`
and scanned backwards for `}` — which breaks when the magic pair or a `0x7D` byte occurs
inside payload or CRC data, and when a frame spans two serial reads. This driver buffers
raw bytes and parses by the length field with CRC validation; incomplete frames wait for
the next read, bad frames resync without discarding the rest of the buffer.

## Weather

Open-Meteo is the primary provider (HTTPS, no API key, stable), wttr.in the fallback —
wttr still wins for place-name locations since Open-Meteo needs `lat,long`. `sync_weather`
always leaves exactly one timer armed: short retry (60 s, max 3×) on failure, otherwise
the normal interval. An earlier version armed a timer per failure, which permanently
multiplied the sync rate after any outage.
