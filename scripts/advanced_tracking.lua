-- Advanced example: Track requests with detailed metadata
-- This example shows how to use tables as request IDs

local request_metadata = {}
local request_id_counter = 0

function request()
   request_id_counter = request_id_counter + 1
   
   -- Create a request metadata table as the request ID
   local req_id = {
      id = request_id_counter,
      timestamp = wrk.time_us(),
      path = wrk.path,
      method = wrk.method
   }
   
   -- Store it for later reference
   request_metadata[request_id_counter] = req_id
   
   -- You can use any Lua value as request_id (number, string, table, etc.)
   return wrk.format(), req_id
end

function response(status, headers, body, request_id)
   if request_id and type(request_id) == "table" then
      local latency = (wrk.time_us() - request_id.timestamp) / 1000.0
      
      print(string.format(
         "Request #%d [%s %s] -> Status %d (%.2fms)",
         request_id.id,
         request_id.method,
         request_id.path,
         status,
         latency
      ))
      
      -- Clean up
      request_metadata[request_id.id] = nil
   end
end

function done(summary, latency, requests)
   print(string.format("\nTotal unique requests tracked: %d", request_id_counter))
end

