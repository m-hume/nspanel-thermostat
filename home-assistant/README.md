# Home Assistant integration

This is the setup we actually run. It gives you a full climate card per panel with two-way
sync — while the thermostat logic stays on the panel.

## The pattern

`generic_thermostat` is used as a **UI/state proxy only**. Its `heater` switch is a
read-only MQTT switch whose `command_topic` is a single space — a dead topic. HA can call
`turn_on`/`turn_off` on it all day; nothing is published, so HA's internal control loop
cannot switch anything. Meanwhile its `hvac_action` still reflects the real relay because
the switch's `state_topic` is the panel's actual `POWER1` status.

The link is completed by four small automations per panel:

```
HA → panel:   climate.<x> hvac_action  → cmnd/<panel>/ATCEnable
              climate.<x> temperature  → cmnd/<panel>/ATCExpect
panel → HA:   tele/<panel>/RESULT {NSPanel.ATCEnable}  → climate.turn_on/off
              tele/<panel>/RESULT {NSPanel.ATCExpect0} → climate.set_temperature
```

…plus one startup automation that publishes `GetTele` to every panel on HA boot so states
resync after a restart.

Topics below use `tas_nspanel_room` / `tas_remote` as placeholders — substitute your own.

## configuration.yaml

```yaml
switch:
  # Read-only view of the panel's relay. command_topic " " is a dead end:
  # HA's generic_thermostat can try to switch it, nothing is published.
  - platform: mqtt
    name: "Room Heating"
    state_topic: "stat/tas_nspanel_room/POWER1"
    command_topic: " "
    availability_topic: "tele/tas_nspanel_room/LWT"
    payload_on: "ON"
    payload_off: "OFF"
    payload_available: "Online"
    payload_not_available: "Offline"

climate:
  - platform: generic_thermostat
    name: Room
    heater: switch.room_heating          # the dead-end switch above
    target_sensor: sensor.room_temperature
    min_temp: 16
    max_temp: 25
    precision: 0.1
```

## sensors.yaml

```yaml
# Local variant — NTC in the panel
- platform: mqtt
  state_topic: "tele/tas_nspanel_room/SENSOR"
  name: "room_temperature"
  unit_of_measurement: "C"
  value_template: "{{ value_json['ANALOG'].Temperature1 | is_defined }}"

# Local variant on a panel using a wired DS18B20 instead
#   value_template: "{{ value_json.DS18B20.Temperature | is_defined }}"

# Remote variant — temperature comes from the remote sensor device
#   state_topic: "tele/tas_remote/SENSOR"
#   value_template: "{{ value_json.DS18B20.Temperature | is_defined }}"
```

## automations.yaml

```yaml
#### HA -> panel ####

- alias: "Room set nspanel ATCEnable"
  trigger:
    - platform: state
      entity_id: climate.room
      attribute: hvac_action
  action:
    - service: mqtt.publish
      data:
        topic: "cmnd/tas_nspanel_room/ATCEnable"
        payload: "{{ state_attr('climate.room', 'hvac_action') != 'off' }}"

- alias: "Room set nspanel ATCExpect"
  trigger:
    - platform: state
      entity_id: climate.room
      attribute: temperature
  action:
    - service: mqtt.publish
      data:
        topic: "cmnd/tas_nspanel_room/ATCExpect"
        payload: "{{ state_attr('climate.room', 'temperature') }}"

#### panel -> HA ####

- alias: "Room get nspanel ATCEnable on"
  trigger:
    - platform: mqtt
      topic: "tele/tas_nspanel_room/RESULT"
      payload: "1"
      value_template: "{{ value_json.NSPanel.ATCEnable | is_defined }}"
  action:
    - service: climate.turn_on
      entity_id: climate.room

- alias: "Room get nspanel ATCEnable off"
  trigger:
    - platform: mqtt
      topic: "tele/tas_nspanel_room/RESULT"
      payload: "0"
      value_template: "{{ value_json.NSPanel.ATCEnable | is_defined }}"
  action:
    - service: climate.turn_off
      entity_id: climate.room

- alias: "Room get nspanel ATCExpect"
  trigger:
    - platform: mqtt
      topic: "tele/tas_nspanel_room/RESULT"
      payload: "True"
      value_template: "{{ (value_json.NSPanel.ATCExpect0 | is_defined) > 0 }}"
  action:
    service: climate.set_temperature
    entity_id: climate.room
    data:
      temperature: "{{ trigger.payload_json.NSPanel.ATCExpect0 }}"

#### resync after HA restart ####

- alias: "Get initial telemetry for the thermostats"
  trigger:
    platform: homeassistant
    event: start
  action:
    - service: mqtt.publish
      data:
        topic: "cmnd/tas_nspanel_room/GetTele"
```

## Notes

- The remote variant's heater view uses `stat/tas_remote/POWER` as `state_topic` — that is
  the *last commanded* state, not measured heater operation. Fine for the card; don't build
  safety logic on it.
- Duplicating the automation block per panel is verbose but keeps each thermostat
  independent. If you run many panels, convert them to a blueprint.
- The panel's own touchscreen thermostat page writes the same `ATCEnable`/`ATCExpect0`
  values — the `panel → HA` automations are what keep the climate card in sync when someone
  uses the wall panel directly.
