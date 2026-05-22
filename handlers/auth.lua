-- handlers/auth.lua
-- Route handlers for User Registration, Login, and Logout

local db = require('../db')
local template = require('../template')
local session = require('../session')
local config = require('../config')
local querystring = require('querystring')
local openssl = require('openssl')

local auth = {}

local loginFailures = {}
local gcCounter = 0

local function getHeader(req, name)
  if not req.headers then return nil end
  local lowerName = name:lower()
  -- Try Luvit array-of-pairs format first
  for _, pair in ipairs(req.headers) do
    if type(pair) == "table" and pair[1] and pair[1]:lower() == lowerName then
      return pair[2]
    end
  end
  -- Fallback: dictionary-style access
  return req.headers[lowerName] or req.headers[name]
end

local function getClientIp(req)
  local xff = getHeader(req, 'x-forwarded-for')
  if xff and xff ~= "" then
    local ip = string.match(xff, "^%s*([^,%s]+)")
    if ip then return ip end
  end

  local xri = getHeader(req, 'x-real-ip')
  if xri and xri ~= "" then
    return xri
  end

  if req.socket and req.socket.address then
    local ok, addr = pcall(req.socket.address, req.socket)
    if ok and addr and addr.ip then
      return addr.ip
    end
  end

  return "127.0.0.1"
end

-- Helper to read POST request body asynchronously
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

-- Helper to calculate SHA256 hash of a password
local function hashPassword(password)
  return openssl.digest.digest('sha256', password)
end

-- Base32 decode/encode for TOTP
local base32_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local base32_map = {}
for i = 1, #base32_chars do
  base32_map[base32_chars:sub(i, i)] = i - 1
end

local function decodeBase32(str)
  str = str:upper():gsub("[=%s]", "")
  local bits = 0
  local val = 0
  local bytes = {}
  for i = 1, #str do
    local c = str:sub(i, i)
    local digit = base32_map[c]
    if not digit then return nil end
    val = (val * 32) + digit
    bits = bits + 5
    while bits >= 8 do
      bits = bits - 8
      local byte = math.floor(val / (2 ^ bits))
      table.insert(bytes, string.char(byte % 256))
      val = val % (2 ^ bits)
    end
  end
  return table.concat(bytes)
end

local function generateSecret()
  local rawBytes = openssl.random(10)
  local secret = {}
  for i = 1, 16 do
    local idx = (rawBytes:byte(((i-1) % 10) + 1) % 32) + 1
    table.insert(secret, base32_chars:sub(idx, idx))
  end
  return table.concat(secret)
end

local function getTOTP(secret, time)
  local bit = require('bit')
  local secret_bytes = decodeBase32(secret)
  if not secret_bytes then return nil end
  local T = math.floor(time / 30)
  local msg = ""
  for i = 7, 0, -1 do
    local byte = math.floor(T / (256 ^ i)) % 256
    msg = msg .. string.char(byte)
  end
  local hmac_val = openssl.hmac.digest('sha1', msg, secret_bytes, true)
  local offset = bit.band(hmac_val:byte(20), 0x0f) + 1
  local b1, b2, b3, b4 = hmac_val:byte(offset, offset + 3)
  local num = bit.bor(
    bit.lshift(bit.band(b1, 0x7f), 24),
    bit.lshift(b2, 16),
    bit.lshift(b3, 8),
    b4
  )
  local code = num % 1000000
  return string.format("%06d", code)
end

local function verifyTOTP(secret, code)
  local now = os.time()
  for _, offset in ipairs({0, -30, 30}) do
    local expected = getTOTP(secret, now + offset)
    if expected and expected == code then
      return true
    end
  end
  return false
end

