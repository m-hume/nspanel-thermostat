# Sonoff NSPanel Tasmota driver v0.47 | code by blakadder and s-hadinger
var mode = "NSPanel"
import persist
var devicename = tasmota.cmd("DeviceName")["DeviceName"]
persist.tempunit = tasmota.get_option(8) == 1 ? "F" : "C"
if persist.has("dim")  else   persist.dim = "1"  end
if persist.has("atcenable")  else   persist.atcenable = 0  end
persist.atcenable = int(persist.atcenable)   # heal legacy string "0"/"1"
if persist.has("atcexpect0")  else   persist.atcexpect0 = 18  end
var loc = str(tasmota.cmd("Latitude")["Latitude"]) + ',' + str(tasmota.cmd("Longitude")["Longitude"])
loc = persist.has("loc") ? persist.loc : loc
var lasttemp = -255   # -255 = no valid reading yet (0.0 C is a legitimate temp here)
var lasttemp_at = tasmota.millis()   # millis() of last valid reading; seeded at boot so the watchdog is armed even if the sensor never reports
var heaterstate = ""   # last COMMANDED state (stat/tas_shedtemp/POWER) — heater itself gives no feedback
var weather_retries = 0   # consecutive weather sync failures (retry budget)
var thermostat_id = persist.has("t_id") ? persist.t_id : "ANALOG#Temperature1"
# TelePeriod when heating On and Off
var teleperiods = [60, 300]
# diesel heater: wide deadband to avoid short-cycling (no thermal capacity)
var frost_protect_temp = 1.0
var hysteresis_temp = 1.0
var heat_over_temp = 1.0
persist.save() # save persist file until serial bug fixed

  var widget = {
# 1 = toggle switch horizontal
# 2 = toggle switch double horizontal
# 3 = toggle switch triple horizontal
# 4 = toggle switch quad horizontal
# 6 = toggle switch vertical
# 7 = toggle switch double vertical
# 8 = toggle switch triple vertical
# 9 = toggle switch quad vertical
# 33 = RGB light strip
# 52 = CCT bulb
# 69 = RGB+CCT bulb
# leave empty brackets if you don't want a widget there
# ctype scene doesn't have an uiid
# index "name   ", "ctype", uiid | name max 8 characters, rest will be truncated)
  1: ["Day", "scene"],
  2: ["Eve", "scene"],
  3: ["Late", "scene"],
  4: [],
  5: [],
  6: [],
  7: [],
  8: [],
}

