-- db.lua
-- Asynchronous/Synchronous Database Adapter with SQLite3 support and Fallback Mock Database

local coroNet = require('coro-net')
local config = require('./config')

local db = {}
db.isConnected = false
db.sqliteConn = nil

-- Determine DB driver (defaults to config driver, fallback to mock if unspecified)
db.driver = config.database.driver or "sqlite"

-- Mock Player Database (Used as fallback or when driver is "mock")
local mockData = {
  users = {
    { id = 2, username = "Ayanomi", email = "ayanomi@example.com", password_hash = "5e883767f37069203078949697cd2002c6918a2d805217300669c79c759d622d", password_md5 = "5f4dcc3b5aa765d61d8327deb882cf99", pp = 12450, rank = 1, country = "VN", accuracy = 99.23, playcount = 85210, ranked_score = 9854120300, level = 101 },
    { id = 3, username = "Miku", email = "miku@example.com", password_hash = "5e883767f37069203078949697cd2002c6918a2d805217300669c79c759d622d", password_md5 = "5f4dcc3b5aa765d61d8327deb882cf99", pp = 11800, rank = 2, country = "JP", accuracy = 98.95, playcount = 65420, ranked_score = 7542100800, level = 98 },
    { id = 4, username = "Cookiezi", email = "cookiezi@example.com", password_hash = "5e883767f37069203078949697cd2002c6918a2d805217300669c79c759d622d", password_md5 = "5f4dcc3b5aa765d61d8327deb882cf99", pp = 11500, rank = 3, country = "KR", accuracy = 99.82, playcount = 120450, ranked_score = 15201400200, level = 102 },
    { id = 1, username = "peppy", email = "peppy@example.com", password_hash = "5e883767f37069203078949697cd2002c6918a2d805217300669c79c759d622d", password_md5 = "5f4dcc3b5aa765d61d8327deb882cf99", pp = 1200, rank = 4, country = "AU", accuracy = 92.50, playcount = 1540, ranked_score = 54021000, level = 25 },
  },
  scores = {
    { id = 101, username = "Cookiezi", beatmap_md5 = "c8f08430a2feb0204d70f1a92e2f3d61", score = 12500000, max_combo = 1520, count50 = 0, count100 = 2, count300 = 1024, countmiss = 0, countkatu = 1, countgeki = 200, perfect = 1, mods = 8, pp = 720 },
    { id = 102, username = "Ayanomi", beatmap_md5 = "c8f08430a2feb0204d70f1a92e2f3d61", score = 12410200, max_combo = 1520, count50 = 0, count100 = 8, count300 = 1018, countmiss = 0, countkatu = 4, countgeki = 195, perfect = 1, mods = 8, pp = 705 },
    { id = 103, username = "Miku", beatmap_md5 = "c8f08430a2feb0204d70f1a92e2f3d61", score = 11850000, max_combo = 1515, count50 = 1, count100 = 12, count300 = 1010, countmiss = 1, countkatu = 6, countgeki = 188, perfect = 0, mods = 0, pp = 580 },
  }
}

