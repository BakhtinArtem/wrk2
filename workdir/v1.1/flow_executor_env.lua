--[[
  wrk2 flow executor for static v1.0 iterations.

  Keeps v1 static-data model (no template resolution), but aligns scheduler
  and reporting behavior with v2.

  Environment variables:
    FLOW_DATA_DIR        default: workdir/v1.0/data
    FLOW_STAGE           default: lifecycle
    FLOW_API_PREFIX      default: /petclinic/api
    FLOW_REUSE_MODE      default: wrap   (wrap | stop)
    FLOW_FAIL_ON_NON2XX  default: 1      (1 | 0)
    FLOW_LOG_EVERY       default: 0      (print every N responses)
    FLOW_IDLE_PATH       default: /owners
]]
---@diagnostic disable: undefined-global

local ok_cjson, cjson = pcall(require, "cjson.safe")
if not ok_cjson then
  local ok2, cjson2 = pcall(require, "cjson")
  if ok2 then
    cjson = cjson2
  else
    error("cjson not available; install lua-cjson")
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
local idle_path = os.getenv("FLOW_IDLE_PATH") or "/owners"

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

local function decode_json(text)
  local ok, obj = pcall(cjson.decode, text)
  if ok then
    return obj, nil
  end
  return nil, tostring(obj)
end

local function encode_json(value)
  local ok, out = pcall(cjson.encode, value)
  if ok then
    return out, nil
  end
  return nil, tostring(out)
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
    local obj, jerr = decode_json(txt)
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

