#!/usr/bin/lua
-- API do app Rede (AX3600). Chamada pelo nginx (porta 8077, /nm/api) via fcgi-cgi.
-- O nginx já conferiu o token (cabeçalho X-NM-Token) antes de chegar aqui.
-- Ações (?a=): all (padrão), reset&dev=ethX, reboot (só POST), wantest,
-- block&mac=…, unblock&mac=…, snapshot e mode&m=allow|deny (só POST): controle de acesso ao Wi-Fi;
-- name&mac=…&name=…, static_set&mac=…&ip=… e static_del&mac=… (só POST): nomes e IP fixo.

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

-- controle de acesso ao Wi-Fi (lista de bloqueio OU só autorizados) --------
-- O firmware aplica no boot wireless.@wifi-iface[0/1].maclist conforme macfilter ('deny' = bloqueia a lista,
-- 'allow' = só a lista entra), pela lista "_sec" do chip (/lib/wifi/qcawificfg80211.sh). As duas listas ficam
-- guardadas em /etc/netmon/acl_deny e /etc/netmon/acl_allow; a do modo ativo é copiada para o uci.
-- Trocar de modo não derruba quem continua permitido: a lista do chip só vale para novas conexões, e o
-- script derruba (kickmac) apenas quem ficou de fora.
local WIFACES = { {0, "wl0"}, {1, "wl1"} }
local ACLDIR = "/etc/netmon"

local function wifitool()
  local t = sh("which cfg80211tool"):match("(%S+)")
  return t or "iwpriv"
end

