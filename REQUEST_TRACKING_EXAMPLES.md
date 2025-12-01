# Request-Response Pair Tracking Examples

This document demonstrates how to use the request-response pair tracking feature in wrk2 Lua scripts.

## Overview

The request-response tracking feature allows you to:
- Assign a unique identifier to each request
- Match responses with their corresponding requests
- Track request metadata (timestamps, paths, etc.)
- Calculate per-request latencies

## Basic Usage

The `request()` function can now return two values:
1. The HTTP request string (required)
2. A request ID (optional - can be any Lua value: number, string, table, etc.)

The `response()` function now receives a fourth parameter:
- `response(status, headers, body, request_id)`

## Example Scripts

### 1. Simple Counter Example (`scripts/simple_tracking.lua`)

The simplest example using a counter:

```lua
counter = 0

function request()
   counter = counter + 1
   return wrk.format(), counter
end

function response(status, headers, body, request_id)
   print(string.format("Request #%d -> Status %d", request_id, status))
end
```

**Usage:**
```bash
./wrk -t2 -c10 -d5s -R100 --script=scripts/simple_tracking.lua http://localhost:8080/
```

### 2. Request Tracking with Latency (`scripts/request_tracking.lua`)

Tracks requests with timestamps and calculates latency:

```lua
request_counter = 0
request_log = {}

function request()
   request_counter = request_counter + 1
   local req_id = request_counter
   local timestamp = wrk.time_us()
   
   request_log[req_id] = {
      timestamp = timestamp,
      path = wrk.path
   }
   
   return wrk.format(), req_id
end

function response(status, headers, body, request_id)
   if request_id then
      local req_info = request_log[request_id]
      local latency_us = wrk.time_us() - req_info.timestamp
      local latency_ms = latency_us / 1000.0
      
      print(string.format("Request #%d -> Status %d (%.3fms)", 
            request_id, status, latency_ms))
      
      request_log[request_id] = nil
   end
end
```

**Usage:**
```bash
./wrk -t2 -c10 -d5s -R100 --script=scripts/request_tracking.lua http://localhost:8080/
```

### 3. Advanced Tracking with Tables (`scripts/advanced_tracking.lua`)

Uses tables as request IDs for more complex metadata:

```lua
local request_metadata = {}
local request_id_counter = 0

function request()
   request_id_counter = request_id_counter + 1
   
   local req_id = {
      id = request_id_counter,
      timestamp = wrk.time_us(),
      path = wrk.path,
      method = wrk.method
   }
   
   request_metadata[request_id_counter] = req_id
   return wrk.format(), req_id
end

function response(status, headers, body, request_id)
   if request_id and type(request_id) == "table" then
      local latency = (wrk.time_us() - request_id.timestamp) / 1000.0
      print(string.format("Request #%d [%s %s] -> Status %d (%.2fms)",
            request_id.id, request_id.method, request_id.path, status, latency))
      request_metadata[request_id.id] = nil
   end
end
```

**Usage:**
```bash
./wrk -t2 -c10 -d5s -R100 --script=scripts/advanced_tracking.lua http://localhost:8080/
```

## Testing the Feature

### Test 1: Verify Request IDs are Unique

Run with a simple script and check that each request gets a unique ID:

```bash
./wrk -t1 -c5 -d3s -R10 --script=scripts/simple_tracking.lua http://httpbin.org/get
```

You should see output like:
```
Request #1 -> Status 200
Request #2 -> Status 200
Request #3 -> Status 200
...
```

### Test 2: Verify Request-Response Matching

Use the tracking script to verify that responses match requests:

```bash
./wrk -t1 -c3 -d5s -R20 --script=scripts/request_tracking.lua http://httpbin.org/get
```

You should see matched pairs:
```
[REQUEST] ID=1, Path=/get, Time=1234567890
[RESPONSE] ID=1, Status=200, Latency=45.123ms, Path=/get
[REQUEST] ID=2, Path=/get, Time=1234567891
[RESPONSE] ID=2, Status=200, Latency=43.456ms, Path=/get
```

### Test 3: Test with Different Endpoints

Modify the script to use different paths and verify tracking works:

```lua
counter = 0
paths = {"/get", "/post", "/status/200"}

function request()
   counter = counter + 1
   local path = paths[(counter % #paths) + 1]
   wrk.path = path
   return wrk.format(), {id = counter, path = path}
end

function response(status, headers, body, request_id)
   print(string.format("Request #%d to %s -> Status %d", 
         request_id.id, request_id.path, status))
end
```

### Test 4: Error Handling

Test that the feature handles errors gracefully:

```bash
# Test with invalid host
./wrk -t1 -c1 -d2s -R5 --script=scripts/simple_tracking.lua http://invalid-host-12345:8080/

# Test with timeout
./wrk -t1 -c1 -d2s -R5 --timeout=1s --script=scripts/simple_tracking.lua http://httpbin.org/delay/10
```

## Notes

- If `request()` doesn't return a second value, `request_id` will be `nil` in `response()`
- The request ID can be any Lua value (number, string, table, etc.)
- For pipelined requests, the current implementation tracks the most recent request in a batch
- Request IDs are automatically cleaned up to prevent memory leaks
- Each thread has its own independent Lua state, so counters start at 0 for each thread

## Troubleshooting

**Problem:** Request IDs are always `nil` in `response()`
- **Solution:** Make sure `request()` returns two values: `return wrk.format(), request_id`

**Problem:** Request IDs don't match between request and response
- **Solution:** This can happen with pipelined requests. The current implementation tracks the most recent request in a batch.

**Problem:** Memory usage grows over time
- **Solution:** Clean up request metadata in `response()`: `request_log[request_id] = nil`

