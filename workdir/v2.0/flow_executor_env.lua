-- wrk2 flow executor (env-driven, no response parsing)
-- Requires cjson module available to wrk's Lua runtime.

local ok_cjson, cjson = pcall(require, "cjson.safe")
if not ok_cjson then
  local ok2, cjson2 = pcall(require, "cjson")
  if ok2 then
    cjson = cjson2
  else
    error("cjson not available; install lua-cjson or switch to pre-generated .lua artifacts")
  end
end

local threads = {}
local setup_thread_counter = 0
local thread_id = 0

local data_dir = os.getenv("FLOW_DATA_DIR") or "workdir/v1.0/data"
local stage = os.getenv("FLOW_STAGE") or "lifecycle"
local api_prefix = os.getenv("FLOW_API_PREFIX") or "/petclinic/api"
local reuse_mode = os.getenv("FLOW_REUSE_MODE") or "wrap" -- wrap | stop
local fail_on_non2xx = (os.getenv("FLOW_FAIL_ON_NON2XX") or "1") == "1"
local log_every = tonumber(os.getenv("FLOW_LOG_EVERY") or "0") or 0

local iterations = {}
local conn_state = {}

local base_headers = {}
local idle_request = nil

local function list_iteration_files(dir)
    local cmd = "ls -1 " .. dir .. "/iteration-*.json 2>/dev/null | sort"
    local p = io.popen(cmd)
    if not p then
        return {}
    end
    local out = {}
    for line in p:lines() do
        if line ~= "" then
        out[#out + 1] = line
        end
    end
    p:close()
    return out
end

local function read_all(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local txt = f:read("*a")
  f:close()
  return txt, nil
end

local function load_iterations()
  local stage_dir = data_dir .. "/" .. stage
  local files = list_iteration_files(stage_dir)
  if #files == 0 then
    error("No iteration files found in: " .. stage_dir)
  end

  local out = {}
  for _, fp in ipairs(files) do
    local txt, err = read_all(fp)
    if not txt then
      error("Failed reading " .. fp .. ": " .. tostring(err))
    end
    local obj, jerr = cjson.decode(txt)
    if not obj then
      error("Bad JSON in " .. fp .. ": " .. tostring(jerr))
    end
    if type(obj.steps) ~= "table" or #obj.steps == 0 then
      error("No steps in " .. fp)
    end
    out[#out + 1] = obj
  end

  return out
end

local function ensure_conn(conn_id)
  local st = conn_state[conn_id]
  if st then
    return st
  end

  st = {
    iter_index = nil,
    step_index = 1,
    next_iter_seed = conn_id + 1, -- 1-based
    current_req = nil,
    sent = 0,
    ok = 0,
    failed = 0,
  }
  conn_state[conn_id] = st
  return st
end

local function claim_iteration(st)
  local total = #iterations
  if total == 0 then
    return false
  end

  local idx = st.next_iter_seed
  if idx > total then
    if reuse_mode == "wrap" then
      idx = ((idx - 1) % total) + 1
    else
      return false
    end
  end

  st.iter_index = idx
  st.step_index = 1
  st.current_req = nil

  -- stride by configured connections if available, else by 1
  local stride = tonumber(wrk.connections) or 1
  if stride < 1 then stride = 1 end
  st.next_iter_seed = st.next_iter_seed + stride
  return true
end

local function is_success(status)
  return status >= 200 and status < 300
end

local function build_step_request(conn_id, st)
  if st.iter_index == nil then
    local ok = claim_iteration(st)
    if not ok then
      return idle_request
    end
  end

  local iter = iterations[st.iter_index]
  local step = iter.steps[st.step_index]
  if not step then
    -- iteration complete; move to next on next call
    st.iter_index = nil
    st.step_index = 1
    return idle_request
  end

  local method = tostring(step.method or "GET")
  local path = step.resolvedPath or step.pathTemplate or "/"
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  path = api_prefix .. path

  local headers = {
    ["Host"] = base_headers["Host"],
    ["Accept"] = base_headers["Accept"],
  }

  local body = nil
  if step.requestBody ~= nil and method ~= "GET" and method ~= "DELETE" then
    body = cjson.encode(step.requestBody)
    headers["Content-Type"] = "application/json"
  end

  st.current_req = {
    conn_id = conn_id,
    iter_index = st.iter_index,
    step_index = st.step_index,
    flow_id = tostring(step.flowId or "unknown"),
    method = method,
    path = path,
  }

  st.sent = st.sent + 1
  return wrk.format(method, path, headers, body)
end

function setup(thread)
  setup_thread_counter = setup_thread_counter + 1
  thread:set("flow_thread_id", setup_thread_counter)
  threads[#threads + 1] = thread
end

function init(args)
  local host = wrk.host
  local port = wrk.port
  host = host:find(":") and ("[" .. host .. "]") or host
  host = port and (host .. ":" .. port) or host
  base_headers["Host"] = host
  base_headers["Accept"] = "application/json"

  thread_id = tonumber(flow_thread_id) or 0
  iterations = load_iterations()
  idle_request = wrk.format("GET", api_prefix .. "/owners", base_headers, nil)

  _G.fe_sent = 0
  _G.fe_ok = 0
  _G.fe_failed = 0
  _G.fe_pairs = 0
end

function request(conn_id)
  local st = ensure_conn(conn_id)
  return build_step_request(conn_id, st)
end

function response(status, headers, body, conn_id)
  local st = conn_state[conn_id]
  if not st or not st.current_req then
    return
  end

  -- request/response pair tracked here
  _G.fe_pairs = (_G.fe_pairs or 0) + 1
  _G.fe_sent = (_G.fe_sent or 0) + 1

  if is_success(status) then
    st.ok = st.ok + 1
    _G.fe_ok = (_G.fe_ok or 0) + 1
    st.step_index = st.step_index + 1
    local iter = iterations[st.iter_index]
    if iter and st.step_index > #iter.steps then
      st.iter_index = nil
      st.step_index = 1
    end
  else
    st.failed = st.failed + 1
    _G.fe_failed = (_G.fe_failed or 0) + 1
    if fail_on_non2xx then
      st.iter_index = nil
      st.step_index = 1
    else
      st.step_index = st.step_index + 1
    end
  end

  if log_every > 0 and ((_G.fe_pairs or 0) % log_every == 0) then
    print(string.format(
      "pair thread=%d conn=%d iter=%s step=%s flow=%s %s %s status=%d body_len=%d",
      thread_id,
      conn_id,
      tostring(st.current_req.iter_index),
      tostring(st.current_req.step_index),
      tostring(st.current_req.flow_id),
      tostring(st.current_req.method),
      tostring(st.current_req.path),
      tonumber(status) or -1,
      body and #body or 0
    ))
  end

  st.current_req = nil
end

function done(summary, latency, requests)
  local sent, ok, failed, pairs = 0, 0, 0, 0
  for _, t in ipairs(threads) do
    sent = sent + (t:get("fe_sent") or 0)
    ok = ok + (t:get("fe_ok") or 0)
    failed = failed + (t:get("fe_failed") or 0)
    pairs = pairs + (t:get("fe_pairs") or 0)
  end

  print("")
  print("--- flow_executor_env ---")
  print("stage: " .. stage)
  print("data_dir: " .. data_dir)
  print(string.format("pairs_tracked: %d", pairs))
  print(string.format("requests_sent: %d", sent))
  print(string.format("responses_2xx: %d", ok))
  print(string.format("responses_non2xx: %d", failed))
end