class NSPanel : Driver
  # set thermostat options
  static atc = {
    "id":     "thermostat",
    "outlet": "0",  # outlet to use for trigger
    "etype":  "hot", # hot or cold
    "mirror":  true, # if true Tasmota will resend triggers as commands to keep the state on screen
  }

  static types = {
    '"switches":[{"outlet":':     0x87,
    "relation":   0x86,
    "ATC":      0x84,
    "index":    0x86,
    "params":     0x86,
    "wifiState":  0x85,
    "HMI_resources":0x86,
    "temp":     0x83,
    "year":     0x82,
    "weather":    0x81,
    "queryInfo":  0x80,
    "HMI_dimOpen":  0x87,
  }
  static header = bytes('55AA')

  var ser    # create serial port object
  var rxbuf  # serial reassembly buffer (frames may span multiple reads)

  # intialize the serial port, if unspecified Tx/Rx are GPIO 16/17
  def init(tx, rx)
    if !tx   tx = 16 end
    if !rx   rx = 17 end
    self.ser = serial(rx, tx, 115200, serial.SERIAL_8N1)
    self.rxbuf = bytes()
    tasmota.add_driver(self)
  end

  # determine type of message
  def findtype(value)
    import string
    for k:self.types.keys()
      if string.find(value, k) >= 0
        return self.types[k]
      end
    end
    return 0
  end

  def crc16(data, poly)
    if !poly  poly = 0xA001 end
    # CRC-16 MODBUS HASHING ALGORITHM
    var crc = 0xFFFF
    for i:0..size(data)-1
      crc = crc ^ data[i]
      for j:0..7
        if crc & 1
          crc = (crc >> 1) ^ poly
        else
          crc = crc >> 1
        end
      end
    end
    return crc
  end

  # encode using NSPanel protocol
  # input: payload:json string
  def encode(payload)
    var b = bytes()
    var nsp_type = self.findtype(payload)
    b += self.header
    b.add(nsp_type)       # add a single byte
    b.add(size(payload), 2)   # add size as 2 bytes, little endian
    b += bytes().fromstring(payload)
    var msg_crc = self.crc16(b)
    b.add(msg_crc, 2)       # crc 2 bytes, little endian
    return b
  end

  # send a string payload (needs to be a valid json string)
  def send(payload)
    print("NSP: Sent =", payload)
    var payload_bin = self.encode(payload)
    self.ser.write(payload_bin)
    # print("NSP: Sent =", payload)
    log("NSP: NSPanel payload sent = " + str(payload_bin), 3)
  end

  # send a nextion payload
  def encodenx(payload)
    var b = bytes().fromstring(payload)
    b += bytes('FFFFFF')
    return b
  end

  def sendnx(payload)
    var payload_bin = self.encodenx(payload)
    self.ser.write(payload_bin)
    # print("NSP: Sent =", payload_bin)
    log("NSP: Nextion command sent = " + str(payload_bin), 3)
  end

  # sets time and date according to Tasmota local time
  def set_clock()
    var now = tasmota.rtc()
    var time_raw = now['local']
    var nsp_time = tasmota.time_dump(time_raw)
    var time_payload = '{"year":' + str(nsp_time['year']) + ',"mon":' + str(nsp_time['month']) + ',"day":' + str(nsp_time['day']) +
     ',"hour":' + str(nsp_time['hour']) + ',"min":' + str(nsp_time['min']) + ',"week":' + str(nsp_time['weekday']) + '}'
    log('NSP: Time and date synced with ' + time_payload, 3)
    self.send(time_payload)
  end

  # sync main screen power bars with tasmota POWER status
  def set_power()
    var ps = tasmota.get_power()
    for i:0..1
      if ps[i] == true
        ps[i] = "on"
      else
        ps[i] = "off"
      end
    end
    var json_payload = '{\"switches\":[{\"outlet\":0,\"switch\":\"' + ps[0] + '\"},{\"outlet\":1,\"switch\":\"' + ps[1] +  '\"}]}'
    log('NSP: Switch state updated with ' + json_payload)
    self.send(json_payload)
  end

  # draw widgets
  def draw()
    var i = 1
    while i < 9
      if size(widget[i]) > 1
        var wdgt = ""
        if widget[i][1] == "scene"
          wdgt = '{"HMI_resources":[{"index":' + str(i) + ',"ctype":"' + widget[i][1] + '","id":"' + str(i) + '"}]}'
        else
          wdgt = '{"HMI_resources":[{"index":' + str(i) + ',"ctype":"' + widget[i][1] + '","id":"' + str(i) + '","uiid":' + str(widget[i][2]) + '}]}'
        end
        var name = '{"relation":[{"ctype":"' + widget[i][1] + '","id":"' + str(i) + '","name":"' + widget[i][0][0..7] + '"}]}'
        self.send(wdgt)
        self.send(name)
      else
      self.send('{"index":' + str(i) + ',"type":"delete"}')
      end
      i += 1
    end
  end

