# NSPanel Thermostat

A thermostat driver for the Sonoff NSPanel running Tasmota (Berry), built on top of
[blakadder's NSPanel driver](https://github.com/blakadder/nspanel) (`nspanel.be`).

The thermostat control loop runs **on the panel itself** — not in Home Assistant. The panel
reads a temperature sensor, applies hysteresis, drives the relay, protects against frost and
against a dead sensor, and keeps doing all of that if your Wi-Fi, MQTT broker, or Home
Assistant goes away. Home Assistant is a display and supervisory layer, not the controller.

## Variants

| File | Architecture | Use when |
|---|---|---|
| `autoexec_local.be` | Local sensor (`ANALOG#Temperature1` NTC, or any `Tele#` source) → local `POWER1` relay | The panel is in the room being heated and directly wired to the load |
| `autoexec_remote.be` | Remote sensor via `tele/<remote>/SENSOR` → remote relay via `cmnd/<remote>/POWER` | The panel shouldn't sense or switch locally — e.g. our shed: an NSPanel by the door, a DS18B20 deeper in the building, and a diesel heater behind a separate Tasmota relay that forwards POWER over a 2.4 GHz RF link |

Key differences in the remote variant:

- **Wider deadband** — frost 1.0 °C, hysteresis ±1.0 °C, 1.0 °C overshoot: a diesel heater
  has no thermal capacity and must not short-cycle
- **Deliberate command republish** — the remote relay has *no state feedback* (fire-and-forget
  over a lossy RF link), so the POWER command is republished on every evaluation as a retry
  mechanism
- **`0.0 °C` is a legitimate reading** — no boot-zero guard; `-255` is the no-data sentinel

## Features

- On-device hysteresis control loop (heat below `setpoint − 0.2`, off at setpoint)
- Frost protection when the thermostat is disabled (10 °C, local variant)
- Stale-sensor watchdog: heater forced off ~10 min after the last valid reading — armed
  from boot even if the sensor never reports
- Boot-artifact guard: the `0.0` reading some panels emit before the ADC stabilises is not
  treated as real frost (local variant)
- Setpoint + enable persisted in flash, debounced so slider bursts don't wear the flash
- Robust NSPanel serial framing: length-field parser, CRC-16/MODBUS validation, reassembly
  buffer for split frames — fixes several upstream parsing bugs
- Weather on screen via Open-Meteo (free, no key) with wttr.in fallback

## Install

1. Flash the panel with a `tasmota32-nspanel` build (any recent-ish version; developed and
   verified on 12.1.1/12.2.0).
2. Pick your variant and rename it to `autoexec.be`.
3. Upload via **Consoles → Manage File system** in the Tasmota web UI.
4. `Restart 1` — uploading does not reload the script.

## Configuration

| Console command | Effect |
|---|---|
| `ATCEnable 1` / `0` / `toggle` / *(bare)* | Enable/disable/query the thermostat |
| `ATCExpect 21` / *(bare)* | Set/query the target temperature |
| `SetThermostatId DS18B20#Temperature` | Choose which `Tele#` sensor feeds the loop (default `ANALOG#Temperature1`); persists + reboots |
| `GetTele` | Dump current thermostat state to RESULT |
| `NSPDim`, `NSPLocation`, `NSPMode`, `NSPSend`, `NSPWInterval` | Upstream driver commands (dim, weather location, screen mode, raw send, weather interval) |

The widget table near the top of each file maps the 8 home-screen slots — edit names/types
to taste. In the remote variant, change `tas_shedtemp` to your remote device's MQTT topic.

## Home Assistant integration

### Why not `generic_thermostat` / a climate integration that runs the loop?

Home Assistant's `generic_thermostat` — and most climate integrations — put the control loop
in HA. That's fine until it isn't: an HA restart, a VM migration, a broker hiccup, or a
Zigbee sensor that stops reporting at unpredictable intervals leaves your heating either
stuck on or stuck off, in a building you may not be watching.

The NSPanel is already a wall-mounted device with a processor, a temperature input path, and
a relay. Letting it own the loop means:

- **Heating keeps working with HA down** — setpoint, hysteresis, frost protect, and the
  stale-sensor watchdog all run on the panel
- **Sensor cadence you control** — `TelePeriod` (60 s while heating, 300 s idle) is
  deterministic, unlike battery Zigbee sensors whose report intervals vary
- **Fail-safe is local** — the watchdog doesn't depend on a round trip through the network

HA's job becomes: show the temperature, expose the setpoint and enable switch, and let
schedules/automations *request* temperatures — the panel still executes safely on its own.

### The setup we actually use

Full working config — a `generic_thermostat` climate card bridged to the panel by four
automations — is in **[`home-assistant/`](home-assistant/README.md)**. The short version:

- `generic_thermostat`'s `heater` is a read-only MQTT switch with `command_topic: " "` —
  a dead end. HA's internal switching loop can fire all it wants; nothing is published.
  The panel does the real switching, and `hvac_action` still reflects the true relay state
  via `stat/.../POWER1`.
- Automations push `climate` changes → `ATCEnable`/`ATCExpect` commands, and feed the
  panel's `{NSPanel.ATCEnable/ATCExpect0}` RESULT publishes → `climate.turn_on/off` /
  `climate.set_temperature`, so the card stays in sync when someone uses the wall panel.
- A `GetTele` publish on HA start resyncs state after restarts.

### Things to know

- `stat/.../POWER` on the remote variant is the **last commanded** state, not measured
  heater operation — display it, but don't build safety logic on it
- The panel's own thermostat page and the HA climate card write the same persisted
  values — they coexist cleanly through the RESULT publishes
- If you *want* HA schedules, automate `ATCExpect`/`ATCEnable` publishes rather than
  touching the relay directly — that keeps the safety logic in the loop

## Acknowledgements

- [blakadder](https://github.com/blakadder/nspanel) and s-hadinger for the NSPanel protocol
  reverse-engineering and the original Berry driver this extends
- The generic driver fixes in this repo were also submitted upstream
  ([blakadder/nspanel#74](https://github.com/blakadder/nspanel/pull/74))
