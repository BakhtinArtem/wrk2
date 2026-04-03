-- Simple wrk2 script for single-endpoint performance checks.
-- Configure behavior via environment variables:
--   PERF_METHOD       (default: GET)
--   PERF_ENDPOINT     (default: /owners)
--   PERF_API_PREFIX   (default: /petclinic/api)
--   PERF_ACCEPT       (default: application/json)
--   PERF_CONTENT_TYPE (default: application/json)
--   PERF_BODY         (optional request body; used for non-GET/HEAD)
---@diagnostic disable: undefined-global

local threads = {}
local setup_thread_counter = 0

local method = string.upper(os.getenv("PERF_METHOD") or "GET")
local endpoint = os.getenv("PERF_ENDPOINT") or "/owners"
local api_prefix = os.getenv("PERF_API_PREFIX") or "/petclinic/api"
local accept = os.getenv("PERF_ACCEPT") or "application/json"
local content_type = os.getenv("PERF_CONTENT_TYPE") or "application/json"
local req_body = os.getenv("PERF_BODY")

local target_path = nil
local request_blob = nil
local function join_path(prefix, path)
  local p = prefix or ""
  local e = path or ""

  if p == "" then
    return e
  end
  if e == "" then
    return p
  end

  if p:sub(-1) == "/" and e:sub(1, 1) == "/" then
    return p:sub(1, -2) .. e
  end
  if p:sub(-1) ~= "/" and e:sub(1, 1) ~= "/" then
    return p .. "/" .. e
  end
  return p .. e
end

function setup(thread)
  setup_thread_counter = setup_thread_counter + 1
  thread:set("single_thread_id", setup_thread_counter)
  threads[#threads + 1] = thread
end

function init(args)
  local host = wrk.host
  local port = wrk.port
  if host:find(":") then
    host = "[" .. host .. "]"
  end
  if port then
    host = host .. ":" .. port
  end

  wrk.headers["Host"] = host
  wrk.headers["Accept"] = accept

  target_path = join_path(api_prefix, endpoint)
  if target_path:sub(1, 1) ~= "/" then
    target_path = "/" .. target_path
  end

  if req_body and req_body ~= "" and method ~= "GET" and method ~= "HEAD" then
    wrk.headers["Content-Type"] = content_type
    request_blob = wrk.format(method, target_path, wrk.headers, req_body)
  else
    request_blob = wrk.format(method, target_path, wrk.headers, nil)
  end

  print(string.format("single_endpoint target=%s method=%s", target_path, method))

  -- Expose per-thread counters for done() aggregation.
  _G.single_target = target_path
  _G.single_method = method
  _G.single_total = 0
  _G.single_ok = 0
  _G.single_redirect = 0
  _G.single_client_err = 0
  _G.single_server_err = 0
  _G.single_other = 0
end

function request()
  return request_blob
end

function response(status, headers, body)
  _G.single_total = (_G.single_total or 0) + 1
  if status >= 200 and status < 300 then
    _G.single_ok = (_G.single_ok or 0) + 1
  elseif status >= 300 and status < 400 then
    _G.single_redirect = (_G.single_redirect or 0) + 1
  elseif status >= 400 and status < 500 then
    _G.single_client_err = (_G.single_client_err or 0) + 1
  elseif status >= 500 and status < 600 then
    _G.single_server_err = (_G.single_server_err or 0) + 1
  else
    _G.single_other = (_G.single_other or 0) + 1
  end
end

function done(summary, latency, requests)
  local total = 0
  local ok = 0
  local redirect = 0
  local client_err = 0
  local server_err = 0
  local other = 0
  local target = nil

  for _, thread in ipairs(threads) do
    total = total + (thread:get("single_total") or 0)
    ok = ok + (thread:get("single_ok") or 0)
    redirect = redirect + (thread:get("single_redirect") or 0)
    client_err = client_err + (thread:get("single_client_err") or 0)
    server_err = server_err + (thread:get("single_server_err") or 0)
    other = other + (thread:get("single_other") or 0)
    if not target then
      target = thread:get("single_target")
    end
  end

  print("")
  print("--- single_endpoint summary ---")
  print(string.format("target: %s", tostring(target)))
  print(string.format("method: %s", tostring(method)))
  print(string.format("responses_total: %d", total))
  print(string.format("responses_2xx: %d", ok))
  print(string.format("responses_3xx: %d", redirect))
  print(string.format("responses_4xx: %d", client_err))
  print(string.format("responses_5xx: %d", server_err))
  print(string.format("responses_other: %d", other))
end