# update weather forecast, since the provider doesn't support range I winged it with FeelsLike temperature
  def set_weather_wttr()
    import json
      var weather_icon = {
        "": 30,      # Unknown
        "113": 1,    # Sunny
        "116": 2,    # PartlyCloudy
        "119": 2,    # Cloudy
        "122": 7,    # VeryCloudy
        "143": 11,   # Fog
        "176": 40,   # LightShowers
        "179": 24,   # LightSleetShowers
        "182": 24,   # LightSleet
        "185": 24,   # LightSleet
        "200": 42,   # ThunderyShowers
        "227": 20,   # LightSnow
        "230": 22,   # HeavySnow
        "248": 11,   # Fog
        "260": 11,   # Fog
        "263": 40,   # LightShowers
        "266": 40,   # LightRain
        "281": 24,   # LightSleet
        "284": 24,   # LightSleet
        "293": 40,   # LightRain
        "296": 40,   # LightRain
        "299": 18,   # HeavyShowers
        "302": 18,   # HeavyRain
        "305": 18,   # HeavyShowers
        "308": 18,   # HeavyRain
        "311": 24,   # LightSleet
        "314": 24,   # LightSleet
        "317": 24,   # LightSleet
        "320": 20,   # LightSnow
        "323": 22,   # LightSnowShowers
        "326": 22,   # LightSnowShowers
        "329": 22,   # HeavySnow
        "332": 22,   # HeavySnow
        "335": 29,   # HeavySnowShowers
        "338": 22,   # HeavySnow
        "350": 24,   # LightSleet
        "353": 24,   # LightSleet
        "356": 18,   # HeavyShowers
        "359": 18,   # HeavyRain
        "362": 24,   # LightSleetShowers
        "365": 24,   # LightSleetShowers
        "368": 22,   # LightSnowShowers
        "371": 29,   # HeavySnowShowers
        "374": 24,   # LightSleetShowers
        "377": 24,   # LightSleet
        "386": 42,   # ThunderyShowers
        "389": 42,   # ThunderyHeavyRain
        "392": 42,   # ThunderySnowShowers
        "395": 29,   # HeavySnowShowers
      }
    var temp
    var tmin
    var tmax
    var cl = webclient()
    var url = "http://wttr.in/" + loc + '?format=j2'
    cl.set_useragent("curl/7.72.0")
    cl.begin(url)
      var code = cl.GET()
      if code == 200 || code == "200"
        try
          var b = json.load(cl.get_string())
          if persist.tempunit == "F"
            temp = b['current_condition'][0]['temp_F']
            tmin = b['weather'][0]['mintempF']
            tmax = b['weather'][0]['maxtempF']
          else
            temp = b['current_condition'][0]['temp_C']
            tmin = b['weather'][0]['mintempC']
            tmax = b['weather'][0]['maxtempC']
          end
          self.send_weather(weather_icon.find(b['current_condition'][0]['weatherCode'], 30), temp, tmin, tmax)
          log('NSP: Weather update for location: ' + b['nearest_area'][0]['areaName'][0]['value'] + ", "+ b['nearest_area'][0]['country'][0]['value'])
          return true
        except .. as e, m
          log('NSP: weather response parse failed: ' + str(e) + ', ' + str(m), 2)
          return false
        end
      end
      log('NSP: Weather update failed! (HTTP ' + str(code) + ')', 3)
      return false
  end

  # shared sender: icon id + current/min/max temps to the screen
  def send_weather(icon, temp, tmin, tmax)
    self.send('{"HMI_weather":' + str(icon) + ',"HMI_outdoorTemp":{"current":' + str(temp) + ',"range":" ' + str(tmin) + ', ' + str(tmax) + '"}}')
  end

  # Open-Meteo — free, no API key, reliable; needs lat,long (NSPLocation must hold coords)
  def set_weather_om()
    import json
    import string
    # WMO weathercode -> NSPanel icon id (same icon ids as the wttr map)
    var wmo_icon = {
      0: 1, 1: 1, 2: 2, 3: 7,          # clear / mainly clear / partly / overcast
      45: 11, 48: 11,                  # fog
      51: 40, 53: 40, 55: 40,          # drizzle
      56: 24, 57: 24,                  # freezing drizzle
      61: 40, 63: 40, 65: 18,          # rain slight/mod/heavy
      66: 24, 67: 24,                  # freezing rain
      71: 20, 73: 22, 75: 22, 77: 20,  # snow
      80: 40, 81: 40, 82: 18,          # rain showers
      85: 20, 86: 29,                  # snow showers
      95: 42, 96: 42, 99: 42           # thunderstorm
    }
    var ll = string.split(loc, ',')
    if size(ll) < 2   return false   end   # place name, not lat,long — use wttr.in
    var unit = persist.tempunit == "F" ? "fahrenheit" : "celsius"
    var url = "https://api.open-meteo.com/v1/forecast?latitude=" + ll[0] +
      "&longitude=" + ll[1] +
      "&current_weather=true&daily=temperature_2m_min,temperature_2m_max" +
      "&forecast_days=1&timezone=auto&temperature_unit=" + unit
    var cl = webclient()
    cl.set_useragent("curl/7.72.0")
    cl.begin(url)
    try
      var code = cl.GET()
      if code == 200 || code == "200"
        var b = json.load(cl.get_string())
        var cw = b['current_weather']
        var dy = b['daily']
        var rnd = /v -> int(v + (v >= 0 ? 0.5 : -0.5))   # round half away from zero
        self.send_weather(wmo_icon.find(int(cw['weathercode']), 30),
          rnd(cw['temperature']), rnd(dy['temperature_2m_min'][0]), rnd(dy['temperature_2m_max'][0]))
        log('NSP: Weather update from Open-Meteo')
        return true
      end
      log('NSP: Open-Meteo update failed! (HTTP ' + str(code) + ')', 3)
      return false
    except .. as e, m
      log('NSP: Open-Meteo fetch/parse failed: ' + str(e) + ', ' + str(m), 2)
      return false
    end
  end

  # Open-Meteo first (reliable); wttr.in as fallback (handles place names, plain HTTP)
  def set_weather()
    if self.set_weather_om()  return true  end
    return self.set_weather_wttr()
  end

  # commands to populate an empty screen, should be executed when screen initializes
  def screeninit()
    # self.send('{"queryInfo":"version"}')
    self.send('{"HMI_ATCDevice":{"ctype":"device","id":"' + self.atc['id'] + '","outlet":' + self.atc['outlet'] + ',"etype":"' + self.atc['etype'] + '"}}')
    self.send('{"relation":[{"ctype":"device","id":"panel","name":"' + devicename + '","online":true}]}')
    self.send('{"HMI_dimOpen":' + persist.dim + '}')
    self.set_clock()
    self.set_power()
    try
      self.set_weather()   # must never abort the rest of screeninit
    except .. as e, m
      log('NSP: weather update failed during screeninit: ' + str(e) + ', ' + str(m), 2)
    end
    self.draw()
    tasmota.cmd("State")
    tasmota.cmd("TelePeriod")
  end

  # read serial port and decode messages according to protocol used
  # frames: 55 AA | type | len lo | len hi | payload | crc lo | crc hi (+ optional stray 00)
  def every_100ms()
    if self.ser.available() > 0
      var chunk = self.ser.read()   # read bytes from serial as bytes
      print("NSP: Received Raw len=" + str(size(chunk)) + " =", chunk.tohex())
      self.rxbuf += chunk
    end
    var b = self.rxbuf
    import string
    while size(b) > 0
      if size(b) >= 10 && b[0..9] == bytes('000000FFFFFF88FFFFFF')
        log("NSP: Screen Initialized")   # print the message as string
        self.screeninit()
        b = b[10..-1]
        continue
      end
      if b[0] == 0x00   # stray pad byte the screen appends after some frames
        b = b[1..-1]
        continue
      end
      if b[0] != 0x55
        # non-protocol data (Nextion mode etc) — report and drop buffer
        var jm = string.format("{\"NSPanel\":{\"Nextion\":\"%s\"}}",str(b[0..-4]))
        tasmota.publish_result(jm, "RESULT")
        b = bytes()
        continue
      end
      if size(b) > 1 && b[1] != 0xAA
        b = b[1..-1]   # stray 0x55 — drop it, keep whatever follows
        continue
      end
      if size(b) < 5   break   end          # length field not fully arrived yet
      var plen = b.get(3, 2)                # payload length, little endian
      if plen <= 0 || plen > 256            # bogus length — skip magic pair, resync
        b = b[2..-1]
        continue
      end
      var frame_len = 7 + plen
      if size(b) < frame_len   break   end  # incomplete frame, wait for next read
      mode = "NSPanel"
      var frame = b[0 .. frame_len-1]
      var payload = b[5 .. 4+plen]
      if self.crc16(b[0 .. 4+plen]) != b.get(5+plen, 2)
        log('NSP: CRC mismatch in frame ' + frame.tohex(), 2)
        b = b[frame_len..-1]
        continue
      end
      if self.atc['mirror'] == true && frame[2] == 0x84
        self.ser.write(frame)   # resend messages with type 0x84 for thermostat page
      end
      if plen > 2 && payload != bytes('7B226572726F72223A307D')   # don't publish {"error":0}
        var jm = string.format("{\"NSPanel\":%s}",payload.asstring())
        tasmota.publish_result(jm, "RESULT")
      end
      b = b[frame_len..-1]
    end
    self.rxbuf = b
  end