local function shallow_copy(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

local function append_query(path, query)
  if type(query) ~= "table" then
    return path
  end
  local parts = {}
  for k, v in pairs(query) do
    if v ~= nil then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  if #parts == 0 then
    return path
  end
  table.sort(parts)
  return path .. "?" .. table.concat(parts, "&")
end

local function with_api_prefix(path)
  local p = tostring(path or "/")
  if p:sub(1, 1) ~= "/" then
    p = "/" .. p
  end
  if api_prefix == "" then
    return p
  end
  if api_prefix:sub(-1) == "/" and p:sub(1, 1) == "/" then
    return api_prefix:sub(1, -2) .. p
  end
  if api_prefix:sub(-1) ~= "/" and p:sub(1, 1) ~= "/" then
    return api_prefix .. "/" .. p
  end
  return api_prefix .. p
end

local function make_idle_request()
  local h = shallow_copy(base_headers)
  return wrk.format("GET", with_api_prefix(idle_path), h, nil)
end

local function init_runtime_counters()
  _G.v1_requests_issued = 0
  _G.v1_pairs = 0
  _G.v1_responses_2xx = 0
  _G.v1_responses_non2xx = 0
  _G.v1_iterations_started = 0
  _G.v1_iterations_completed = 0
  _G.v1_iterations_failed = 0
  _G.v1_iterations_exhausted = 0
  _G.v1_encode_failures = 0
  _G.v1_stage = stage
  _G.v1_data_dir = data_dir
end

local function ensure_conn_state(conn_id)
  local st = conn_state[conn_id]
  if st then
    return st
  end
  st = {
    iteration_index = nil,
    step_index = 1,
    next_iteration_seed = conn_id + 1, -- 1-based
    current_step = nil,
    exhausted = false,
  }
  conn_state[conn_id] = st
  return st
end

local function claim_next_iteration(st)
  if st.exhausted then
    return false
  end
  local total = #iterations
  if total == 0 then
    st.exhausted = true
    _G.v1_iterations_exhausted = _G.v1_iterations_exhausted + 1
    return false
  end

  local idx = st.next_iteration_seed
  if idx > total then
    if reuse_mode == "wrap" then
      idx = ((idx - 1) % total) + 1
    else
      st.exhausted = true
      _G.v1_iterations_exhausted = _G.v1_iterations_exhausted + 1
      return false
    end
  end

  st.iteration_index = idx
  st.step_index = 1
  st.current_step = nil

  local stride = tonumber(wrk.connections) or 1
  if stride < 1 then
    stride = 1
  end
  st.next_iteration_seed = st.next_iteration_seed + stride
  _G.v1_iterations_started = _G.v1_iterations_started + 1
  return true
end

local function complete_iteration(st)
  _G.v1_iterations_completed = _G.v1_iterations_completed + 1
  st.iteration_index = nil
  st.step_index = 1
  st.current_step = nil
end

local function fail_iteration(st)
  _G.v1_iterations_failed = _G.v1_iterations_failed + 1
  st.iteration_index = nil
  st.step_index = 1
  st.current_step = nil
end

local function build_request_for_state(st)
  local iter = iterations[st.iteration_index]
  local step = iter and iter.steps and iter.steps[st.step_index]
  if not step then
    complete_iteration(st)
    return nil
  end

  local method = tostring(step.method or "GET")
  local path = step.resolvedPath or step.pathTemplate or "/"
  path = append_query(path, step.query)
  path = with_api_prefix(path)

  local headers = shallow_copy(base_headers)
  for k, v in pairs(step.headers or {}) do
    headers[tostring(k)] = tostring(v)
  end

  local body_text = nil
  if step.requestBody ~= nil and method ~= "GET" and method ~= "HEAD" then
    local encoded, encode_err = encode_json(step.requestBody)
    if not encoded then
      _G.v1_encode_failures = _G.v1_encode_failures + 1
      fail_iteration(st)
      return nil
    end
    body_text = encoded
    if headers["Content-Type"] == nil then
      headers["Content-Type"] = "application/json"
    end
  end

  st.current_step = {
    flow_id = tostring(step.flowId or "unknown"),
    method = method,
    path = path,
    iteration_index = st.iteration_index,
    step_index = st.step_index,
  }

  _G.v1_requests_issued = _G.v1_requests_issued + 1
  return wrk.format(method, path, headers, body_text)
end

local function request_with_retries(conn_id, retries)
  local st = ensure_conn_state(conn_id)
  if st.iteration_index == nil then
    local ok = claim_next_iteration(st)
    if not ok then
      return idle_request
    end
  end
  for _ = 1, retries do
    local req = build_request_for_state(st)
    if req then
      return req
    end
    if st.exhausted then
      return idle_request
    end
    if st.iteration_index == nil then
      local ok = claim_next_iteration(st)
      if not ok then
        return idle_request
      end
    end
  end
  return idle_request
end

local function is_success_status(status)
  return status >= 200 and status < 300
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

  thread_id = tonumber(flow_thread_id) or 0
  base_headers["Host"] = host
  base_headers["Accept"] = "application/json"
  iterations = load_iterations()
  idle_request = make_idle_request()
  init_runtime_counters()

  print(string.format("flow_executor_env stage=%s iterations=%d", stage, #iterations))
end

function request(conn_id)
  return request_with_retries(conn_id, 3)
end

function response(status, headers, body, conn_id)
  local st = conn_state[conn_id]
  if not st or st.iteration_index == nil or not st.current_step then
    return
  end

  _G.v1_pairs = _G.v1_pairs + 1
  if is_success_status(status) then
    _G.v1_responses_2xx = _G.v1_responses_2xx + 1
    st.step_index = st.step_index + 1
    local iter = iterations[st.iteration_index]
    if iter and st.step_index > #iter.steps then
      complete_iteration(st)
    end
  else
    _G.v1_responses_non2xx = _G.v1_responses_non2xx + 1
    if fail_on_non2xx then
      fail_iteration(st)
    else
      st.step_index = st.step_index + 1
      local iter = iterations[st.iteration_index]
      if iter and st.step_index > #iter.steps then
        complete_iteration(st)
      end
    end
  end

  if log_every > 0 and (_G.v1_pairs % log_every == 0) then
    print(string.format(
      "flow_pair thread=%d conn=%d iter=%s step=%s flow=%s method=%s path=%s status=%d",
      thread_id,
      conn_id,
      tostring(st.current_step.iteration_index),
      tostring(st.current_step.step_index),
      tostring(st.current_step.flow_id),
      tostring(st.current_step.method),
      tostring(st.current_step.path),
      tonumber(status) or -1
    ))
  end

  st.current_step = nil
end

function done(summary, latency, requests)
  local out = {
    requests_issued = 0,
    pairs = 0,
    responses_2xx = 0,
    responses_non2xx = 0,
    iterations_started = 0,
    iterations_completed = 0,
    iterations_failed = 0,
    iterations_exhausted = 0,
    encode_failures = 0,
  }
  local stage_name = nil
  local data_root = nil

  for _, t in ipairs(threads) do
    out.requests_issued = out.requests_issued + (t:get("v1_requests_issued") or 0)
    out.pairs = out.pairs + (t:get("v1_pairs") or 0)
    out.responses_2xx = out.responses_2xx + (t:get("v1_responses_2xx") or 0)
    out.responses_non2xx = out.responses_non2xx + (t:get("v1_responses_non2xx") or 0)
    out.iterations_started = out.iterations_started + (t:get("v1_iterations_started") or 0)
    out.iterations_completed = out.iterations_completed + (t:get("v1_iterations_completed") or 0)
    out.iterations_failed = out.iterations_failed + (t:get("v1_iterations_failed") or 0)
    out.iterations_exhausted = out.iterations_exhausted + (t:get("v1_iterations_exhausted") or 0)
    out.encode_failures = out.encode_failures + (t:get("v1_encode_failures") or 0)
    if not stage_name then
      stage_name = t:get("v1_stage")
    end
    if not data_root then
      data_root = t:get("v1_data_dir")
    end
  end

  print("")
  print("--- flow_executor_env ---")
  print(string.format("stage: %s", tostring(stage_name or stage)))
  print(string.format("data_dir: %s", tostring(data_root or data_dir)))
  print(string.format("requests_issued: %d", out.requests_issued))
  print(string.format("pairs_tracked: %d", out.pairs))
  print(string.format("responses_2xx: %d", out.responses_2xx))
  print(string.format("responses_non2xx: %d", out.responses_non2xx))
  print(string.format("iterations_started: %d", out.iterations_started))
  print(string.format("iterations_completed: %d", out.iterations_completed))
  print(string.format("iterations_failed: %d", out.iterations_failed))
  print(string.format("iterations_exhausted: %d", out.iterations_exhausted))
  print(string.format("encode_failures: %d", out.encode_failures))
end