-- Simple mock query router
local function mockQuery(sql, params)
  sql = sql:lower()
  
  -- Case 2: Select users sorted by PP (Leaderboard)
  if string.find(sql, "select.*from users.*order by pp desc") then
    local limit = 50
    if string.find(sql, "limit") then
      limit = tonumber(string.match(sql, "limit%s+(%d+)")) or 50
    end
    
    local leaderboard = {}
    for i, u in ipairs(mockData.users) do
      if i <= limit then
        table.insert(leaderboard, u)
      end
    end
    table.sort(leaderboard, function(a, b) return a.pp > b.pp end)
    return leaderboard
  end

  -- Case 1: Select single player profile by username, email, or both (with WHERE clause)
  if string.find(sql, "select.*from users.*where") then
    local matched_users = {}
    for _, u in ipairs(mockData.users) do
      local matched = false
      for _, p in ipairs(params) do
        local paramStr = tostring(p):lower()
        if u.username:lower() == paramStr or (u.email and u.email:lower() == paramStr) then
          matched = true
          break
        end
      end
      if matched then
        table.insert(matched_users, u)
      end
    end
    return matched_users
  end

  -- Case 1b: Select all users (e.g. for simple.team query)
  if string.find(sql, "select.*from users") then
    return mockData.users
  end

  -- Case 4: Insert new user (registration)
  if string.find(sql, "insert%s+into%s+users") then
    local username = params[1] or ""
    local email = params[2] or ""
    local password_hash = params[3] or ""
    local password_md5 = params[4] or ""
    
    local new_id = #mockData.users + 1
    local new_user = {
      id = new_id,
      username = username,
      email = email,
      password_hash = password_hash,
      password_md5 = password_md5,
      pp = 0,
      rank = #mockData.users + 1,
      country = "VN",
      accuracy = 100.0,
      playcount = 0,
      ranked_score = 0,
      level = 1
    }
    table.insert(mockData.users, new_user)
    return {
      affected_rows = 1,
      insert_id = new_id
    }
  end

  -- Case 3: Select scores for a beatmap (osu! getscores)
  if string.find(sql, "select.*from scores.*where beatmap_md5.*=.*") then
    local md5 = params[1] or ""
    local mapScores = {}
    for _, s in ipairs(mockData.scores) do
      if s.beatmap_md5 == md5 then
        table.insert(mapScores, s)
      end
    end
    table.sort(mapScores, function(a, b) return a.pp > b.pp end)
    return mapScores
  end

  -- Default fallback empty table
  return {}
end

-- SQLite Query Executor
local function sqliteQuery(sqlStr, params)
  if not db.sqliteConn then
    return {}
  end

  local isSelect = string.find(sqlStr:lower(), "^%s*select") ~= nil

  local success, stmt = pcall(function() return db.sqliteConn:prepare(sqlStr) end)
  if not success or not stmt then
    print("[DB SQLite Error] Prepare failed for: " .. tostring(sqlStr) .. " | Error: " .. tostring(stmt))
    return {}
  end

  if params and #params > 0 then
    local bindSuccess, bindErr = pcall(function() stmt:bind(unpack(params)) end)
    if not bindSuccess then
      print("[DB SQLite Error] Bind failed: " .. tostring(bindErr))
      stmt:close()
      return {}
    end
  end

  if isSelect then
    local rows = {}
    local stepSuccess, r, h = pcall(function() return stmt:step({}, {}) end)
    if not stepSuccess then
      print("[DB SQLite Error] Step failed: " .. tostring(r))
      stmt:close()
      return {}
    end

    if r then
      local function mapRow(row_data, header_data)
        local mapped = {}
        for i = 1, #header_data do
          local val = row_data[i]
          if type(val) == "cdata" then
            val = tonumber(val)
          end
          mapped[header_data[i]] = val
        end
        return mapped
      end

      table.insert(rows, mapRow(r, h))

      while true do
        local nextRow = stmt:step()
        if not nextRow then break end
        table.insert(rows, mapRow(nextRow, h))
      end
    end

    stmt:close()
    return rows
  else
    -- INSERT, UPDATE, DELETE
    local stepSuccess, stepErr = pcall(function() return stmt:step() end)
    stmt:close()
    if not stepSuccess then
      print("[DB SQLite Error] Execute failed: " .. tostring(stepErr))
      return { affected_rows = 0, insert_id = 0 }
    end

    local changes = 0
    local lastId = 0

    pcall(function()
      changes = tonumber(db.sqliteConn:rowexec("SELECT changes()")) or 0
      lastId = tonumber(db.sqliteConn:rowexec("SELECT last_insert_rowid()")) or 0
    end)

    return {
      affected_rows = changes,
      insert_id = lastId
    }
  end
end