end

nsp=NSPanel()

tasmota.add_rule("power1#state", /-> nsp.set_power())
tasmota.add_rule("power2#state", /-> nsp.set_power())

# add NSPSend command to Tasmota
def nspsend(cmd, idx, payload, payload_json)
  # NSPSend2 sends Nextion commands
    if idx == 2
    var command = nsp.sendnx(payload)
  tasmota.resp_cmnd_done()
  # NSPSend sends NSPanel commands, requires valid payload
  else
    import json
    var command = nsp.send(json.dump(payload_json))
    tasmota.resp_cmnd_done()
  end
end

tasmota.add_cmd('NSPSend', nspsend)

# Switch thermostat control on = ATCEnable 1, off = ATCEnable 0
def setATCEnable(cmd, idx, payload, payload_json)
  import string
  if size(str(payload)) == 0
    tasmota.publish_result('{"NSPanel":{"ATCEnable":' + str(int(persist.atcenable)) + '}}', "RESULT")
    tasmota.resp_cmnd_done()
    return
  end
  if string.tolower(str(payload)) == "toggle"
    if persist.atcenable == 1
      payload = "0"
    else
      payload = "1"
    end
  elif payload != "1" && string.tolower(str(payload)) != "true"
    payload = "0"
  else
    payload = "1"
  end
  if str(persist.atcenable) != payload
    var wire = '{"ATCEnable":' + payload + '}'
    nsp.send(wire)
    tasmota.publish_result('{"NSPanel":' + wire + '}', "RESULT")
  end
  tasmota.resp_cmnd_done()