-- Cloudflare Turnstile verification
local function verifyTurnstile(token, remoteIp)
  if not config.turnstile or not config.turnstile.secret_key or config.turnstile.secret_key == "" then
    return true -- Skip if not configured
  end
  if not token or token == "" then
    return false
  end
  local ok, coroHttp = pcall(require, 'coro-http')
  if not ok then return true end -- Skip if coro-http not available
  local body = "secret=" .. config.turnstile.secret_key .. "&response=" .. token
  if remoteIp and remoteIp ~= "" then
    body = body .. "&remoteip=" .. remoteIp
  end
  local success, res, data = pcall(coroHttp.request, "POST", "https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    {"Content-Type", "application/x-www-form-urlencoded"},
    {"Content-Length", tostring(#body)}
  }, body)
  if not success then
    print("[Auth] Turnstile verification request failed: " .. tostring(res))
    return true -- Fail open if request errors
  end
  if data and string.find(data, '"success"%s*:%s*true') then
    return true
  end
  return false
end

-- Helper: get Turnstile template variables for login/register pages
local function turnstileVars()
  local siteKey = config.turnstile and config.turnstile.site_key or ""
  return {
    turnstile_site_key = siteKey,
    turnstile_display = (siteKey ~= "") and "block" or "none"
  }
end

-- Helper: merge turnstile vars into a data context table
local function withTurnstile(ctx)
  local tv = turnstileVars()
  for k, v in pairs(tv) do ctx[k] = v end
  return ctx
end

-- GET /register
function auth.registerPage(req, res)
  local currentUser = session.get(req)
  if currentUser then
    res:writeHead(302, { ['Location'] = '/' })
    res:finish()
    return
  end

  local dataContext = {
    title = "Register",
    error = "",
    error_display = "none"
  }
  withTurnstile(dataContext)
  local success, renderedHtml = pcall(template.render, "register", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /register
function auth.registerSubmit(req, res)
  local currentUser = session.get(req)
  if currentUser then
    res:writeHead(302, { ['Location'] = '/' })
    res:finish()
    return
  end

  local body = readBody(req)
  local params = querystring.parse(body)
  local username = params.username or ""
  local email = params.email or ""
  local password = params.password or ""
  local passwordConfirm = params.password_confirm or ""

  local turnstileToken = params['cf-turnstile-response'] or ""

  local errStr = ""

  if not verifyTurnstile(turnstileToken, getClientIp(req)) then
    errStr = "Human verification failed. Please try again."
  end

  -- Basic input validation
  if username == "" or email == "" or password == "" or passwordConfirm == "" then
    errStr = "All fields are required."
  elseif password ~= passwordConfirm then
    errStr = "Passwords do not match."
  elseif #password < 6 then
    errStr = "Password must be at least 6 characters long."
  elseif not string.match(username, "^[a-zA-Z0-9%s_-]+$") then
    errStr = "Username contains invalid characters. Use alphanumeric, spaces, hyphens, and underscores only."
  elseif #username < 2 or #username > 15 then
    errStr = "Username must be between 2 and 15 characters."
  end

  -- Database validation: Check if username/email already exists
  if errStr == "" then
    local users = db.query("SELECT * FROM users WHERE username = ? OR email = ?", username, email)
    if #users > 0 then
      for _, u in ipairs(users) do
        if u.username:lower() == username:lower() then
          errStr = "Username is already registered."
          break
        elseif u.email and u.email:lower() == email:lower() then
          errStr = "Email is already registered."
          break
        end
      end
    end
  end

  if errStr ~= "" then
    local dataContext = {
      title = "Register",
      error = errStr,
      error_display = "block"
    }
    withTurnstile(dataContext)
    local success, renderedHtml = pcall(template.render, "register", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
    return
  end

  -- Insert new user into database
  local passHash = hashPassword(password)
  local passMd5 = openssl.digest.digest('md5', password)
  local result = db.query("INSERT INTO users (username, email, password_hash, password_md5) VALUES (?, ?, ?, ?)", username, email, passHash, passMd5)
  
  -- Query the created user to put in session
  local queryNewUser = db.query("SELECT * FROM users WHERE username = ?", username)
  local newUser = queryNewUser[1]

  if newUser then
    local sid = session.create(newUser)
    res:writeHead(302, {
      ['Location'] = '/',
      ['Set-Cookie'] = "sid=" .. sid .. "; Path=/; HttpOnly"
    })
    res:finish()
  else
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish("Error creating user account.")
  end
end

-- GET /login
function auth.loginPage(req, res)
  local currentUser = session.get(req)
  if currentUser then
    res:writeHead(302, { ['Location'] = '/' })
    res:finish()
    return
  end

  local dataContext = {
    title = "Login",
    error = "",
    error_display = "none"
  }
  withTurnstile(dataContext)
  local success, renderedHtml = pcall(template.render, "login", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /login
function auth.loginSubmit(req, res)
  local currentUser = session.get(req)
  if currentUser then
    res:writeHead(302, { ['Location'] = '/' })
    res:finish()
    return
  end

  local ip = getClientIp(req)
  local now = os.time()

  -- Inline Garbage Collection for loginFailures
  gcCounter = gcCounter + 1
  if gcCounter % 50 == 0 then
    for k, v in pairs(loginFailures) do
      if v.blockedUntil and now >= v.blockedUntil then
        loginFailures[k] = nil
      elseif not v.blockedUntil and now - v.lastAttempt > 300 then
        loginFailures[k] = nil
      end
    end
  end

  local failRecord = loginFailures[ip]
  if failRecord then
    if failRecord.blockedUntil and now < failRecord.blockedUntil then
      local remaining = math.max(0, math.ceil(failRecord.blockedUntil - now))
      local minutes = math.ceil(remaining / 60)
      local dataContext = {
        title = "Login",
        error = string.format("Too many failed login attempts. Please wait %d minute(s) before trying again.", minutes),
        error_display = "block"
      }
      withTurnstile(dataContext)
      local success, renderedHtml = pcall(template.render, "login", dataContext)
      res:writeHead(200, {
        ['Content-Type'] = 'text/html; charset=utf-8',
        ['Content-Length'] = success and tostring(#renderedHtml) or 24
      })
      res:finish(success and renderedHtml or "Internal rendering error")
      return
    elseif failRecord.blockedUntil and now >= failRecord.blockedUntil then
      loginFailures[ip] = nil
      failRecord = nil
    end
  end

  local body = readBody(req)
  local params = querystring.parse(body)
  local turnstileToken = params['cf-turnstile-response'] or ""
  local username = params.username or ""
  local password = params.password or ""

  -- Verify Turnstile
  if not verifyTurnstile(turnstileToken, ip) then
    local dataContext = {
      title = "Login",
      error = "Human verification failed. Please try again.",
      error_display = "block"
    }
    withTurnstile(dataContext)
    local success, renderedHtml = pcall(template.render, "login", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
    return
  end

  local user = nil
  if username ~= "" and password ~= "" then
    local users = db.query("SELECT * FROM users WHERE username = ? OR email = ?", username, username)
    local candidate = users[1]
    if candidate then
      local passHash = hashPassword(password)
      if candidate.password_hash == passHash then
        user = candidate
      end
    end
  end

  if user then
    if user.two_factor_enabled and user.two_factor_enabled == 1 then
      -- 2FA is enabled: create a pending session and redirect to 2FA page
      user.pending_2fa = true
      local sid = session.create(user)
      res:writeHead(302, {
        ['Location'] = '/login/2fa',
        ['Set-Cookie'] = "sid=" .. sid .. "; Path=/; HttpOnly"
      })
      res:finish()
    else
      -- Normal login (no 2FA)
      loginFailures[ip] = nil
      local sid = session.create(user)
      res:writeHead(302, {
        ['Location'] = '/',
        ['Set-Cookie'] = "sid=" .. sid .. "; Path=/; HttpOnly"
      })
      res:finish()
    end
  else
    failRecord = loginFailures[ip]
    if not failRecord then
      failRecord = { count = 0, lastAttempt = now }
      loginFailures[ip] = failRecord
    end
    failRecord.count = failRecord.count + 1
    failRecord.lastAttempt = now

    if failRecord.count >= 5 then
      failRecord.blockedUntil = now + 300
      local dataContext = {
        title = "Login",
        error = "Too many failed login attempts. Please try again in 5 minutes.",
        error_display = "block"
      }
      withTurnstile(dataContext)
      local success, renderedHtml = pcall(template.render, "login", dataContext)
      res:writeHead(200, {
        ['Content-Type'] = 'text/html; charset=utf-8',
        ['Content-Length'] = success and tostring(#renderedHtml) or 24
      })
      res:finish(success and renderedHtml or "Internal rendering error")
    else
      local dataContext = {
        title = "Login",
        error = "Invalid username/email or password.",
        error_display = "block"
      }
      withTurnstile(dataContext)
      local success, renderedHtml = pcall(template.render, "login", dataContext)
      res:writeHead(200, {
        ['Content-Type'] = 'text/html; charset=utf-8',
        ['Content-Length'] = success and tostring(#renderedHtml) or 24
      })
      res:finish(success and renderedHtml or "Internal rendering error")
    end
  end
end

-- GET /logout
function auth.logout(req, res)
  local _, sid = session.get(req, true)
  if sid then
    session.destroy(sid)
  end

  res:writeHead(302, {
    ['Location'] = '/',
    ['Set-Cookie'] = "sid=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
  })
  res:finish()
end

-- POST /users - osu! client in-game registration
-- osu! stable sends multipart/form-data with: user[username], user[user_email], user[password]
-- If check=0, create account. If check=1, only validate.
function auth.registerClient(req, res)
  local body = readBody(req)

  -- Parse multipart/form-data body
  -- Extract boundary from Content-Type header or detect from body
  local params = {}
  local boundary = nil

  -- Try to get boundary from Content-Type header
  local contentType = getHeader(req, 'content-type') or ""
  boundary = contentType:match('boundary="?([^";%s]+)"?')

  if not boundary then
    -- Detect boundary from the first line of the body
    boundary = body:match("^(%-%-%-+%d+)")
  end

  if boundary then
    -- Split body by boundary and extract name/value pairs
    -- Each part looks like:
    --   Content-Disposition: form-data; name="fieldname"
    --   \r\n
    --   value
    local pattern = 'Content%-Disposition: form%-data; name="([^"]+)"%s*\r?\n\r?\n(.-)\r?\n%-%-'
    for name, value in body:gmatch(pattern) do
      params[name] = value:match("^%s*(.-)%s*$") -- trim whitespace
    end
  else
    -- Fallback: try URL-encoded parsing
    for pair in body:gmatch("[^&]+") do
      local key, value = pair:match("^(.-)=(.*)$")
      if key then
        key = key:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        value = value:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        value = value:gsub("%+", " ")
        params[key] = value
      end
    end
  end

  local username = params['user[username]'] or ""
  local email = params['user[user_email]'] or ""
  local password = params['user[password]'] or ""
  local check = params['check']

  print(string.format("[Auth] Client registration: username='%s', email='%s', check=%s", username, email, tostring(check)))

  -- Validation
  local errors = {}

  if username == "" then
    table.insert(errors, "Username is required.")
  elseif not string.match(username, "^[a-zA-Z0-9%s_%-]+$") then
    table.insert(errors, "Username contains invalid characters.")
  elseif #username < 2 or #username > 15 then
    table.insert(errors, "Username must be between 2 and 15 characters.")
  end

  if email == "" then
    table.insert(errors, "Email address is required.")
  end

  if password == "" then
    table.insert(errors, "Password is required.")
  elseif #password < 8 then
    table.insert(errors, "Password must be at least 8 characters.")
  end

  -- Check if username/email already taken
  if #errors == 0 then
    local existing = db.query("SELECT id, username, email FROM users WHERE username = ? OR email = ?", username, email)
    for _, u in ipairs(existing) do
      if u.username:lower() == username:lower() then
        table.insert(errors, "Username already taken.")
      elseif u.email and u.email:lower() == email:lower() then
        table.insert(errors, "Email already in use.")
      end
    end
  end

  if #errors > 0 then
    -- Return error response
    local errBody = table.concat(errors, "\n")
    res:writeHead(400, {
      ['Content-Type'] = 'text/plain; charset=utf-8',
      ['Content-Length'] = tostring(#errBody)
    })
    res:finish(errBody)
    return
  end

  -- If check=1, just validate without creating
  if check == "1" then
    local okBody = "ok"
    res:writeHead(200, {
      ['Content-Type'] = 'text/plain; charset=utf-8',
      ['Content-Length'] = tostring(#okBody)
    })
    res:finish(okBody)
    return
  end

  -- Create account
  local passHash = hashPassword(password)
  local passMd5 = openssl.digest.digest('md5', password)
  local result = db.query("INSERT INTO users (username, email, password_hash, password_md5) VALUES (?, ?, ?, ?)", username, email, passHash, passMd5)

  -- Create stats entries for the new user
  local newUserId = result.insert_id
  if newUserId then
    db.query("INSERT OR IGNORE INTO users_stats (id) VALUES (?)", newUserId)
    db.query("INSERT OR IGNORE INTO users_stats_relax (id) VALUES (?)", newUserId)
  end

  print(string.format("[Auth] Client registration successful: %s (id=%s, %s)", username, tostring(newUserId), email))

  local okBody = "ok"
  res:writeHead(200, {
    ['Content-Type'] = 'text/plain; charset=utf-8',
    ['Content-Length'] = tostring(#okBody)
  })
  res:finish(okBody)
end

-- Helper to parse multipart file from raw POST body for avatar upload
local function parseAvatarUpload(body, boundary)
  if not boundary then return nil, "No multipart boundary found." end
  local boundaryStr = "--" .. boundary
  
  local partStart = string.find(body, boundaryStr, 1, true)
  if not partStart then return nil, "Multipart boundary not found in body." end
  
  local headerEnd = string.find(body, "\r\n\r\n", partStart, true)
  if not headerEnd then return nil, "Invalid multipart header structure." end
  
  local header = string.sub(body, partStart, headerEnd)
  local filename = string.match(header, 'filename="([^"]+)"')
  if not filename or filename == "" then
    return nil, "No file selected."
  end
  
  local ext = string.match(filename, "%.([^%.]+)$")
  if ext then ext = ext:lower() end
  if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" then
    return nil, "Invalid file format. Only PNG, JPG, and JPEG files are allowed."
  end
  
  local fileStart = headerEnd + 4
  local fileEnd = string.find(body, boundaryStr, fileStart, true)
  if not fileEnd then return nil, "Upload payload incomplete." end
  
  local data = string.sub(body, fileStart, fileEnd - 3)
  return data, nil, ext
end

-- GET /home/account/edit
function auth.editPage(req, res)
  local currentUser = session.get(req)
  if not currentUser then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local urlParser = require('url')
  local parsedUrl = urlParser.parse(req.url, true)
  local queryParams = parsedUrl.query or {}
  local successParam = queryParams.success or ""

  -- Query fresh 2FA status
  local userInfo = db.query("SELECT two_factor_enabled FROM users WHERE id = ?", currentUser.id)
  local twofa_enabled = userInfo and userInfo[1] and userInfo[1].two_factor_enabled == 1

  -- Determine alert message based on success param
  local alertDisplay = "none"
  local alertClass = "alert-success"
  local alertTitle = "SUCCESS"
  local alertMessage = ""
  if successParam == "1" then
    alertDisplay = "block"
    alertMessage = "Your avatar has been updated successfully!"
  elseif successParam == "2fa_enabled" then
    alertDisplay = "block"
    alertMessage = "Two-factor authentication has been enabled successfully!"
  elseif successParam == "2fa_disabled" then
    alertDisplay = "block"
    alertMessage = "Two-factor authentication has been disabled."
  end

  local dataContext = {
    title = "Account Settings",
    username = currentUser.username,
    user_id = currentUser.id,
    t = os.time(),
    alert_display = alertDisplay,
    alert_class = alertClass,
    alert_title = alertTitle,
    alert_message = alertMessage,
    twofa_enabled = twofa_enabled,
    twofa_status = twofa_enabled and "Enabled" or "Disabled",
    twofa_badge_class = twofa_enabled and "enabled" or "disabled",
    twofa_btn_display_enable = twofa_enabled and "none" or "block",
    twofa_btn_display_disable = twofa_enabled and "block" or "none"
  }
  
  local success, renderedHtml = pcall(template.render, "edit_account", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Auth] Edit Page Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /home/account/edit
function auth.editSubmit(req, res)
  local currentUser = session.get(req)
  if not currentUser then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local body = readBody(req)
  local contentType = getHeader(req, 'content-type') or ""
  local boundary = contentType:match('boundary="?([^";%s]+)"?')
  
  local fileData, err, ext = parseAvatarUpload(body, boundary)
  
  if not fileData then
    local dataContext = {
      title = "Account Settings",
      username = currentUser.username,
      user_id = currentUser.id,
      t = os.time(),
      alert_display = "block",
      alert_class = "alert-danger",
      alert_title = "ERROR",
      alert_message = err or "Failed to upload avatar."
    }
    local success, renderedHtml = pcall(template.render, "edit_account", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
    return
  end

  -- Max size check (2MB)
  if #fileData > 2 * 1024 * 1024 then
    local dataContext = {
      title = "Account Settings",
      username = currentUser.username,
      user_id = currentUser.id,
      t = os.time(),
      alert_display = "block",
      alert_class = "alert-danger",
      alert_title = "ERROR",
      alert_message = "File is too large. Max size is 2MB."
    }
    local success, renderedHtml = pcall(template.render, "edit_account", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
    return
  end

  local fs = require('fs')
  local targetExt = (ext == "png") and "png" or "jpg"
  local otherExt = (ext == "png") and "jpg" or "png"
  
  local path = string.format("%s/avatars/%s.%s", config.paths.data, currentUser.username, targetExt)
  local otherPath = string.format("%s/avatars/%s.%s", config.paths.data, currentUser.username, otherExt)

  -- Save file
  local co = coroutine.running()
  fs.writeFile(path, fileData, function(writeErr)
    coroutine.resume(co, writeErr)
  end)
  local writeErr = coroutine.yield()

  if writeErr then
    print("[Auth] Error writing avatar: ", writeErr)
    local dataContext = {
      title = "Account Settings",
      username = currentUser.username,
      user_id = currentUser.id,
      t = os.time(),
      alert_display = "block",
      alert_class = "alert-danger",
      alert_title = "ERROR",
      alert_message = "Failed to save avatar image on server."
    }
    local success, renderedHtml = pcall(template.render, "edit_account", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
  else
    -- Delete other format to avoid caching/conflict issues
    fs.unlink(otherPath, function() end)

    res:writeHead(302, { ['Location'] = '/home/account/edit?success=1' })
    res:finish()
  end
end

-- GET /login/2fa
function auth.login2faPage(req, res)
  local user = session.get(req, true)
  if not user or not user.pending_2fa then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local dataContext = {
    title = "Two-Factor Verification",
    error = "",
    error_display = "none"
  }
  local success, renderedHtml = pcall(template.render, "login_2fa", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /login/2fa
function auth.login2faSubmit(req, res)
  local user = session.get(req, true)
  if not user or not user.pending_2fa then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local body = readBody(req)
  local params = querystring.parse(body)
  local totp_code = params.totp_code or ""

  if verifyTOTP(user.two_factor_secret, totp_code) then
    user.pending_2fa = nil
    res:writeHead(302, { ['Location'] = '/' })
    res:finish()
  else
    local dataContext = {
      title = "Two-Factor Verification",
      error = "Invalid verification code. Please try again.",
      error_display = "block"
    }
    local success, renderedHtml = pcall(template.render, "login_2fa", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
  end
end

-- GET /home/account/2fa/setup
function auth.setup2faPage(req, res)
  local currentUser = session.get(req)
  if not currentUser then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local secret = generateSecret()
  local secret_display = secret:sub(1, 4) .. " " .. secret:sub(5, 8) .. " " .. secret:sub(9, 12) .. " " .. secret:sub(13, 16)
  local otpauth_uri = "otpauth://totp/AyanomiBancho:" .. currentUser.username .. "?secret=" .. secret .. "&issuer=AyanomiBancho"

  -- URL-encode the otpauth URI for the QR code API
  local encoded_uri = otpauth_uri:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  local qr_url = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" .. encoded_uri

  local dataContext = {
    title = "Setup Two-Factor Authentication",
    qr_url = qr_url,
    secret_display = secret_display,
    secret_raw = secret,
    error = "",
    error_display = "none"
  }
  local success, renderedHtml = pcall(template.render, "setup_2fa", dataContext)
  if success then
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = tostring(#renderedHtml)
    })
    res:finish(renderedHtml)
  else
    print("[Auth] Setup 2FA Render Error: ", renderedHtml)
    res:writeHead(500, { ['Content-Type'] = 'text/plain' })
    res:finish('500 Internal Server Error')
  end
end

-- POST /home/account/2fa/enable
function auth.enable2faSubmit(req, res)
  local currentUser = session.get(req)
  if not currentUser then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local body = readBody(req)
  local params = querystring.parse(body)
  local totp_code = params.totp_code or ""
  local secret = params.secret or ""

  if verifyTOTP(secret, totp_code) then
    db.query("UPDATE users SET two_factor_enabled = 1, two_factor_secret = ? WHERE id = ?", secret, currentUser.id)
    res:writeHead(302, { ['Location'] = '/home/account/edit?success=2fa_enabled' })
    res:finish()
  else
    -- Re-render setup page with error
    local secret_display = secret:sub(1, 4) .. " " .. secret:sub(5, 8) .. " " .. secret:sub(9, 12) .. " " .. secret:sub(13, 16)
    local otpauth_uri = "otpauth://totp/AyanomiBancho:" .. currentUser.username .. "?secret=" .. secret .. "&issuer=AyanomiBancho"
    local encoded_uri = otpauth_uri:gsub("([^%w%-%.%_%~])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    local qr_url = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=" .. encoded_uri

    local dataContext = {
      title = "Setup Two-Factor Authentication",
      qr_url = qr_url,
      secret_display = secret_display,
      secret_raw = secret,
      error = "Invalid verification code. Please try again.",
      error_display = "block"
    }
    local success, renderedHtml = pcall(template.render, "setup_2fa", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
  end
end

-- POST /home/account/2fa/disable
function auth.disable2faSubmit(req, res)
  local currentUser = session.get(req)
  if not currentUser then
    res:writeHead(302, { ['Location'] = '/login' })
    res:finish()
    return
  end

  local body = readBody(req)
  local params = querystring.parse(body)
  local totp_code = params.totp_code or ""

  local userRow = db.query("SELECT two_factor_secret FROM users WHERE id = ?", currentUser.id)
  local secret = userRow and userRow[1] and userRow[1].two_factor_secret or ""

  if verifyTOTP(secret, totp_code) then
    db.query("UPDATE users SET two_factor_enabled = 0, two_factor_secret = NULL WHERE id = ?", currentUser.id)
    res:writeHead(302, { ['Location'] = '/home/account/edit?success=2fa_disabled' })
    res:finish()
  else
    -- Re-render edit_account with error
    local userInfo = db.query("SELECT two_factor_enabled FROM users WHERE id = ?", currentUser.id)
    local twofa_enabled = userInfo and userInfo[1] and userInfo[1].two_factor_enabled == 1

    local dataContext = {
      title = "Account Settings",
      username = currentUser.username,
      user_id = currentUser.id,
      t = os.time(),
      alert_display = "block",
      alert_class = "alert-danger",
      alert_title = "ERROR",
      alert_message = "Invalid verification code. Could not disable 2FA.",
      twofa_enabled = twofa_enabled,
      twofa_status = twofa_enabled and "Enabled" or "Disabled",
      twofa_badge_class = twofa_enabled and "enabled" or "disabled",
      twofa_btn_display_enable = twofa_enabled and "none" or "block",
      twofa_btn_display_disable = twofa_enabled and "block" or "none"
    }
    local success, renderedHtml = pcall(template.render, "edit_account", dataContext)
    res:writeHead(200, {
      ['Content-Type'] = 'text/html; charset=utf-8',
      ['Content-Length'] = success and tostring(#renderedHtml) or 24
    })
    res:finish(success and renderedHtml or "Internal rendering error")
  end
end

return auth

