-- Simple example: Track request IDs with a counter
-- This minimal example shows the basic usage

counter = 0

function request()
   counter = counter + 1
   -- Return request string and counter as request ID
   return wrk.format(), counter
end

function response(status, headers, body, request_id)
   -- request_id will be the counter value from request()
   print(string.format("Request #%d -> Status %d", request_id, status))
end

