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
  return req.headers[name:lower()] or req.headers[name]
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

  local errStr = ""

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
  local username = params.username or ""
  local password = params.password or ""

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
    loginFailures[ip] = nil
    local sid = session.create(user)
    res:writeHead(302, {
      ['Location'] = '/',
      ['Set-Cookie'] = "sid=" .. sid .. "; Path=/; HttpOnly"
    })
    res:finish()
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
  local _, sid = session.get(req)
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
  local contentType = req.headers['content-type'] or ""
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
  local successMsg = queryParams.success == "1"

  local dataContext = {
    title = "Account Settings",
    username = currentUser.username,
    user_id = currentUser.id,
    alert_display = successMsg and "block" or "none",
    alert_class = "alert-success",
    alert_title = "SUCCESS",
    alert_message = "Your avatar has been updated successfully!"
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
  local contentType = req.headers['content-type'] or ""
  local boundary = contentType:match('boundary="?([^";%s]+)"?')
  
  local fileData, err, ext = parseAvatarUpload(body, boundary)
  
  if not fileData then
    local dataContext = {
      title = "Account Settings",
      username = currentUser.username,
      user_id = currentUser.id,
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

return auth

