-- handlers/bancho.lua
-- Non-blocking Bancho Protocol handler for AyanomiBancho
-- Implements client login, token mapping, and protocol packeting

local db = require('../db')
local bit = require('bit')

local bancho = {}

-- In-memory cache of active Bancho user sessions: token -> user
bancho.sessions = {}

-- Helper to read request POST body asynchronously
local function readBody(req)
  local co = coroutine.running()
  local chunks = {}
  req:on('data', function(chunk)
    table.insert(chunks, chunk)
  end)
  req:on('end', function()
    coroutine.resume(co, table.concat(chunks))
  end)
  return coroutine.yield()
end

-- Pack a 32-bit integer in little-endian format
local function packInt32(val)
  if val < 0 then
    val = val + 4294967296
  end
  local b1 = bit.band(val, 0xFF)
  local b2 = bit.band(bit.rshift(val, 8), 0xFF)
  local b3 = bit.band(bit.rshift(val, 16), 0xFF)
  local b4 = bit.band(bit.rshift(val, 24), 0xFF)
  return string.char(b1, b2, b3, b4)
end

-- Pack a 16-bit unsigned integer in little-endian format
local function packUInt16(val)
  local b1 = bit.band(val, 0xFF)
  local b2 = bit.band(bit.rshift(val, 8), 0xFF)
  return string.char(b1, b2)
end

-- Pack a 64-bit integer in little-endian format (as two 32-bit ints)
local function packInt64(val)
  return packInt32(val) .. packInt32(0)
end

-- Pack a 32-bit float in little-endian format
local function packFloat32(val)
  -- IEEE 754 single precision
  if val == 0 then return "\0\0\0\0" end
  local sign = 0
  if val < 0 then sign = 1; val = -val end
  local mantissa, exponent = math.frexp(val)
  exponent = exponent + 126
  mantissa = (mantissa * 2 - 1) * 8388608 -- 2^23
  local b1 = bit.band(math.floor(mantissa), 0xFF)
  mantissa = math.floor(mantissa / 256)
  local b2 = bit.band(mantissa, 0xFF)
  mantissa = math.floor(mantissa / 256)
  local b3 = bit.bor(bit.band(mantissa, 0x7F), bit.lshift(bit.band(exponent, 1), 7))
  local b4 = bit.bor(bit.rshift(exponent, 1), bit.lshift(sign, 7))
  return string.char(b1, b2, b3, b4)
end

-- Write a ULEB128 encoded integer
local function writeUleb128(num)
  if num == 0 then return "\0" end
  local bytes = {}
  while num ~= 0 do
    local b = bit.band(num, 0x7F)
    num = bit.rshift(num, 7)
    if num ~= 0 then
      b = bit.bor(b, 0x80)
    end
    table.insert(bytes, string.char(b))
  end
  return table.concat(bytes)
end