end
tasmota.add_cmd('ATCEnable', setATCEnable)

# Set thermostat value ie ATCExpect 21
def setATCExpect(cmd, idx, payload, payload_json)
  if size(str(payload)) == 0
    tasmota.publish_result('{"NSPanel":{"ATCExpect0":' + str(number(persist.atcexpect0)) + '}}', "RESULT")
    tasmota.resp_cmnd_done()
    return
  end
  if number(persist.atcexpect0) != number(payload)
    var wire = '{"ATCMode":0,"ATCExpect0":' + str(int(payload)) + '}'
    nsp.send(wire)
    tasmota.publish_result('{"NSPanel":' + wire + '}', "RESULT")
  end
  tasmota.resp_cmnd_done()
end
tasmota.add_cmd('ATCExpect', setATCExpect)

# add NSPMode command to Tasmota
def modeselect(NSPMode, idx, payload)
  if payload == "1"
    nsp.sendnx('DRAKJHSUYDGBNCJHGJKSHBDN')
    tasmota.resp_cmnd_done()
    mode = "Nextion"
  elif payload == "0"
    nsp.sendnx('recmod=1')
    nsp.sendnx('recmod=1')
    mode = "NSPanel"
    tasmota.resp_cmnd_done()
  else
  tasmota.resp_cmnd_str('{"Mode":"' + mode + '"}')
  end
end

tasmota.add_cmd('NSPMode', modeselect)

# add NSPDim command to Tasmota
def dimopen(NSPDim, idx, payload)
  if payload == "0" || payload == "1"
    persist.dim = payload
    nsp.send('{"HMI_dimOpen":' + payload + '}')
    tasmota.resp_cmnd_done()
  else
    payload = str(persist.dim)
  end
  import string
  var jm = string.format("{\"NSPanel\":{\"Energy-saving\":%s}}",payload)
  tasmota.publish_result(jm, "RESULT")
end

tasmota.add_cmd('NSPDim', dimopen)

# add NSPLocation command to Tasmota
def setloc(NSPLocation, idx, payload)
  if size(payload) > 1
    persist.loc = payload
    tasmota.resp_cmnd_done()
    persist.save()
    loc = persist.loc
    nsp.set_weather()
  else
    payload = loc
  end
  import string
  var jm = string.format("{\"NSPanel\":{\"Location\":\"%s\"}}",payload)
  tasmota.publish_result(jm, "RESULT")
end
tasmota.add_cmd('NSPLocation', setloc)

