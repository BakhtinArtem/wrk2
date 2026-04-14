#!/usr/bin/env lua

-- Script to measure time to first successful request
-- Uses SERVICE_NAME and PORT environment variables
-- Queries the first endpoint from scenario.json until successful
--
-- Debug mode: Set DEBUG=1 or DEBUG=true environment variable for verbose output

-- Add path to find modules (current directory first)
package.path = "./?.lua;" .. package.path

-- Load required bmodules
local json = require("json")
local data_generator = require("data-generator")

-- Load luaposix modules
local posix = require("posix")
local posix_stat = require("posix.sys.stat")

-- Load luasocket modules
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")

-------------------------------------------------------
-- Debug Configuration
-------------------------------------------------------

-- Check if debug mode is enabled via environment variable
local function is_debug_enabled()
    local debug_env = os.getenv("DEBUG")
    if debug_env then
        debug_env = debug_env:lower()
        return debug_env == "1" or debug_env == "true" or debug_env == "yes"
    end
    return false
end

local DEBUG = is_debug_enabled()

-- Debug print function - only prints if DEBUG is true
local function debug_print(...)
    if DEBUG then
        local args = {...}
        local msg = ""
        for i, v in ipairs(args) do
            msg = msg .. tostring(v)
            if i < #args then
                msg = msg .. " "
            end
        end
        print(string.format("[DEBUG] %s | %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), msg))
    end
end

-- Debug print for tables (pretty print)
local function debug_table(name, tbl, max_depth)
    if not DEBUG then return end
    max_depth = max_depth or 2
    
    local function print_table(t, indent, depth)
        if depth > max_depth then
            return "{...}"
        end
        indent = indent or ""
        local result = "{\n"
        for k, v in pairs(t) do
            local key_str = tostring(k)
            local val_str
            if type(v) == "table" then
                val_str = print_table(v, indent .. "  ", depth + 1)
            elseif type(v) == "string" then
                -- Truncate long strings
                if #v > 100 then
                    val_str = '"' .. v:sub(1, 100) .. '..."'
                else
                    val_str = '"' .. v .. '"'
                end
            else
                val_str = tostring(v)
            end
            result = result .. indent .. "  " .. key_str .. " = " .. val_str .. ",\n"
        end
        return result .. indent .. "}"
    end
    
    print(string.format("[DEBUG] %s | %s = %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), name, print_table(tbl, "", 1)))
end

-------------------------------------------------------
-- Helper Functions
-------------------------------------------------------

-- Create directory recursively (like mkdir -p)
local function mkdir_p(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    
    local current_path = ""
    for i, part in ipairs(parts) do
        if i == 1 and path:sub(1, 1) == "/" then
            current_path = "/" .. part
        else
            current_path = current_path .. (current_path == "" and "" or "/") .. part
        end
        
        local ok, err = posix_stat.mkdir(current_path, "0755")
        if not ok and err ~= "EEXIST" then
            return false, err
        end
    end
    return true
end

-------------------------------------------------------
-- HTTP Request Functions
-------------------------------------------------------

-- Make HTTP request using LuaSocket
local function make_request(method, url, headers, body, timeout, attempt_num)
    timeout = timeout or 0.1  -- Default timeout of 100ms
    attempt_num = attempt_num or 0
    
    debug_print(string.format("Request #%d: %s %s (timeout: %.3fs)", attempt_num, method, url, timeout))
    if body and body ~= "" then
        debug_print(string.format("Request #%d request_body length: %d bytes", attempt_num, #body))
        -- Log request body content (truncated if too long)
        if #body > 500 then
            debug_print(string.format("Request #%d request_body (truncated): %s...", attempt_num, body:sub(1, 500)))
        else
            debug_print(string.format("Request #%d request_body: %s", attempt_num, body))
        end
    else
        debug_print(string.format("Request #%d request_body: (none)", attempt_num))
    end
    
    local start_time = socket.gettime()
    local response_body = {}
    
    local request = {
        method = method,
        url = url,
        headers = headers or {},
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_body),
        timeout = timeout
    }
    
    debug_table(string.format("Request #%d headers", attempt_num), headers)
    
    local result, status_code, response_headers, status_line = http.request(request)
    local end_time = socket.gettime()
    local request_time = end_time - start_time
    
    debug_print(string.format("Request #%d completed in %.6f seconds", attempt_num, request_time))
    
    if result then
        local body_text = table.concat(response_body)
        debug_print(string.format("Request #%d result: status=%s, status_line=%s, body_length=%d", 
            attempt_num, tostring(status_code), tostring(status_line), #body_text))
        if response_headers then
            debug_table(string.format("Request #%d response_headers", attempt_num), response_headers)
        end
        -- Log response body (truncated if too long)
        if body_text and #body_text > 0 then
            if #body_text > 500 then
                debug_print(string.format("Request #%d response_body (truncated): %s...", attempt_num, body_text:sub(1, 500)))
            else
                debug_print(string.format("Request #%d response_body: %s", attempt_num, body_text))
            end
        else
            debug_print(string.format("Request #%d response_body: (empty)", attempt_num))
        end
        return status_code, response_headers, body_text, request_time
    else
        -- Timeout or connection error
        debug_print(string.format("Request #%d FAILED: result=%s, status_code=%s", 
            attempt_num, tostring(result), tostring(status_code)))
        return 0, {}, nil, request_time, status_code  -- status_code contains error message on failure
    end
end

-------------------------------------------------------
-- Main Function
-------------------------------------------------------

local function main()
    -- Print startup banner
    print(string.rep("=", 70))
    print("MEASURE FIRST REQUEST - Starting")
    print(string.rep("=", 70))
    print(string.format("Start time: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    print(string.format("Debug mode: %s", DEBUG and "ENABLED" or "DISABLED"))
    if DEBUG then
        print("(Set DEBUG=0 to disable verbose logging)")
    else
        print("(Set DEBUG=1 for verbose logging)")
    end
    print("")
    
    -- Get and validate environment variables
    debug_print("Reading environment variables...")
    local service_name = os.getenv("SERVICE_NAME")
    local port = os.getenv("PORT")
    local output_dir = os.getenv("OUTPUT_DIR")
    local wrk2params = os.getenv("WRK2PARAMS")
    
    -- Debug: Print all relevant environment variables
    debug_print("Environment variables:")
    debug_print("  SERVICE_NAME =", service_name or "(not set)")
    debug_print("  PORT =", port or "(not set)")
    debug_print("  OUTPUT_DIR =", output_dir or "(not set)")
    debug_print("  WRK2PARAMS =", wrk2params or "(not set)")
    debug_print("  DEBUG =", os.getenv("DEBUG") or "(not set)")
    debug_print("  PWD =", os.getenv("PWD") or "(not set)")
    debug_print("  HOME =", os.getenv("HOME") or "(not set)")
    
    if not service_name or not port then
        print("ERROR: Required environment variables not set!")
        print("  SERVICE_NAME:", service_name or "MISSING")
        print("  PORT:", port or "MISSING")
        error("SERVICE_NAME and PORT environment variables must be set")
    end
    
    local base_url = string.format("http://%s:%s", service_name, port)
    print(string.format("Target service: %s", base_url))
    debug_print("Base URL constructed:", base_url)
    
    -- Check current working directory and files
    debug_print("Current working directory contents:")
    local handle = io.popen("ls -la 2>&1")
    if handle then
        local result = handle:read("*a")
        handle:close()
        for line in result:gmatch("[^\r\n]+") do
            debug_print("  ", line)
        end
    end
    
    -- Load scenario
    local scenario_path = "scenario.json"
    print(string.format("Loading scenario from: %s", scenario_path))
    debug_print("Checking if scenario file exists...")
    
    local scenario_file = io.open(scenario_path, "r")
    if scenario_file then
        local file_size = scenario_file:seek("end")
        scenario_file:close()
        debug_print(string.format("Scenario file found, size: %d bytes", file_size))
    else
        print("ERROR: Cannot open scenario file: " .. scenario_path)
        debug_print("Scenario file not found or not readable")
    end
    
    debug_print("Calling data_generator.load_scenario()...")
    local load_start = socket.gettime()
    local scenario = data_generator.load_scenario(scenario_path)
    local load_time = socket.gettime() - load_start
    debug_print(string.format("Scenario loaded in %.6f seconds", load_time))
    
    if not scenario then
        print("ERROR: data_generator.load_scenario() returned nil")
        error("Failed to load scenario or scenario has no vertices")
    end
    
    if not scenario.vertices then
        print("ERROR: Scenario has no 'vertices' field")
        debug_table("scenario", scenario, 1)
        error("Failed to load scenario or scenario has no vertices")
    end
    
    -- Debug: Print scenario summary
    local vertex_count = 0
    for _ in pairs(scenario.vertices) do vertex_count = vertex_count + 1 end
    debug_print(string.format("Scenario loaded: %d vertices", vertex_count))
    debug_table("scenario.vertices keys", scenario.vertices and (function()
        local keys = {}
        for k in pairs(scenario.vertices) do keys[#keys + 1] = k end
        return keys
    end)() or {})
    
    -- Get first endpoint (vertex "0")
    local first_vertex_key = "0"
    local first_vertex = scenario.vertices[first_vertex_key]
    
    if not first_vertex then
        print("ERROR: First vertex (key '0') not found in scenario")
        print("Available vertex keys:")
        for k in pairs(scenario.vertices) do
            print("  - " .. tostring(k))
        end
        error("First vertex (0) not found in scenario")
    end
    
    print(string.format("\nFirst endpoint: %s %s", first_vertex.method, first_vertex.path))
    debug_table("first_vertex", first_vertex, 2)
    
    -- Generate dummy data for the first endpoint
    debug_print("Generating request data...")
    local unique_seed = os.time() * 1000 + math.random(1, 999)
    local thread_id = unique_seed % 1000000
    local conn_id = (unique_seed + 1) % 1000000
    local unique_values_generated = math.random(1, 10000)
    
    debug_print(string.format("Data generation params: seed=%d, thread_id=%d, conn_id=%d, unique_values=%d",
        unique_seed, thread_id, conn_id, unique_values_generated))
    
    local build_start = socket.gettime()
    local path, method, body, content_type, _, generated_values = data_generator.build_request(
        scenario,
        {},  -- No previous responses
        {},  -- No previous generated values
        0,   -- First vertex
        thread_id,
        conn_id,
        unique_values_generated
    )
    local build_time = socket.gettime() - build_start
    debug_print(string.format("Request built in %.6f seconds", build_time))
    
    local full_url = base_url .. path
    print(string.format("Full URL: %s", full_url))
    print(string.format("Method: %s", method))
    if body and body ~= "" then
        print(string.format("Body: %s", body))
        debug_print(string.format("Body length: %d bytes", #body))
    else
        debug_print("No request body")
    end
    print(string.format("Content-Type: %s", content_type))
    
    if generated_values then
        debug_table("generated_values", generated_values, 2)
    end
    
    -- Prepare headers
    local headers = {
        ["Content-Type"] = content_type,
        ["Accept"] = "application/json"
    }
    
    -- Test DNS resolution / connectivity
    debug_print("Testing connectivity to service...")
    local test_socket = socket.tcp()
    test_socket:settimeout(1)
    local conn_result, conn_err = test_socket:connect(service_name, tonumber(port))
    if conn_result then
        debug_print(string.format("TCP connection to %s:%s successful", service_name, port))
        test_socket:close()
    else
        debug_print(string.format("TCP connection to %s:%s failed: %s", service_name, port, tostring(conn_err)))
        print(string.format("Warning: Initial TCP connection test failed: %s", tostring(conn_err)))
    end
    
    -- Measure time to first successful request
    print("\nStarting requests until first successful response...")
    print("(A successful request is one with status code 200-399, excluding client errors)\n")
    debug_print("Request loop starting...")
    
    -- Get start time using luaposix gettimeofday for high precision
    local start_tv = posix.gettimeofday()
    local start_time = start_tv.sec + start_tv.usec / 1000000.0
    
    local attempt = 0
    local success = false
    local final_status = nil
    local final_body = nil
    local first_success_timestamp = nil
    local request_timeout = 0.1  -- 100ms timeout per request
    
    local error_counts = {}  -- Track different error types
    local last_error = nil
    
    while not success do
        attempt = attempt + 1
        
        -- Make synchronous request (pass attempt number for debug logging)
        local status, response_headers, response_body, request_time, error_msg = make_request(method, full_url, headers, body, request_timeout, attempt)
        
        if status then
            if status == 0 then
                -- Track error type
                local err_key = error_msg and tostring(error_msg) or "timeout"
                error_counts[err_key] = (error_counts[err_key] or 0) + 1
                last_error = err_key
                
                -- Only print every 10th timeout to reduce noise (or always in debug mode)
                if attempt <= 5 or attempt % 10 == 0 or DEBUG then
                    print(string.format("Attempt %d: Timeout/Error (%.3f seconds) - %s", attempt, request_time, err_key))
                elseif attempt == 6 then
                    print("  (suppressing further timeout messages, will show every 10th attempt)")
                end
            else
                print(string.format("Attempt %d: Status %d (%.3f seconds)", attempt, status, request_time))
                
                -- Consider 2xx and 3xx status codes as successful (3xx are redirects, which indicate service is working)
                -- Exclude 4xx (client errors) and 5xx (server errors)
                if status >= 200 and status < 400 then
                    success = true
                    final_status = status
                    final_body = response_body
                    
                    -- Get timestamp of first success
                    local success_tv = posix.gettimeofday()
                    first_success_timestamp = success_tv.sec
                    
                    print(string.format("\n✓ SUCCESS on attempt %d!", attempt))
                    debug_print("First successful response received")
                    if response_headers then
                        debug_table("Success response headers", response_headers)
                    end
                else
                    -- Non-success response (4xx or 5xx)
                    debug_print(string.format("Non-success status %d, response: %s", 
                        status, response_body and response_body:sub(1, 200) or "(empty)"))
                end
            end
        else
            local err_key = "request_failed"
            error_counts[err_key] = (error_counts[err_key] or 0) + 1
            last_error = err_key
            
            if attempt <= 5 or attempt % 10 == 0 or DEBUG then
                print(string.format("Attempt %d: Request failed (%.3f seconds)", attempt, request_time or 0))
            end
        end
        
        -- Small delay between requests (1 millisecond) if not successful
        if not success then
            socket.sleep(0.001)  -- 1 millisecond delay using luasocket
        end
        
        -- Safety check: warn if too many attempts
        if attempt % 100 == 0 then
            local elapsed_tv = posix.gettimeofday()
            local elapsed = elapsed_tv.sec + elapsed_tv.usec / 1000000.0 - start_time
            print(string.format("  ... %d attempts so far (%.2f seconds elapsed)", attempt, elapsed))
            debug_print("Error counts so far:")
            for err_type, count in pairs(error_counts) do
                debug_print(string.format("  %s: %d", err_type, count))
            end
        end
    end
    
    -- Print error summary if there were errors
    if next(error_counts) then
        debug_print("Error summary:")
        for err_type, count in pairs(error_counts) do
            debug_print(string.format("  %s: %d occurrences", err_type, count))
        end
    end
    
    -- Get final end time using luaposix gettimeofday
    local end_tv = posix.gettimeofday()
    local end_time = end_tv.sec + end_tv.usec / 1000000.0
    local total_time = end_time - start_time
    
    -- Print results
    print("\n" .. string.rep("=", 60))
    print("RESULTS")
    print(string.rep("=", 60))
    print(string.format("Time to first successful request: %.3f seconds", total_time))
    print(string.format("Time to first successful request: %.6f seconds (high precision)", total_time))
    print(string.format("First success timestamp: %s", os.date("!%Y-%m-%dT%H:%M:%SZ", first_success_timestamp)))
    print(string.format("Total attempts: %d", attempt))
    print(string.format("Final status code: %d", final_status))
    if final_body then
        local body_preview = final_body:sub(1, 200)
        if #final_body > 200 then
            body_preview = body_preview .. "..."
        end
        print(string.format("Response body preview: %s", body_preview))
        debug_print(string.format("Full response body length: %d bytes", #final_body))
    end
    print(string.rep("=", 60))
    
    -- Debug: Print timing breakdown
    debug_print("Timing breakdown:")
    debug_print(string.format("  Start time (epoch): %.6f", start_time))
    debug_print(string.format("  End time (epoch): %.6f", end_time))
    debug_print(string.format("  Total duration: %.6f seconds", total_time))
    if attempt > 1 then
        debug_print(string.format("  Average time per attempt: %.6f seconds", total_time / attempt))
    end
    
    -- Save results to file
    local output_dir_save = os.getenv("OUTPUT_DIR")
    debug_print("Saving results...")
    debug_print("OUTPUT_DIR:", output_dir_save or "(not set)")
    
    if output_dir_save then
        -- Create directory recursively if it doesn't exist using luaposix
        debug_print("Creating output directory:", output_dir_save)
        local ok, err = mkdir_p(output_dir_save)
        if not ok then
            print(string.format("Warning: Could not create directory %s: %s", output_dir_save, err or "unknown error"))
            debug_print("mkdir_p failed:", err)
        else
            debug_print("Directory created/exists")
        end
        
        -- Prepare result data
        local result_data = {
            time_to_first_success = total_time,
            time_to_first_success_ms = total_time * 1000,
            first_success_timestamp = first_success_timestamp,
            first_success_timestamp_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", first_success_timestamp),
            total_attempts = attempt,
            final_status_code = final_status,
            endpoint = {
                method = method,
                path = path,
                full_url = full_url
            },
            response_body = final_body,
            debug_info = DEBUG and {
                service_name = service_name,
                port = port,
                start_time_epoch = start_time,
                end_time_epoch = end_time,
                error_counts = error_counts
            } or nil
        }
        
        debug_table("result_data (excluding response_body)", {
            time_to_first_success = result_data.time_to_first_success,
            time_to_first_success_ms = result_data.time_to_first_success_ms,
            first_success_timestamp = result_data.first_success_timestamp,
            total_attempts = result_data.total_attempts,
            final_status_code = result_data.final_status_code,
            endpoint = result_data.endpoint
        })
        
        -- Save as JSON
        local result_file = output_dir_save .. "/first_request_result.json"
        debug_print("Writing results to:", result_file)
        
        local file = io.open(result_file, "w")
        if file then
            local json_str = json.encode(result_data)
            debug_print(string.format("JSON string length: %d bytes", #json_str))
            file:write(json_str)
            file:close()
            print(string.format("\nResults saved to: %s", result_file))
            
            -- Verify the file was written
            local verify_file = io.open(result_file, "r")
            if verify_file then
                local written_size = verify_file:seek("end")
                verify_file:close()
                debug_print(string.format("Verified: file written, size: %d bytes", written_size))
            end
        else
            print(string.format("\nWarning: Could not write results to %s", result_file))
            debug_print("io.open failed for result file")
        end
    else
        print("\nNote: OUTPUT_DIR not set, results not saved to file")
    end
    
    -- Final debug summary
    debug_print("")
    debug_print(string.rep("-", 50))
    debug_print("Script completed successfully")
    debug_print(string.format("End time: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    debug_print(string.rep("-", 50))
end

-- Run main function with error handling
local ok, err = pcall(main)
if not ok then
    print("")
    print(string.rep("!", 70))
    print("FATAL ERROR")
    print(string.rep("!", 70))
    print(string.format("Error message: %s", err))
    print("")
    print("Debug information:")
    print(string.format("  Timestamp: %s", os.date("!%Y-%m-%dT%H:%M:%SZ")))
    print(string.format("  SERVICE_NAME: %s", os.getenv("SERVICE_NAME") or "(not set)"))
    print(string.format("  PORT: %s", os.getenv("PORT") or "(not set)"))
    print(string.format("  OUTPUT_DIR: %s", os.getenv("OUTPUT_DIR") or "(not set)"))
    print(string.format("  DEBUG: %s", os.getenv("DEBUG") or "(not set)"))
    print("")
    print("Tip: Set DEBUG=1 environment variable for verbose output")
    print(string.rep("!", 70))
    os.exit(1)
end