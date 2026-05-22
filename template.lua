-- template.lua
-- High-performance, lightweight HTML Template Engine with Hot-reload for AyanomiBancho

local fs = require('fs')
local pathJoin = require('path').join
local config = require('./config')

local template = {}
local templateCache = {}

-- Helper to read file asynchronously
local function readFileAsync(path)
  local co = coroutine.running()
  fs.readFile(path, function(err, data)
    local success, resumeErr = coroutine.resume(co, err, data)
    if not success then
      print("[Template Error] Resume failed: ", debug.traceback(co, resumeErr))
      error(resumeErr)
    end
  end)
  return coroutine.yield()
end

-- Resolve nested dot-notation paths in data table (e.g. "user.stats.pp")
local function resolvePath(data, path)
  local current = data
  for segment in string.gmatch(path, "[%w_]+") do
    if type(current) == "table" then
      current = current[segment]
    else
      return nil
    end
  end
  return current
end

-- Process template string and render it with provided data context (double curly braces {{var}})
local function renderString(tmplStr, data)
  local rendered = string.gsub(tmplStr, "{{%s*([%w_%.]+)%s*}}", function(path)
    local val = resolvePath(data, path)
    return val ~= nil and tostring(val) or ""
  end)
  return rendered
end

template.currentRequests = setmetatable({}, { __mode = "k" })

-- Read and compile an HTML template, supporting layout inheritance
function template.render(templateName, data)
  local co = coroutine.running()
  local req = template.currentRequests[co]
  if req then
    local newData = {}
    if data then
      for k, v in pairs(data) do
        newData[k] = v
      end
    end
    newData.user_nav = req.user_nav or ""
    data = newData
  end

  local templatePath = pathJoin(config.paths.templates, templateName .. ".html")

  -- Read from cache or load from disk asynchronously
  local tmplContent = templateCache[templateName]
  if not tmplContent then
    local err, content = readFileAsync(templatePath)
    if err then
      error("[Template] Failed to read template: " .. templatePath .. " (" .. tostring(err) .. ")")
    end
    tmplContent = content
    templateCache[templateName] = tmplContent
  end

  -- Look for layout declaration: <!-- layout: layout_name -->
  local layoutName = string.match(tmplContent, "<!%-%-%s*layout:%s*([%w_]+)%s*%-%->")
  
  if layoutName then
    -- Strip the layout tag from the template content
    local contentBody = string.gsub(tmplContent, "<!%-%-%s*layout:%s*([%w_]+)%s*%-%->", "")
    
    -- Load and render the layout template
    local layoutPath = pathJoin(config.paths.templates, layoutName .. ".html")
    local layoutContent = templateCache[layoutName]
    if not layoutContent then
      local err, content = readFileAsync(layoutPath)
      if err then
        error("[Template] Failed to read layout template: " .. layoutPath .. " (" .. tostring(err) .. ")")
      end
      layoutContent = content
      templateCache[layoutName] = layoutContent
    end

    -- Render the page body template contents first
    local renderedBody = renderString(contentBody, data)

    -- Inject rendered body into the layout's {{body}} placeholder
    local fullRenderedPage = string.gsub(layoutContent, "{{%s*body%s*}}", renderedBody)

    -- Finally, render all variables inside the full layout context
    return renderString(fullRenderedPage, data)
  else
    -- Simple standalone page template
    return renderString(tmplContent, data)
  end
end

-- Monitor template folder for hot-reload
function template.initHotReload()
  local dir = config.paths.templates
  print("[Template] Initializing Hot-Reload watcher on: " .. dir)
  
  -- Create template dir if it doesn't exist
  fs.mkdir(dir, 511, function()
    local uv = require('uv')
    local fs_event = uv.new_fs_event()
    fs_event:start(dir, {}, function(err, filename, events)
      if err then
        print("[Template] Watcher error: " .. tostring(err))
        return
      end
      if filename then
        local name = string.match(filename, "^(.-)%.html$")
        if name then
          print(string.format("[Template] File change detected: %s. Clearing cache.", filename))
          templateCache[name] = nil
        end
      end
    end)
  end)
end

-- Initialize hot-reload watch loop
template.initHotReload()

return template