# add SetThermostatId command to Tasmota
def setthermostatid(SetThermostatId, idx, payload)
  var changed = false
  if size(payload) > 1
    persist.t_id = payload
    persist.save()
    thermostat_id = persist.t_id
    changed = true
  else
    payload = thermostat_id
  end
  import string
  var jm = string.format("{\"NSPanel\":{\"ThermostatId\":\"%s\"}}",payload)
  tasmota.publish_result(jm, "RESULT")
  if changed
    tasmota.resp_cmnd_done()
    tasmota.cmd('Restart 1')
  end
end
tasmota.add_cmd('SetThermostatId', setthermostatid)

# add GetTele command to Tasmota
def gettele(GetTele, idx, payload)
  tasmota.cmd('TelePeriod -1')
  tasmota.cmd('POWER1')
  tasmota.publish_result('{"NSPanel":{"ATCMode":0,"ATCExpect0":' + str(persist.atcexpect0) + ',"ATCEnable":' + str(persist.atcenable) + '}}', "RESULT")
end
tasmota.add_cmd('GetTele', gettele)


# set displayed indoor temperature to value:int
def set_temp(value)
  if value == nil  return  end   # 0.0 C is a real outdoor reading on this panel
  var temp_payload = '{"temperature":' + str(value) + ',"tempUnit":"' + persist.tempunit + '"}'
  log('NSP: Indoor temperature set with ' + temp_payload, 3)
  nsp.send(temp_payload)
end

# tasmota.add_rule("Tele#" + thermostat_id, set_temp) # temp arrives via MQTT (tas_shedtemp)

# set wifi icon status

def set_wifi(value)
  var rssi = (value-1)/20
  rssi = '{"wifiState":"connected","rssiLevel":' + str(rssi) + '}'
  log('NSP: Wi-Fi icon set with ' + rssi, 3)
  nsp.send(rssi)
end

def set_disconnect()
  nsp.send('{"wifiState":"nonetwork","rssiLevel":0}')
end

def sync_weather() # set weather every 60 minutes, with short retries on failure
  var ok = false
  try
    ok = nsp.set_weather()
  except .. as e, m
    log('NSP: weather sync error: ' + str(e) + ', ' + str(m), 2)
  end
  # exactly one outstanding timer: retry quickly on failure, else normal cadence
  var next = 60*60*1000
  if ok
    weather_retries = 0
    print("Weather forecast synced")
  else
    weather_retries += 1
    if weather_retries <= 3
      log('NSP: weather sync failed, retrying in 60s (' + str(weather_retries) + '/3)', 2)
      next = 60*1000
    else
      log('NSP: weather sync failed ' + str(weather_retries) + 'x, waiting for next hour', 2)
    end
  end
  tasmota.set_timer(next, sync_weather)
end

# heater is remote: command tas_shedtemp's relay over MQTT, track via heaterstate
def thermostat_power(power_on)
  import mqtt
  var state = power_on ? "ON" : "OFF"
  # always republish: tas_shedtemp relays POWER to the diesel heater over a
  # lossy 2.4 GHz link with NO feedback — the per-evaluation re-send is the
  # retry mechanism (fire-and-forget; heaterstate = last commanded, not actual)
  mqtt.publish("cmnd/tas_shedtemp/POWER", state)
  if str(heaterstate) != str(state)   # commanded-state transition: update TelePeriods
    if power_on
      mqtt.publish("cmnd/tas_shedtemp/TelePeriod", str(teleperiods[0]))
      tasmota.cmd("TelePeriod " + str(teleperiods[0]))
    else
      mqtt.publish("cmnd/tas_shedtemp/TelePeriod", str(teleperiods[1]))
      tasmota.cmd("TelePeriod " + str(teleperiods[1]))
    end
  end
end