local function uci_list(i)
  local t = {}
  for m in sh("uci -q get wireless.@wifi-iface[" .. i .. "].maclist"):gmatch("%S+") do
    t[#t + 1] = m:lower()
  end
  return t
end

local function contains(list, x)
  for _, v in ipairs(list) do if v == x then return true end end
  return false
end

local function valid_mac(m)
  m = (m or ""):lower():gsub("%%3a", ":")
  if m:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return m end
  return nil
end

local function mode()
  local m = sh("uci -q get wireless.@wifi-iface[0].macfilter"):match("(%S+)")
  if m == "allow" then return "allow" end
  return "deny"
end

local function load_list(kind)
  local f = io.open(ACLDIR .. "/acl_" .. kind, "r")
  if not f then
    -- primeira vez: a lista do modo ativo vem do uci
    if mode() == kind then return uci_list(0) end
    return {}
  end
  local t = {}
  for l in f:lines() do
    local m = valid_mac(l)
    if m and not contains(t, m) then t[#t + 1] = m end
  end
  f:close()
  return t
end

local function save_list(kind, list)
  local f = io.open(ACLDIR .. "/acl_" .. kind, "w")
  if not f then return end
  for _, m in ipairs(list) do f:write(m, "\n") end
  f:close()
end

local function without(list, x)
  local t = {}
  for _, v in ipairs(list) do if v ~= x then t[#t + 1] = v end end
  return t
end

-- quem está conectado agora no Wi-Fi do AX3600: { mac = "wl0" }
local function connected()
  local c = {}
  for _, w in ipairs(WIFACES) do
    for line in sh("wlanconfig " .. w[2] .. " list sta"):gmatch("[^\n]+") do
      local m = line:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s")
      if m then c[m:lower()] = w[2] end
    end
  end
  return c
end

-- MAC de quem fez o pedido (pela tabela ARP). Pela ponte do GT-SRV, é o GT-SRV (cabo).
local function requester()
  local ip = os.getenv("REMOTE_ADDR") or ""
  for line in rdall("/proc/net/arp"):gmatch("[^\n]+") do
    local a, m = line:match("^(%S+)%s+%S+%s+%S+%s+(%S+)")
    if a == ip and m then return m:lower() end
  end
  return nil
end

-- grava o modo e a lista no uci e no chip, e derruba quem ficou de fora
local function apply(md)
  local list = load_list(md)
  for _, w in ipairs(WIFACES) do
    local sec = "wireless.@wifi-iface[" .. w[1] .. "]"
    ex("uci -q delete " .. sec .. ".maclist")
    for _, m in ipairs(list) do ex("uci add_list " .. sec .. ".maclist=" .. m) end
    ex("uci set " .. sec .. ".macfilter=" .. md)
  end
  ex("uci commit wireless")
  local T = wifitool()
  for _, w in ipairs(WIFACES) do
    local cmd = T .. " " .. w[2] .. " maccmd_sec 3"
    for _, m in ipairs(list) do cmd = cmd .. "; " .. T .. " " .. w[2] .. " addmac_sec " .. m end
    local code = (md == "allow") and "1" or ((#list > 0) and "2" or "0")
    cmd = cmd .. "; " .. T .. " " .. w[2] .. " maccmd_sec " .. code
    ex("( " .. cmd .. " ) >/dev/null 2>&1")
  end
  local kick = ""
  for m, wl in pairs(connected()) do
    local fora = (md == "allow" and not contains(list, m)) or (md == "deny" and contains(list, m))
    if fora then kick = kick .. T .. " " .. wl .. " kickmac " .. m .. "; " end
  end
  if kick ~= "" then ex("( " .. kick .. ") >/dev/null 2>&1") end
end

local function acl_json()
  local function arr(list)
    local t = {}
    for _, m in ipairs(list) do t[#t + 1] = q(m) end
    return "[" .. table.concat(t, ",") .. "]"
  end
  local deny = load_list("deny")
  return '{"mode":' .. q(mode()) .. ',"deny":' .. arr(deny) .. ',"allow":' .. arr(load_list("allow")) .. "}",
    arr(deny)
end

-- ações (todas só por POST) -------------------------------------------------
local function acl_action(a)
  local me = requester()
  local conn = connected()
  local md = mode()
  if a == "block" or a == "unblock" then
    local mac = valid_mac(Q.mac)
    if not mac then return "400 Bad Request", '{"error":"mac"}' end
    if a == "block" and mac == me then
      return "409 Conflict", '{"error":"Este é o aparelho que está usando o app."}'
    end
    if md == "allow" then
      local allow = load_list("allow")
      if a == "block" then allow = without(allow, mac)
      elseif not contains(allow, mac) then allow[#allow + 1] = mac end
      save_list("allow", allow)
    else
      local deny = load_list("deny")
      if a == "block" then
        if not contains(deny, mac) then deny[#deny + 1] = mac end
      else
        deny = without(deny, mac)
      end
      save_list("deny", deny)
    end
    apply(md)
  elseif a == "snapshot" then
    -- autoriza todos os conectados agora (soma à lista que já existe)
    local allow = load_list("allow")
    local deny = load_list("deny")
    for m in pairs(conn) do
      if not contains(allow, m) and not contains(deny, m) then allow[#allow + 1] = m end
    end
    save_list("allow", allow)
    if md == "allow" then apply("allow") end
  elseif a == "mode" then
    local novo = Q.m
    if novo ~= "allow" and novo ~= "deny" then return "400 Bad Request", '{"error":"m"}' end
    if novo == "allow" then
      local allow = load_list("allow")
      -- quem está usando o app pelo Wi-Fi entra sempre, para não se trancar para fora
      if me and conn[me] and not contains(allow, me) then allow[#allow + 1] = me end
      if #allow == 0 then
        return "409 Conflict", '{"error":"A lista de autorizados está vazia. Autorize os conectados primeiro."}'
      end
      save_list("allow", allow)
    end
    -- guarda as duas listas em arquivo antes de trocar (na primeira troca, a ativa vinha só do uci)
    save_list("deny", load_list("deny"))
    save_list("allow", load_list("allow"))
    apply(novo)
  end
  local acl = acl_json()
  return "200 OK", '{"ok":true,"acl":' .. acl .. "}"
end

local function chip_json()
  local T = wifitool()
  local t = {}
  for _, w in ipairs(WIFACES) do
    local out = sh(T .. " " .. w[2] .. " getmac_sec")
    local macs = {}
    for m in out:gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do macs[#macs + 1] = q(m:lower()) end
    t[#t + 1] = q(w[2]) .. ":[" .. table.concat(macs, ",") .. "]"
  end
  return "{" .. table.concat(t, ",") .. "}"
end

-- nomes dos aparelhos e IP fixo (os mesmos da tela "DHCP static IP assignment") ---
-- Nomes: banco SQLite da Xiaomi (/etc/xqDb, tabela DEVICE_INFO: MAC em maiúsculas, ONAME = nome que o
-- aparelho informa, NICKNAME = nome dado pelo usuário). IP fixo: a Xiaomi grava a mesma entrada em
-- /etc/config/macbind (a lista da tela) e em /etc/config/dhcp (o que o dnsmasq usa), seção = MAC sem ":".
local XQDB = "/etc/xqDb"

local function opendb()
  local ok, sq = pcall(require, "lsqlite3")
  if not ok then return nil end
  local db = sq.open(XQDB)
  if db and db.busy_timeout then db:busy_timeout(3000) end
  return db
end

local function names_json()
  local db = opendb()
  if not db then return "{}" end
  local t = {}
  for r in db:nrows("SELECT MAC, ONAME, NICKNAME FROM DEVICE_INFO") do
    local mac = valid_mac(r.MAC)
    if mac then
      t[#t + 1] = q(mac) .. ':{"nick":' .. q(r.NICKNAME or "") .. ',"oname":' .. q(r.ONAME or "") .. "}"
    end
  end
  db:close()
  return "{" .. table.concat(t, ",") .. "}"
end

-- { mac = seção } de um arquivo do uci (dhcp ou macbind), só as entradas "host"
local function host_sections(conf)
  local sec = {}
  local tipo = {}
  local out = sh("uci -q show " .. conf)
  for name, ty in out:gmatch(conf .. "%.([%w_]+)=(%w+)\n") do tipo[name] = ty end
  for name, mac in out:gmatch(conf .. "%.([%w_]+)%.mac='([^']+)'") do
    local m = valid_mac(mac)
    if m and tipo[name] == "host" then sec[m] = name end
  end
  return sec, out
end

local function static_json()
  local t, vistos = {}, {}
  for _, conf in ipairs({"macbind", "dhcp"}) do
    local sec, out = host_sections(conf)
    for mac, name in pairs(sec) do
      if not vistos[mac] then
        local ip = out:match(conf .. "%." .. name:gsub("%p", "%%%0") .. "%.ip='([^']+)'")
        if ip then
          vistos[mac] = true
          t[#t + 1] = '{"mac":' .. q(mac) .. ',"ip":' .. q(ip) .. "}"
        end
      end
    end
  end
  return "[" .. table.concat(t, ",") .. "]"
end

local function urldecode(v)
  v = (v or ""):gsub("%+", " ")
  v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return v
end

local function set_name(mac, name)
  name = name:gsub("[%z\1-\31\127]", ""):match("^%s*(.-)%s*$")
  if #name > 48 then name = name:sub(1, 48) end
  local db = opendb()
  if not db then return false, "Banco de nomes indisponível." end
  local MAC = mac:upper()
  local st = db:prepare("UPDATE DEVICE_INFO SET NICKNAME = ? WHERE MAC = ?")
  st:bind_values(name, MAC)
  st:step()
  st:finalize()
  if db:changes() == 0 then
    st = db:prepare("INSERT INTO DEVICE_INFO (MAC, ONAME, NICKNAME, COMPANY, OWNNERID) VALUES (?, '', ?, '', '')")
    st:bind_values(MAC, name)
    st:step()
    st:finalize()
  end
  db:close()
  return true
end

local function lan_prefix()
  local ip = sh("uci -q get network.lan.ipaddr"):match("(%d+%.%d+%.%d+%.)%d+")
  return ip or "10.0.0."
end

local function reload_dhcp()
  ex("uci commit dhcp; uci commit macbind; /etc/init.d/dnsmasq reload >/dev/null 2>&1")
end

local function set_static(mac, ip)
  local pre = lan_prefix()
  local last = tonumber((ip or ""):match("^" .. pre:gsub("%.", "%%.") .. "(%d+)$") or "")
  if not last or last < 2 or last > 254 then
    return false, "IP fora da rede de casa (use " .. pre .. "2 a " .. pre .. "254)."
  end
  if ip == sh("uci -q get network.lan.ipaddr"):match("(%S+)") then
    return false, "Esse é o IP do roteador."
  end
  -- IP já fixado para outro aparelho?
  local _, out = host_sections("dhcp")
  for name, outro in out:gmatch("dhcp%.([%w_]+)%.ip='([^']+)'") do
    local m = out:match("dhcp%." .. name .. "%.mac='([^']+)'")
    if outro == ip and m and valid_mac(m) ~= mac then
      return false, "O IP " .. ip .. " já está fixado para outro aparelho (" .. m .. ")."
    end
  end
  for _, conf in ipairs({"dhcp", "macbind"}) do
    local sec = host_sections(conf)
    local name = sec[mac] or mac:gsub(":", "")
    ex("uci set " .. conf .. "." .. name .. "=host")
    ex("uci set " .. conf .. "." .. name .. ".mac=" .. mac)
    ex("uci set " .. conf .. "." .. name .. ".ip=" .. ip)
    ex("uci set " .. conf .. "." .. name .. ".name=" .. mac:gsub(":", ""))
  end
  reload_dhcp()
  return true
end

local function del_static(mac)
  for _, conf in ipairs({"dhcp", "macbind"}) do
    local sec = host_sections(conf)
    if sec[mac] then ex("uci -q delete " .. conf .. "." .. sec[mac]) end
  end
  reload_dhcp()
  return true
end

local function all_json()
  local acl_text, deny_text = acl_json()
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
    ',"acl":' .. acl_text ..
    ',"blocked":' .. deny_text ..
    ',"me":' .. q(requester() or "") ..
    ',"names":' .. names_json() ..
    ',"static":' .. static_json() ..
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
elseif a == "name" or a == "static_set" or a == "static_del" then
  local mac = valid_mac(Q.mac)
  if METHOD ~= "POST" then
    out("405 Method Not Allowed", '{"error":"POST"}')
  elseif not mac then
    out("400 Bad Request", '{"error":"mac"}')
  else
    local ok, err
    if a == "name" then
      ok, err = set_name(mac, urldecode(Q.name))
    elseif a == "static_set" then
      ok, err = set_static(mac, urldecode(Q.ip))
    else
      ok, err = del_static(mac)
    end
    if ok then out("200 OK", '{"ok":true}') else out("409 Conflict", '{"error":' .. q(err) .. "}") end
  end
elseif a == "block" or a == "unblock" or a == "snapshot" or a == "mode" then
  if METHOD ~= "POST" then
    out("405 Method Not Allowed", '{"error":"POST"}')
  else
    local st, body = acl_action(a)
    if st == "200 OK" then
      body = body:sub(1, -2) .. ',"chip":' .. chip_json() .. "}"
    end
    out(st, body)
  end
else
  out("400 Bad Request", '{"error":"a"}')
end