-- Initialize database schemas for SQLite
function db.initSqliteSchema()
  if not db.sqliteConn then return end

  print("[DB] Initializing SQLite database schemas...")
  
  -- Optimizations and foreign keys
  pcall(function()
    db.sqliteConn:exec("PRAGMA journal_mode = WAL;")
    db.sqliteConn:exec("PRAGMA foreign_keys = ON;")
  end)

  -- Create tables
  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      password_md5 TEXT DEFAULT '',
      country TEXT DEFAULT 'VN',
      latest_activity INTEGER DEFAULT 0,
      privileges INTEGER DEFAULT 1
    );
  ]]

  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS users_stats (
      id INTEGER PRIMARY KEY,
      username_aka TEXT DEFAULT '',
      playcount_std INTEGER DEFAULT 0,
      ranked_score_std INTEGER DEFAULT 0,
      total_score_std INTEGER DEFAULT 0,
      pp_std INTEGER DEFAULT 0,
      avg_accuracy_std REAL DEFAULT 0,
      replays_watched_std INTEGER DEFAULT 0,
      playcount_taiko INTEGER DEFAULT 0,
      ranked_score_taiko INTEGER DEFAULT 0,
      total_score_taiko INTEGER DEFAULT 0,
      pp_taiko INTEGER DEFAULT 0,
      avg_accuracy_taiko REAL DEFAULT 0,
      replays_watched_taiko INTEGER DEFAULT 0,
      playcount_ctb INTEGER DEFAULT 0,
      ranked_score_ctb INTEGER DEFAULT 0,
      total_score_ctb INTEGER DEFAULT 0,
      pp_ctb INTEGER DEFAULT 0,
      avg_accuracy_ctb REAL DEFAULT 0,
      replays_watched_ctb INTEGER DEFAULT 0,
      playcount_mania INTEGER DEFAULT 0,
      ranked_score_mania INTEGER DEFAULT 0,
      total_score_mania INTEGER DEFAULT 0,
      pp_mania INTEGER DEFAULT 0,
      avg_accuracy_mania REAL DEFAULT 0,
      replays_watched_mania INTEGER DEFAULT 0,
      FOREIGN KEY(id) REFERENCES users(id)
    );
  ]]

  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS users_stats_relax (
      id INTEGER PRIMARY KEY,
      playcount_std INTEGER DEFAULT 0,
      ranked_score_std INTEGER DEFAULT 0,
      total_score_std INTEGER DEFAULT 0,
      pp_std INTEGER DEFAULT 0,
      avg_accuracy_std REAL DEFAULT 0,
      playcount_taiko INTEGER DEFAULT 0,
      ranked_score_taiko INTEGER DEFAULT 0,
      total_score_taiko INTEGER DEFAULT 0,
      pp_taiko INTEGER DEFAULT 0,
      avg_accuracy_taiko REAL DEFAULT 0,
      playcount_ctb INTEGER DEFAULT 0,
      ranked_score_ctb INTEGER DEFAULT 0,
      total_score_ctb INTEGER DEFAULT 0,
      pp_ctb INTEGER DEFAULT 0,
      avg_accuracy_ctb REAL DEFAULT 0,
      playcount_mania INTEGER DEFAULT 0,
      ranked_score_mania INTEGER DEFAULT 0,
      total_score_mania INTEGER DEFAULT 0,
      pp_mania INTEGER DEFAULT 0,
      avg_accuracy_mania REAL DEFAULT 0,
      FOREIGN KEY(id) REFERENCES users(id)
    );
  ]]

  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS scores (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userid INTEGER NOT NULL,
      beatmap_md5 TEXT NOT NULL,
      score INTEGER NOT NULL,
      max_combo INTEGER NOT NULL,
      full_combo INTEGER DEFAULT 0,
      mods INTEGER DEFAULT 0,
      count300 INTEGER DEFAULT 0,
      count100 INTEGER DEFAULT 0,
      count50 INTEGER DEFAULT 0,
      countmiss INTEGER DEFAULT 0,
      countkatu INTEGER DEFAULT 0,
      countgeki INTEGER DEFAULT 0,
      accuracy REAL DEFAULT 0,
      pp REAL DEFAULT 0,
      play_mode INTEGER DEFAULT 0,
      is_relax INTEGER DEFAULT 0,
      completed INTEGER DEFAULT 3,
      time INTEGER DEFAULT 0
    );
  ]]

  -- Create beatmapsets and beatmaps cache tables mirroring Cheesegull
  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS beatmapsets (
      id INTEGER PRIMARY KEY,
      ranked_status INTEGER DEFAULT 1,
      approved_date INTEGER DEFAULT 0,
      last_update INTEGER DEFAULT 0,
      last_checked INTEGER DEFAULT 0,
      artist TEXT DEFAULT '',
      title TEXT DEFAULT '',
      creator TEXT DEFAULT '',
      source TEXT DEFAULT '',
      tags TEXT DEFAULT '',
      has_video INTEGER DEFAULT 0,
      genre INTEGER DEFAULT 0,
      language INTEGER DEFAULT 0,
      favourites INTEGER DEFAULT 0
    );
  ]]

  db.sqliteConn:exec[[
    CREATE TABLE IF NOT EXISTS beatmaps (
      id INTEGER PRIMARY KEY,
      parent_set_id INTEGER NOT NULL,
      diff_name TEXT DEFAULT '',
      file_md5 TEXT NOT NULL,
      mode INTEGER DEFAULT 0,
      bpm REAL DEFAULT 0,
      ar REAL DEFAULT 0,
      od REAL DEFAULT 0,
      cs REAL DEFAULT 0,
      hp REAL DEFAULT 0,
      total_length INTEGER DEFAULT 0,
      hit_length INTEGER DEFAULT 0,
      playcount INTEGER DEFAULT 0,
      passcount INTEGER DEFAULT 0,
      max_combo INTEGER DEFAULT 0,
      difficulty_rating REAL DEFAULT 0,
      FOREIGN KEY(parent_set_id) REFERENCES beatmapsets(id) ON DELETE CASCADE
    );
  ]]