# thermostat logic — asymmetric deadband; -255 means no data yet
def thermostat_logic()
  if lasttemp == nil || lasttemp == -255
    log('DEF: no valid temperature from tas_shedtemp yet', 1)
  else
    log('DEF: thermostat_logic ATCEnable:' + str(persist.atcenable) + ' ATCExpect0:' + str(persist.atcexpect0) + ' lasttemp:' + str(lasttemp), 1)
    if persist.atcenable == 0
      # its turned off so frost protect
      if lasttemp < frost_protect_temp
        thermostat_power(true)
      elif lasttemp <= (frost_protect_temp + hysteresis_temp + heat_over_temp)
        # do nothing
      else
        thermostat_power(false)
      end
    else
      if lasttemp < (number(persist.atcexpect0) - hysteresis_temp)
        thermostat_power(true)
      elif lasttemp >= (number(persist.atcexpect0) + heat_over_temp)
        thermostat_power(false)
      end
    end
  end
end

# temp sensor has changed
def temp_change(value)
  lasttemp = value
  if lasttemp == nil
    lasttemp = -255   # sentinel: no data; 0.0 C is a real reading here
    thermostat_power(false)   # fail safe: bogus reading mustn't hold the heat on
    return
  end
  lasttemp_at = tasmota.millis()
  thermostat_logic()
end

# tasmota.add_rule("Tele#" + thermostat_id, temp_change) # temp arrives via MQTT (tas_shedtemp)

# debounced flash write — coalesces bursts of ATC events into one save
def persist_save_deferred()
  persist.save()
end

def atcenable_save(value, trigger)
  persist.atcenable = int(value)
  thermostat_logic()
  tasmota.set_timer(5000, persist_save_deferred)
end
tasmota.add_rule("NSPanel#ATCEnable", atcenable_save)

def atcexpect0_save(value, trigger)
  persist.atcexpect0 = number(value)
  thermostat_logic()
  tasmota.set_timer(5000, persist_save_deferred)
end
tasmota.add_rule("NSPanel#ATCExpect0", atcexpect0_save)

# remote temp sensor + remote heater relay live on tas_shedtemp
def temp_mqtt_data(topic, idx, data, databytes)
  import json
  var b = nil
  try
    b = json.load(data)
  except .. as e, m
    log('DEF: malformed SENSOR payload from tas_shedtemp: ' + str(data), 2)
    return
  end
  var ds = b.find('DS18B20')
  var t = ds != nil ? ds.find('Temperature') : nil
  if t == nil
    log('DEF: SENSOR from tas_shedtemp had no DS18B20.Temperature: ' + str(data), 2)
    return
  end
  log('DEF: temp_mqtt_data: ' + str(topic) + ' t:' + str(t) + ' lasttemp:' + str(lasttemp), 1)
  set_temp(t)
  temp_change(t)
end

def power_mqtt_data(topic, idx, data, databytes)
  heaterstate = str(data)   # payload is a bare ON/OFF, not JSON
  log('DEF: power_mqtt_data: ' + str(topic) + ' -> ' + heaterstate, 1)
end

def subscribes()
  import mqtt
  mqtt.subscribe("tele/tas_shedtemp/SENSOR", temp_mqtt_data)
  mqtt.subscribe("stat/tas_shedtemp/POWER", power_mqtt_data)
  mqtt.publish("cmnd/tas_shedtemp/POWER", "")   # query current heater state
  mqtt.publish("cmnd/tas_shedtemp/teleperiod", "")
end

tasmota.add_rule("MQTT#Connected=1", subscribes)

tasmota.cmd("Rule3 1") # needed until Berry bug fixed
tasmota.cmd("State")
tasmota.add_rule("Time#Minute", /-> nsp.set_clock()) # set rule to update clock every minute
tasmota.add_rule("Tele#Wifi#RSSI", set_wifi) # set rule to update wifi icon
tasmota.add_rule("wifi#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
tasmota.add_rule("mqtt#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
tasmota.add_rule("system#boot", /-> nsp.screeninit())

# failsafe: force heater off if no valid temp reading arrives within 2 idle teleperiods
def sensor_watchdog()
  if lasttemp_at != nil && tasmota.millis() - lasttemp_at > 2 * teleperiods[1] * 1000
    log('DEF: tas_shedtemp sensor stale — forcing heater off', 1)
    lasttemp = -255
    thermostat_power(false)
    lasttemp_at = tasmota.millis()   # re-arm: periodic OFF re-command is deliberate (lossy RF link), just not every minute
  end
end
tasmota.add_rule("Time#Minute", sensor_watchdog)
tasmota.add_rule("time#initialized", sync_weather)

tasmota.cmd("TelePeriod")
