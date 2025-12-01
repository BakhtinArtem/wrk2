-- Example script demonstrating request-response pair tracking
-- This script tracks each request with an ID and matches it with responses

request_counter = 0
request_map = {}

function request()
   request_counter = request_counter + 1
   local req_id = request_counter
   
   -- Store request info (optional, for tracking)
   request_map[req_id] = {
      timestamp = wrk.time_us(),
      path = wrk.path
   }
   
   -- Return request string and request ID
   return wrk.format(), req_id
end

function response(status, headers, body, request_id)
   if request_id then
      local req_info = request_map[request_id]
      if req_info then
         local latency = wrk.time_us() - req_info.timestamp
         print(string.format("Request %d: status=%d, latency=%.3fms", 
               request_id, status, latency / 1000.0))
         -- Clean up
         request_map[request_id] = nil
      end
   end
end

function done(summary, latency, requests)
   print(string.format("\n=== Summary ==="))
   print(string.format("Total requests tracked: %d", request_counter))
   print(string.format("Completed requests: %d", summary.requests))
end