-- Write an osu! protocol string (0x0b + uleb128 length + utf8 data, or 0x00 for empty)
local function writeString(s)
  if not s or s == "" then
    return "\0"
  end
  return "\x0b" .. writeUleb128(#s) .. s
end

-- Construct a Bancho packet: [ID (2 bytes LE)] [0x00 (1 byte)] [Length (4 bytes LE)] [Body]
local function makePacket(id, body)
  body = body or ""
  local b1 = bit.band(id, 0xFF)
  local b2 = bit.band(bit.rshift(id, 8), 0xFF)
  return string.char(b1, b2, 0) .. packInt32(#body) .. body
end

-- Public packet construction utilities for unit testing
bancho.packInt32 = packInt32
bancho.makePacket = makePacket

-- === Server Packet IDs ===
local ServerPackets = {
  USER_ID = 5,                -- login_reply
  SEND_MESSAGE = 7,
  PONG = 8,
  USER_STATS = 11,
  USER_LOGOUT = 12,
  NOTIFICATION = 24,
  CHANNEL_INFO = 65,
  CHANNEL_AUTO_JOIN = 67,
  PRIVILEGES = 71,
  FRIENDS_LIST = 72,
  PROTOCOL_VERSION = 75,
  MAIN_MENU_ICON = 76,
  USER_PRESENCE = 83,
  RESTART_SERVER = 86,
  CHANNEL_INFO_END = 89,
  SILENCE_END = 92,
}

-- === Packet Builders ===
local function packetProtocolVersion(ver)
  return makePacket(ServerPackets.PROTOCOL_VERSION, packInt32(ver))
end

local function packetLoginReply(userId)
  return makePacket(ServerPackets.USER_ID, packInt32(userId))
end

local function packetBanchoPrivileges(priv)
  return makePacket(ServerPackets.PRIVILEGES, packInt32(priv))
end

local function packetNotification(msg)
  return makePacket(ServerPackets.NOTIFICATION, writeString(msg))
end

local function packetChannelInfo(name, topic, playerCount)
  local body = writeString(name) .. writeString(topic) .. packUInt16(playerCount)
  return makePacket(ServerPackets.CHANNEL_INFO, body)
end

local function packetChannelInfoEnd()
  return makePacket(ServerPackets.CHANNEL_INFO_END, "")
end

local function packetFriendsList(friendIds)
  -- Format: i16 count, then i32 per friend
  local count = friendIds and #friendIds or 0
  local body = packUInt16(count)
  for _, id in ipairs(friendIds or {}) do
    body = body .. packInt32(id)
  end
  return makePacket(ServerPackets.FRIENDS_LIST, body)
end

local function packetSilenceEnd(seconds)
  return makePacket(ServerPackets.SILENCE_END, packInt32(seconds or 0))
end

local function packetMainMenuIcon(iconUrl, onclickUrl)
  return makePacket(ServerPackets.MAIN_MENU_ICON, writeString(iconUrl .. "|" .. onclickUrl))
end

local function packetUserPresence(userId, username, utcOffset, countryCode, banchoPrivs, mode, lon, lat, rank)
  local body = packInt32(userId)
    .. writeString(username)
    .. string.char((utcOffset or 0) + 24)            -- utc_offset + 24
    .. string.char(countryCode or 0)                  -- country code numeric
    .. string.char(bit.bor(banchoPrivs or 0, bit.lshift(mode or 0, 5))) -- priv | (mode << 5)
    .. packFloat32(lon or 0)                          -- longitude
    .. packFloat32(lat or 0)                          -- latitude
    .. packInt32(rank or 0)                           -- global rank
  return makePacket(ServerPackets.USER_PRESENCE, body)
end

local function packetUserStats(userId, action, infoText, mapMd5, mods, mode, mapId, rscore, acc, plays, tscore, rank, pp)
  local body = packInt32(userId)
    .. string.char(action or 0)                       -- action (u8)
    .. writeString(infoText or "")                    -- info_text
    .. writeString(mapMd5 or "")                      -- map_md5
    .. packInt32(mods or 0)                           -- mods
    .. string.char(mode or 0)                         -- mode (u8)
    .. packInt32(mapId or 0)                          -- map_id
    .. packInt64(rscore or 0)                         -- ranked_score (i64)
    .. packFloat32((acc or 0) / 100.0)                -- accuracy (f32)
    .. packInt32(plays or 0)                          -- plays
    .. packInt64(tscore or 0)                         -- total_score (i64)
    .. packInt32(rank or 0)                           -- global_rank
    .. packUInt16(pp or 0)                            -- pp (u16)
  return makePacket(ServerPackets.USER_STATS, body)
end

local function packetRestartServer(ms)
  return makePacket(ServerPackets.RESTART_SERVER, packInt32(ms or 0))
end

-- Client privilege flags
local ClientPrivileges = {
  PLAYER = 1,
  MODERATOR = 2,
  SUPPORTER = 4,
  OWNER = 8,
  DEVELOPER = 16,
}

-- Main Bancho POST / router request handler
function bancho.handle(req, res)
  -- Check if client is using a session token for subsequent pings
  local token = req.headers['osu-token'] or req.headers['cho-token']
  
  if token then
    local user = bancho.sessions[token]
    if not user then
      -- Session expired or invalid, tell client to reconnect
      local resBody = packetNotification("Server has restarted.")
        .. packetRestartServer(0)
      res:writeHead(200, {
        ['Content-Type'] = 'text/html; charset=UTF-8',
        ['Content-Length'] = tostring(#resBody)
      })
      res:finish(resBody)
      return
    end

    -- Read client packets (we don't parse them yet, just acknowledge)
    local _ = readBody(req)

    -- Respond with pong
    local pingPacket = makePacket(ServerPackets.PONG, "")
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=UTF-8',
      ['Content-Length'] = tostring(#pingPacket)
    })
    res:finish(pingPacket)
    return
  else
    -- First time login attempt
    local body = readBody(req)
    if not body or body == "" then
      local failPacket = packetLoginReply(-1)
      res:writeHead(200, {
        ['Content-Type'] = 'text/html; charset=UTF-8',
        ['Content-Length'] = tostring(#failPacket)
      })
      res:finish(failPacket)
      return
    end

    -- Parse login data:
    -- Line 1: username
    -- Line 2: password MD5 hash
    -- Line 3: client_version|utc_offset|display_city|client_hashes|pm_private
    local username, password_md5 = string.match(body, "^([^\r\n]*)\r?\n([^\r\n]*)")
    
    print(string.format("[Bancho] Login attempt: username='%s', md5='%s'", tostring(username), tostring(password_md5)))

    if not username or not password_md5 then
      print("[Bancho] Failed to parse login body")
      local failPacket = packetLoginReply(-1)
      res:writeHead(200, {
        ['Content-Type'] = 'text/plain; charset=utf-8',
        ['Content-Length'] = tostring(#failPacket)
      })
      res:finish(failPacket)
      return
    end

    -- Query username from database
    local users = db.query("SELECT * FROM users WHERE username = ?", username)
    local user = users[1]

    local loginSuccess = false
    if user and user.password_md5 then
      if user.password_md5 == password_md5:lower() then
        loginSuccess = true
      end
    end

    if loginSuccess then
      -- Generate a unique 16-character alphanumeric session token
      local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
      local tokenParts = {}
      for i = 1, 16 do
        local r = math.random(1, #chars)
        table.insert(tokenParts, string.sub(chars, r, r))
      end
      local newToken = table.concat(tokenParts)
      
      -- Map token to user session
      bancho.sessions[newToken] = user

      print(string.format("[Bancho] %s logged in successfully (id: %d, token: %s)", username, user.id, newToken))

      -- Build the full login response packet stream (matching bancho.py)
      local data = ""

      -- 1. Protocol version (packet 75)
      data = data .. packetProtocolVersion(19)

      -- 2. Login reply / User ID (packet 5)
      data = data .. packetLoginReply(user.id)

      -- 3. Bancho privileges (packet 71) - give player + supporter
      local priv = bit.bor(ClientPrivileges.PLAYER, ClientPrivileges.SUPPORTER)
      data = data .. packetBanchoPrivileges(priv)

      -- 4. Welcome notification (packet 24)
      data = data .. packetNotification("Welcome to AyanomiBancho!\nRunning AyanomiBancho Server.")

      -- 5. Channel info (packet 65) - send default channels
      data = data .. packetChannelInfo("#osu", "General discussion", 1)
      data = data .. packetChannelInfo("#announce", "Announcements", 1)

      -- 6. Channel info end (packet 89) - CRITICAL: tells client channels are done
      data = data .. packetChannelInfoEnd()

      -- 7. Main menu icon (packet 76)
      data = data .. packetMainMenuIcon(
        "https://i.imgur.com/placeholder.png",
        "https://o.ayanomi.io.vn"
      )

      -- 8. Friends list (packet 72) - empty for now
      data = data .. packetFriendsList({})

      -- 9. Silence end (packet 92) - 0 = not silenced
      data = data .. packetSilenceEnd(0)

      -- Load user stats from database
      local statsRows = db.query("SELECT * FROM users_stats WHERE id = ?", user.id)
      local stats = statsRows[1] or {}
      local playcount = stats.playcount_std or 0
      local rankedScore = stats.ranked_score_std or 0
      local totalScore = stats.total_score_std or 0
      local pp = 0
      local accuracy = stats.avg_accuracy_std or 100.0
      local globalRank = 0

      -- Calculate global rank (count users with higher ranked score)
      local rankRows = db.query("SELECT COUNT(*) as cnt FROM users_stats WHERE ranked_score_std > ?", rankedScore)
      if rankRows[1] then
        globalRank = (rankRows[1].cnt or 0) + 1
      end

      -- 10. User presence (packet 83) - our player's presence
      data = data .. packetUserPresence(
        user.id,          -- userId
        user.username,    -- username
        7,                -- utcOffset (UTC+7 for Vietnam)
        233,              -- country code (VN = 233)
        bit.bor(ClientPrivileges.PLAYER, ClientPrivileges.SUPPORTER), -- privileges
        0,                -- mode (osu! standard)
        0,                -- longitude
        0,                -- latitude
        globalRank        -- global rank
      )

      -- 11. User stats (packet 11) - our player's stats
      data = data .. packetUserStats(
        user.id,          -- userId
        0,                -- action (Idle)
        "",               -- info_text
        "",               -- map_md5
        0,                -- mods
        0,                -- mode
        0,                -- map_id
        rankedScore,      -- ranked_score
        accuracy,         -- accuracy
        playcount,        -- plays
        totalScore,       -- total_score
        globalRank,       -- global_rank
        pp                -- pp
      )

      res:writeHead(200, {
        ['Content-Type'] = 'text/plain; charset=utf-8',
        ['Content-Length'] = tostring(#data),
        ['cho-token'] = newToken
      })
      res:finish(data)
    else
      -- Invalid credentials
      print(string.format("[Bancho] Login failed for: %s", username or "unknown"))
      local failData = packetNotification("AyanomiBancho: Incorrect credentials")
        .. packetLoginReply(-1)
      res:writeHead(200, {
        ['Content-Type'] = 'text/plain; charset=utf-8',
        ['Content-Length'] = tostring(#failData)
      })
      res:finish(failData)
    end
  end
end

return bancho