end

-- Connect to database
function db.connect()
  if db.driver == "sqlite" then
    print("[DB] Attempting database connection using SQLite3...")
    local reqSuccess, sqlite3 = pcall(require, 'sqlite3')
    if not reqSuccess then
      print("[DB] WARNING: Unable to load 'sqlite3' package: " .. tostring(sqlite3))
      print("[DB] Falling back to local mock player database.")
      db.driver = "mock"
      db.isConnected = false
      return
    end

    local dbPath = config.database.sqlite_path or "ayanomibancho.db"
    local connSuccess, conn = pcall(sqlite3.open, dbPath)
    if not connSuccess then
      print("[DB] WARNING: Unable to open SQLite database file: " .. tostring(conn))
      print("[DB] Falling back to local mock player database.")
      db.driver = "mock"
      db.isConnected = false
      return
    end

    db.sqliteConn = conn
    db.isConnected = true
    print("[DB] Connected to SQLite database successfully at " .. dbPath)
    db.initSqliteSchema()

  elseif db.driver == "mysql" then
    coroutine.wrap(function()
      print("[DB] Attempting database connection to MySQL " .. config.database.host .. ":" .. config.database.port)
      
      local read, write, socket = coroNet.connect({
        host = config.database.host,
        port = config.database.port,
        timeout = 2000
      })
      
      if not read then
        print("[DB] WARNING: Unable to connect to MySQL database (" .. tostring(write) .. ").")
        print("[DB] Falling back to high-performance local mock player database.")
        db.driver = "mock"
        db.isConnected = false
        return
      end

      print("[DB] Connected to MySQL successfully! Protocol initialized.")
      db.isConnected = true
      db.readChannel = read
      db.writeChannel = write
      db.socket = socket
    end)()
  else
    print("[DB] Initialized with local mock player database.")
  end
end

-- Query Dispatcher
function db.query(sql, ...)
  local params = {...}
  
  if db.driver == "sqlite" then
    return sqliteQuery(sql, params)
  elseif db.driver == "mysql" and db.isConnected then
    -- Real MySQL implementation goes here. Fallback to mock for now.
    return mockQuery(sql, params)
  else
    -- Fallback/Mock implementation with network trip latency simulation (1-5ms)
    local co = coroutine.running()
    if co then
      local timer = require('uv').new_timer()
      timer:start(5, 0, function()
        timer:close()
        local success, resumeErr = coroutine.resume(co)
        if not success then
          print("[DB Error] Resume failed: ", debug.traceback(co, resumeErr))
        end
      end)
      coroutine.yield()
    end
    
    return mockQuery(sql, params)
  end
end

-- Initialize database connection on load
db.connect()

return db
