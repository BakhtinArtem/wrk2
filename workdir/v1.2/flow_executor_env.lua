--[[
  wrk2 flow executor for static v1.2 iterations.

  Adds low-overhead per-step telemetry:
    step_count[step]
    step_sum_us[step]
    step_max_us[step]
    step_status_count[step:status]
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

local step_count_by_key = {}
local step_sum_us_by_key = {}
local step_max_us_by_key = {}
local step_status_count_by_key = {}
local step_status_keys_seen = {}

local function now_us()
  return math.floor(os.clock() * 1000000)
end

local function sanitize_token(s)
  return tostring(s):gsub("[^%w_]", "_")
end

local function split_csv(text)
  local out = {}
  if not text or text == "" then
    return out
  end
  for token in tostring(text):gmatch("([^,]+)") do
    if token ~= "" then
      out[#out + 1] = token
    end
  end
  return out
end

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
  _G.v12_requests_issued = 0
  _G.v12_pairs = 0
  _G.v12_responses_2xx = 0
  _G.v12_responses_non2xx = 0
  _G.v12_iterations_started = 0
  _G.v12_iterations_completed = 0
  _G.v12_iterations_failed = 0
  _G.v12_iterations_exhausted = 0
  _G.v12_encode_failures = 0
  _G.v12_stage = stage
  _G.v12_data_dir = data_dir

  _G.v12_step_keys_line = ""
  _G.v12_step_status_keys_line = ""
end

local function register_step_key(step_key)
  local token = sanitize_token(step_key)
  local key_var = "v12_step_key_name__" .. token
  if _G[key_var] == nil then
    _G[key_var] = step_key
    local prior = _G.v12_step_keys_line
    if not prior or prior == "" then
      _G.v12_step_keys_line = token
    else
      _G.v12_step_keys_line = prior .. "," .. token
    end
  end
  if _G["v12_step_count__" .. token] == nil then
    _G["v12_step_count__" .. token] = 0
    _G["v12_step_sum_us__" .. token] = 0
    _G["v12_step_max_us__" .. token] = 0
  end
  return token
end

local function register_step_status_key(step_key, status)
  local token = sanitize_token(step_key .. ":" .. tostring(status))
  if step_status_keys_seen[token] then
    return token
  end
  step_status_keys_seen[token] = true
  _G["v12_step_status_name__" .. token] = step_key .. ":" .. tostring(status)
  _G["v12_step_status__" .. token] = _G["v12_step_status__" .. token] or 0
  local prior = _G.v12_step_status_keys_line
  if not prior or prior == "" then
    _G.v12_step_status_keys_line = token
  else
    _G.v12_step_status_keys_line = prior .. "," .. token
  end
  return token
end

local function bootstrap_step_registry()
  local seen = {}
  for _, iter in ipairs(iterations) do
    for _, step in ipairs(iter.steps or {}) do
      local step_key = tostring(step.flowId or "unknown")
      if not seen[step_key] then
        seen[step_key] = true
        register_step_key(step_key)
      end
    end
  end
end

local function record_step_metrics(step_key, status, elapsed_us)
  if not step_key then
    return
  end
  local token = register_step_key(step_key)
  local count_name = "v12_step_count__" .. token
  local sum_name = "v12_step_sum_us__" .. token
  local max_name = "v12_step_max_us__" .. token

  step_count_by_key[step_key] = (step_count_by_key[step_key] or 0) + 1
  step_sum_us_by_key[step_key] = (step_sum_us_by_key[step_key] or 0) + elapsed_us
  local prev_max = step_max_us_by_key[step_key] or 0
  if elapsed_us > prev_max then
    step_max_us_by_key[step_key] = elapsed_us
  end
  step_status_count_by_key[step_key .. ":" .. tostring(status)] =
    (step_status_count_by_key[step_key .. ":" .. tostring(status)] or 0) + 1

  _G[count_name] = (_G[count_name] or 0) + 1
  _G[sum_name] = (_G[sum_name] or 0) + elapsed_us
  if elapsed_us > (_G[max_name] or 0) then
    _G[max_name] = elapsed_us
  end

  local stoken = register_step_status_key(step_key, status)
  local scount_name = "v12_step_status__" .. stoken
  _G[scount_name] = (_G[scount_name] or 0) + 1
end

local function ensure_conn_state(conn_id)
  local st = conn_state[conn_id]
  if st then
    return st
  end
  st = {
    iteration_index = nil,
    step_index = 1,
    next_iteration_seed = conn_id + 1,
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
    _G.v12_iterations_exhausted = _G.v12_iterations_exhausted + 1
    return false
  end

  local idx = st.next_iteration_seed
  if idx > total then
    if reuse_mode == "wrap" then
      idx = ((idx - 1) % total) + 1
    else
      st.exhausted = true
      _G.v12_iterations_exhausted = _G.v12_iterations_exhausted + 1
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
  _G.v12_iterations_started = _G.v12_iterations_started + 1
  return true
end

local function complete_iteration(st)
  _G.v12_iterations_completed = _G.v12_iterations_completed + 1
  st.iteration_index = nil
  st.step_index = 1
  st.current_step = nil
end

local function fail_iteration(st)
  _G.v12_iterations_failed = _G.v12_iterations_failed + 1
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
    local encoded = nil
    encoded, _ = encode_json(step.requestBody)
    if not encoded then
      _G.v12_encode_failures = _G.v12_encode_failures + 1
      fail_iteration(st)
      return nil
    end
    body_text = encoded
    if headers["Content-Type"] == nil then
      headers["Content-Type"] = "application/json"
    end
  end

  local step_key = tostring(step.flowId or "unknown")
  register_step_key(step_key)

  st.current_step = {
    flow_id = step_key,
    method = method,
    path = path,
    iteration_index = st.iteration_index,
    step_index = st.step_index,
    started_us = now_us(),
  }

  _G.v12_requests_issued = _G.v12_requests_issued + 1
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
  bootstrap_step_registry()

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

  _G.v12_pairs = _G.v12_pairs + 1

  local elapsed = now_us() - (st.current_step.started_us or 0)
  if elapsed < 0 then
    elapsed = 0
  end
  record_step_metrics(st.current_step.flow_id, status, elapsed)

  if is_success_status(status) then
    _G.v12_responses_2xx = _G.v12_responses_2xx + 1
    st.step_index = st.step_index + 1
    local iter = iterations[st.iteration_index]
    if iter and st.step_index > #iter.steps then
      complete_iteration(st)
    end
  else
    _G.v12_responses_non2xx = _G.v12_responses_non2xx + 1
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

  if log_every > 0 and (_G.v12_pairs % log_every == 0) then
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

local function flow_stats_wants_formats()
  local raw = os.getenv("FLOW_STATS_FORMAT") or ""
  raw = string.lower(raw):gsub("%s+", "")
  if raw == "" or raw == "json" then
    return true, false
  end
  if raw == "csv" then
    return false, true
  end
  if raw == "both" or raw == "all" then
    return true, true
  end
  local want_j, want_c = false, false
  for part in string.gmatch(raw, "[^,]+") do
    local p = part:match("^%s*(.-)%s*$")
    if p == "json" then
      want_j = true
    elseif p == "csv" then
      want_c = true
    end
  end
  if want_j or want_c then
    return want_j, want_c
  end
  return true, false
end

local function flow_escape_csv_field(s)
  s = tostring(s)
  if string.find(s, "[\",\n\r]", 1) then
    return '"' .. string.gsub(s, '"', '""') .. '"'
  end
  return s
end

local function flow_try_write_stats(doc)
  local dir = os.getenv("FLOW_STATS_OUT_DIR")
  if not dir or dir == "" then
    return
  end
  local want_json, want_csv = flow_stats_wants_formats()
  local base = string.format(
    "flow_stats_%s_%s",
    os.date("!%Y%m%dT%H%M%S"),
    string.sub(string.gsub(tostring(os.clock()), "%.", ""), 1, 12)
  )
  local function fail(msg)
    print("FLOW_STATS_OUT: " .. tostring(msg))
  end
  if want_json then
    local payload = {
      executor = doc.executor,
      ts_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      stage = doc.stage,
      data_dir = doc.data_dir,
      summary = doc.summary,
      step_stats = doc.step_stats,
      step_status = doc.step_status,
    }
    local txt, err = encode_json(payload)
    if not txt then
      fail("json encode: " .. tostring(err))
    else
      local path = dir .. "/" .. base .. ".json"
      local f = io.open(path, "w")
      if not f then
        fail("cannot open " .. path)
      else
        f:write(txt)
        f:close()
      end
    end
  end
  if want_csv then
    local path_steps = dir .. "/" .. base .. "_step_stats.csv"
    local f = io.open(path_steps, "w")
    if not f then
      fail("cannot open " .. path_steps)
    else
      f:write("step,count,sum_us,max_us,avg_us\n")
      for _, r in ipairs(doc.step_stats) do
        f:write(string.format(
          "%s,%d,%d,%d,%d\n",
          flow_escape_csv_field(r.step),
          r.count,
          r.sum_us,
          r.max_us,
          r.avg_us
        ))
      end
      f:close()
    end
    local path_status = dir .. "/" .. base .. "_step_status.csv"
    f = io.open(path_status, "w")
    if not f then
      fail("cannot open " .. path_status)
    else
      f:write("key,count\n")
      for _, r in ipairs(doc.step_status) do
        f:write(string.format("%s,%d\n", flow_escape_csv_field(r.key), r.count))
      end
      f:close()
    end
    local path_summary = dir .. "/" .. base .. "_summary.csv"
    f = io.open(path_summary, "w")
    if not f then
      fail("cannot open " .. path_summary)
    else
      f:write("key,value\n")
      for k, v in pairs(doc.summary) do
        if type(v) == "number" then
          f:write(string.format("%s,%d\n", flow_escape_csv_field(k), v))
        else
          f:write(string.format(
            "%s,%s\n",
            flow_escape_csv_field(k),
            flow_escape_csv_field(tostring(v))
          ))
        end
      end
      f:close()
    end
  end
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
  local step_tokens = {}
  local step_token_seen = {}
  local status_tokens = {}
  local status_token_seen = {}

  for _, t in ipairs(threads) do
    out.requests_issued = out.requests_issued + (t:get("v12_requests_issued") or 0)
    out.pairs = out.pairs + (t:get("v12_pairs") or 0)
    out.responses_2xx = out.responses_2xx + (t:get("v12_responses_2xx") or 0)
    out.responses_non2xx = out.responses_non2xx + (t:get("v12_responses_non2xx") or 0)
    out.iterations_started = out.iterations_started + (t:get("v12_iterations_started") or 0)
    out.iterations_completed = out.iterations_completed + (t:get("v12_iterations_completed") or 0)
    out.iterations_failed = out.iterations_failed + (t:get("v12_iterations_failed") or 0)
    out.iterations_exhausted = out.iterations_exhausted + (t:get("v12_iterations_exhausted") or 0)
    out.encode_failures = out.encode_failures + (t:get("v12_encode_failures") or 0)
    if not stage_name then
      stage_name = t:get("v12_stage")
    end
    if not data_root then
      data_root = t:get("v12_data_dir")
    end

    for _, token in ipairs(split_csv(t:get("v12_step_keys_line"))) do
      if not step_token_seen[token] then
        step_token_seen[token] = true
        step_tokens[#step_tokens + 1] = token
      end
    end
    for _, token in ipairs(split_csv(t:get("v12_step_status_keys_line"))) do
      if not status_token_seen[token] then
        status_token_seen[token] = true
        status_tokens[#status_tokens + 1] = token
      end
    end
  end

  table.sort(step_tokens)
  table.sort(status_tokens)

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

  local step_stats_rows = {}
  for _, token in ipairs(step_tokens) do
    local count = 0
    local sum_us = 0
    local max_us = 0
    local step_name = nil
    for _, t in ipairs(threads) do
      count = count + (t:get("v12_step_count__" .. token) or 0)
      sum_us = sum_us + (t:get("v12_step_sum_us__" .. token) or 0)
      local th_max = t:get("v12_step_max_us__" .. token) or 0
      if th_max > max_us then
        max_us = th_max
      end
      if not step_name then
        step_name = t:get("v12_step_key_name__" .. token)
      end
    end
    local avg_us = 0
    if count > 0 then
      avg_us = math.floor(sum_us / count)
    end
    step_stats_rows[#step_stats_rows + 1] = {
      step = tostring(step_name or token),
      count = count,
      sum_us = sum_us,
      max_us = max_us,
      avg_us = avg_us,
    }
    print(string.format("step_stats %s count=%d sum_us=%d max_us=%d avg_us=%d",
      tostring(step_name or token), count, sum_us, max_us, avg_us))
  end

  local step_status_rows = {}
  for _, token in ipairs(status_tokens) do
    local total = 0
    local status_name = nil
    for _, t in ipairs(threads) do
      total = total + (t:get("v12_step_status__" .. token) or 0)
      if not status_name then
        status_name = t:get("v12_step_status_name__" .. token)
      end
    end
    step_status_rows[#step_status_rows + 1] = {
      key = tostring(status_name or token),
      count = total,
    }
    print(string.format("step_status %s count=%d", tostring(status_name or token), total))
  end

  flow_try_write_stats({
    executor = "flow_executor_env",
    stage = tostring(stage_name or stage),
    data_dir = tostring(data_root or data_dir),
    summary = out,
    step_stats = step_stats_rows,
    step_status = step_status_rows,
  })
end
