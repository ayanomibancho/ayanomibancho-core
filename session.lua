-- session.lua
-- In-memory Session Manager for AyanomiBancho

local openssl = require('openssl')

local session = {}

-- In-memory session store: mapping of sid -> user table
local sessionStore = {}

-- Parse request cookie header
local function parseCookies(cookieHeader)
  local cookies = {}
  if not cookieHeader then return cookies end
  for pair in string.gmatch(cookieHeader, "[^;]+") do
    local k, v = string.match(pair, "^%s*([^=]+)%s*=%s*(.-)%s*$")
    if k and v then
      cookies[k] = v
    end
  end
  return cookies
end

-- Generate a secure random 32-character hex session ID
local function generateSid()
  local bytes = openssl.random(16)
  local hex = {}
  for i = 1, #bytes do
    table.insert(hex, string.format("%02x", string.byte(bytes, i)))
  end
  return table.concat(hex)
end

-- Create a session for a given user. Returns the session ID.
function session.create(user)
  local sid = generateSid()
  sessionStore[sid] = user
  return sid
end

-- Get user associated with the request (by checking cookies)
function session.get(req)
  local cookieHeader = req.headers and (req.headers.cookie or req.headers.Cookie)
  local cookies = parseCookies(cookieHeader)
  local sid = cookies.sid
  if not sid then return nil end
  return sessionStore[sid], sid
end

-- Destroy a session by session ID
function session.destroy(sid)
  if sid then
    sessionStore[sid] = nil
  end
end

-- Clear all sessions (mostly useful for tests)
function session.clear()
  sessionStore = {}
end

return session
