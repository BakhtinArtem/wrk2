-- Example script demonstrating request-response pair tracking
-- This script shows how to track each request with an ID and match it with responses

-- Global counter to assign unique IDs to each request
request_counter = 0

-- Optional: Store request metadata for tracking
request_log = {}

function request()
   -- Increment counter for each request
   request_counter = request_counter + 1
   local req_id = request_counter
   
   -- Store request metadata (optional, for demonstration)
   local timestamp = wrk.time_us()
   request_log[req_id] = {
      timestamp = timestamp,
      path = wrk.path
   }
   
   -- Print when request is sent (optional, for testing)
   print(string.format("[REQUEST] ID=%d, Path=%s, Time=%d", 
         req_id, wrk.path, timestamp))
   
   -- Return request string AND request ID as second return value
   -- The request ID will be passed to response() function
   return wrk.format(), req_id
end

function response(status, headers, body, request_id)
   -- request_id is the second return value from request()
   if request_id then
      local req_info = request_log[request_id]
      if req_info then
         local latency_us = wrk.time_us() - req_info.timestamp
         local latency_ms = latency_us / 1000.0
         
         -- Print matched request-response pair
         print(string.format("[RESPONSE] ID=%d, Status=%d, Latency=%.3fms, Path=%s", 
               request_id, status, latency_ms, req_info.path))
         
         -- Clean up (optional, to prevent memory growth)
         request_log[request_id] = nil
      else
         print(string.format("[WARNING] Response for unknown request_id: %s", 
               tostring(request_id)))
      end
   else
      print("[WARNING] Response received without request_id")
   end
end

-- Optional: Print summary at the end
function done(summary, latency, requests)
   print("\n=== Request Tracking Summary ===")
   print(string.format("Total requests tracked: %d", request_counter))
   print(string.format("Completed requests: %d", summary.requests))
   print(string.format("Duration: %.2f seconds", summary.duration / 1000000.0))
end

