#!/usr/bin/lua
-- API do app Rede (AX3600). Chamada pelo nginx (porta 8077, /nm/api) via fcgi-cgi.
-- O nginx já conferiu o token (cabeçalho X-NM-Token) antes de chegar aqui.
-- Ações (?a=): all (padrão), reset&dev=ethX, reboot (só POST), wantest.

local function rd(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  return s
end

local function rdall(p)
  local f = io.open(p, "r")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return s
end

local function wr(p, s)
  local f = io.open(p, "w")
  if f then f:write(s, "\n") f:close() end
end

-- o fcgi-cgi não repassa PATH; os comandos ganham um PATH fixo
local PATHP = "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; "

local function ex(cmd)
  os.execute(PATHP .. cmd)
end

local function sh(cmd)
  local f = io.popen(PATHP .. cmd .. " 2>/dev/null")
  if not f then return "" end
  local s = f:read("*a") or ""
  f:close()
  return s
end

local function q(s)
  s = tostring(s == nil and "" or s)
  s = s:gsub('[%z\1-\31"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function raw(s)
  s = (s or ""):match("^%s*(.-)%s*$")
  if s == "" then return "null" end
  return s
end

local function num(x)
  local n = tonumber(x)
  if not n then return "null" end
  return tostring(n)
end

local function uptime()
  local u = rd("/proc/uptime") or "0"
  return tonumber(u:match("^(%S+)")) or 0
end

-- parâmetros ---------------------------------------------------------------
local Q = {}
for k, v in (os.getenv("QUERY_STRING") or ""):gmatch("([^&=]+)=([^&]*)") do
  Q[k] = v
end
local METHOD = os.getenv("REQUEST_METHOD") or "GET"

local function out(status, body)
  io.write("Status: ", status, "\r\n")
  io.write("Content-Type: application/json\r\n")
  io.write("Cache-Control: no-store\r\n\r\n")
  io.write(body, "\n")
end

-- portas (mesma lógica do rodapé e da seção Port status) --------------------
local P = {
  {"WAN", "eth1", "ZTE modem"},
  {"LAN1", "eth2", "IoT router"},
  {"LAN2", "eth3", "GT-SRV"},
  {"LAN3", "eth4", ""},
}
local BOOT = rd("/proc/sys/kernel/random/boot_id") or ""

local function bfile(dev)
  if dev == "eth1" then return "/etc/wanlink.base" end
  return "/etc/wanlink/base." .. dev
end

local function counters(dev)
  local d = "/sys/class/net/" .. dev
  local c = tonumber(rd(d .. "/carrier_changes") or "") or 0
  local e = tonumber(rd(d .. "/statistics/rx_crc_errors") or "") or 0
  return c, e
end

local function stats(dev)
  local c, e = counters(dev)
  local b = rd(bfile(dev)) or ""
  local bb, bc, be, bd = b:match("^(%S+) (%d+) (%d+) ?(%S*)")
  local since = ""
  if bb == BOOT then
    c = c - tonumber(bc)
    e = e - tonumber(be)
    since = (bd or ""):gsub("_", " ")
  else
    c = c - 1
    if c < 0 then c = 0 end
  end
  return math.floor((c + 1) / 2), e, since
end

local function ports_json()
  local names = {}
  local f = io.open("/etc/wanlink/ports.names", "r")
  if f then
    for l in f:lines() do names[#names + 1] = l end
    f:close()
  else
    for i = 1, #P do names[i] = P[i][3] end
  end
  local t = {}
  for i, p in ipairs(P) do
    local d = "/sys/class/net/" .. p[2]
    local up = rd(d .. "/carrier") == "1"
    local dr, ce, since = stats(p[2])
    local st = d .. "/statistics/"
    t[#t + 1] = "{" ..
      '"port":' .. q(p[1]) .. ',"dev":' .. q(p[2]) ..
      ',"label":' .. q(names[i] or "") ..
      ',"up":' .. (up and "true" or "false") ..
      ',"speed":' .. (up and num(rd(d .. "/speed")) or "null") ..
      ',"duplex":' .. q(up and (rd(d .. "/duplex") or "") or "") ..
      ',"drops":' .. dr .. ',"crc":' .. ce .. ',"since":' .. q(since) ..
      ',"rx_bytes":' .. num(rd(st .. "rx_bytes")) ..
      ',"tx_bytes":' .. num(rd(st .. "tx_bytes")) .. "}"
  end
  return "[" .. table.concat(t, ",") .. "]"
end

-- Wi-Fi: wlanconfig <if> list sta -------------------------------------------
local function wifi_json(ifname)
  local t = {}
  for line in sh("wlanconfig " .. ifname .. " list sta"):gmatch("[^\n]+") do
    local mac, rest = line:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.*)$")
    if mac then
      local aid, chan, tx, rx, rssi = rest:match("^(%d+)%s+(%d+)%s+(%d+)M?%s+(%d+)M?%s+(%-?%d+)")
      local assoc = rest:match("%s(%d+:%d%d:%d%d)%s")
      local mode = rest:match("IEEE80211_MODE_(%S+)")
      t[#t + 1] = "{" ..
        '"mac":' .. q(mac:lower()) ..
        ',"chan":' .. num(chan) ..
        ',"tx":' .. num(tx) .. ',"rx":' .. num(rx) ..
        ',"rssi":' .. num(rssi) ..
        ',"assoc":' .. q(assoc or "") ..
        ',"mode":' .. q(mode or "") .. "}"
    end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

-- tabela de MACs da bridge (em que porta cada aparelho foi visto) ------------
local function fdb_json()
  local portname = {}
  for ifn in sh("ls /sys/class/net/br-lan/brif"):gmatch("%S+") do
    local pn = rd("/sys/class/net/br-lan/brif/" .. ifn .. "/port_no") or ""
    local h = pn:match("0x(%x+)")
    if h then portname[tonumber(h, 16)] = ifn end
  end
  local t = {}
  for line in sh("brctl showmacs br-lan"):gmatch("[^\n]+") do
    local pno, mac, loc, age = line:match("^%s*(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if pno and loc == "no" then
      t[#t + 1] = "{" ..
        '"mac":' .. q(mac:lower()) ..
        ',"dev":' .. q(portname[tonumber(pno)] or "") ..
        ',"age":' .. num(age) .. "}"
    end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

local function leases_json()
  local t = {}
  for line in rdall("/tmp/dhcp.leases"):gmatch("[^\n]+") do
    local exp, mac, ip, name = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if mac then
      if name == "*" then name = "" end
      t[#t + 1] = "{" ..
        '"mac":' .. q(mac:lower()) .. ',"ip":' .. q(ip) ..
        ',"name":' .. q(name) .. ',"exp":' .. num(exp) .. "}"
    end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

local function arp_json()
  local t = {}
  local first = true
  for line in rdall("/proc/net/arp"):gmatch("[^\n]+") do
    if first then
      first = false
    else
      local ip, flags, mac, dev = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)%s+%S+%s+(%S+)")
      if ip and flags ~= "0x0" and mac ~= "00:00:00:00:00:00" then
        t[#t + 1] = "{" ..
          '"ip":' .. q(ip) .. ',"mac":' .. q(mac:lower()) ..
          ',"dev":' .. q(dev) .. "}"
      end
    end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

local function sys_json()
  local mt = rdall("/proc/meminfo")
  local total = mt:match("MemTotal:%s+(%d+)")
  local avail = mt:match("MemAvailable:%s+(%d+)")
  local load = (rd("/proc/loadavg") or ""):match("^(%S+ %S+ %S+)")
  return "{" ..
    '"host":' .. q(rd("/proc/sys/kernel/hostname") or "") ..
    ',"uptime":' .. string.format("%d", math.floor(uptime())) ..
    ',"load":' .. q(load or "") ..
    ',"mem_total_kb":' .. num(total) ..
    ',"mem_avail_kb":' .. num(avail) ..
    ',"time":' .. os.time() .. "}"
end

local function all_json()
  return "{" ..
    '"v":1' ..
    ',"sys":' .. sys_json() ..
    ',"wan":' .. raw(sh("ubus call network.interface.wan status")) ..
    ',"wan6":' .. raw(sh("ubus call network.interface.wan_6 status")) ..
    ',"ports":' .. ports_json() ..
    ',"wifi":{"5g":' .. wifi_json("wl0") .. ',"2g":' .. wifi_json("wl1") .. "}" ..
    ',"fdb":' .. fdb_json() ..
    ',"leases":' .. leases_json() ..
    ',"arp":' .. arp_json() ..
    ',"devices":' .. raw(sh("ubus call trafficd hw")) ..
    "}"
end

-- teste de internet feito pelo próprio roteador (Cloudflare) ----------------
local function wantest()
  local T = "/tmp/netmon/wt"
  local L = "/tmp/netmon/wt.lock"
  local held = tonumber(rd(L) or "")
  if held and uptime() - held < 90 then
    return out("409 Conflict", '{"error":"busy"}')
  end
  ex("mkdir -p /tmp/netmon")
  wr(L, string.format("%d", math.floor(uptime())))
  local secs = tonumber(Q.secs or "") or 8
  if secs < 3 then secs = 3 end
  if secs > 15 then secs = 15 end
  local n = 4
  ex("rm -rf " .. T .. " && mkdir -p " .. T)
  -- latência: 5 pings para 1.1.1.1
  local ping = sh("ping -c 5 -W 2 1.1.1.1"):match("= [%d%.]+/([%d%.]+)/")
  local dl = "https://speed.cloudflare.com/__down?bytes=99999999"
  local cmd = ""
  for i = 1, n do
    cmd = cmd .. "curl -k -s -m " .. secs .. " -o /dev/null -w '%{size_download}' '" ..
      dl .. "' > " .. T .. "/d" .. i .. " & "
  end
  local t0 = uptime()
  ex("( " .. cmd .. " wait ) >/dev/null 2>&1")
  local t1 = uptime()
  local down = 0
  for i = 1, n do down = down + (tonumber(rd(T .. "/d" .. i) or "") or 0) end
  cmd = ""
  for i = 1, n do
    cmd = cmd .. "dd if=/dev/zero bs=1M count=300 2>/dev/null | curl -k -s -m " .. secs ..
      " -H 'Expect:' -T - -X POST -o /dev/null -w '%{size_upload}' " ..
      "https://speed.cloudflare.com/__up > " .. T .. "/u" .. i .. " & "
  end
  local t2 = uptime()
  ex("( " .. cmd .. " wait ) >/dev/null 2>&1")
  local t3 = uptime()
  local up = 0
  for i = 1, n do up = up + (tonumber(rd(T .. "/u" .. i) or "") or 0) end
  ex("rm -rf " .. T .. " " .. L)
  local dsec = t1 - t0
  local usec = t3 - t2
  if dsec <= 0 then dsec = 1 end
  if usec <= 0 then usec = 1 end
  out("200 OK", "{" ..
    '"down_mbps":' .. string.format("%.1f", down * 8 / dsec / 1e6) ..
    ',"up_mbps":' .. string.format("%.1f", up * 8 / usec / 1e6) ..
    ',"down_bytes":' .. string.format("%d", math.floor(down)) ..
    ',"up_bytes":' .. string.format("%d", math.floor(up)) ..
    ',"down_secs":' .. string.format("%.2f", dsec) ..
    ',"up_secs":' .. string.format("%.2f", usec) ..
    ',"ping_ms":' .. num(ping) ..
    ',"streams":' .. n .. "}")
end

-- roteamento ---------------------------------------------------------------
local a = Q.a or "all"
if a == "all" then
  out("200 OK", all_json())
elseif a == "reset" then
  local ok = false
  for i = 1, #P do
    if Q.dev == P[i][2] then
      local c, e = counters(Q.dev)
      ex("mkdir -p /etc/wanlink")
      wr(bfile(Q.dev), BOOT .. " " .. c .. " " .. e .. " " .. os.date("%d/%m/%Y_%H:%M"))
      ok = true
    end
  end
  if ok then out("200 OK", '{"ok":true}') else out("400 Bad Request", '{"error":"dev"}') end
elseif a == "reboot" then
  if METHOD ~= "POST" then
    out("405 Method Not Allowed", '{"error":"POST"}')
  else
    out("200 OK", '{"ok":true}')
    io.stdout:flush()
    ex("( sleep 3; reboot ) </dev/null >/dev/null 2>&1 &")
  end
elseif a == "wantest" then
  wantest()
else
  out("400 Bad Request", '{"error":"a"}')
end
