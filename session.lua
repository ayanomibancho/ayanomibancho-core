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
-- If allowPending is false/nil, sessions with pending_2fa are treated as not logged in
function session.get(req, allowPending)
  if not req.headers then return nil end

  -- Luvit HTTP stores headers as array of {key, value} pairs
  -- We need to search for the Cookie header in both formats
  local cookieHeader = nil
  if type(req.headers) == "table" then
    -- Try array-of-pairs format first (Luvit native)
    for _, pair in ipairs(req.headers) do
      if type(pair) == "table" and pair[1] and pair[1]:lower() == "cookie" then
        cookieHeader = pair[2]
        break
      end
    end
    -- Fallback: try dictionary-style access
    if not cookieHeader then
      cookieHeader = req.headers.cookie or req.headers.Cookie
    end
  end

  local cookies = parseCookies(cookieHeader)
  local sid = cookies.sid
  if not sid then return nil end
  local user = sessionStore[sid]
  if user and user.pending_2fa and not allowPending then
    return nil, sid
  end
  return user, sid
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
