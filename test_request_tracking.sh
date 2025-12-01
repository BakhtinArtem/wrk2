#!/bin/bash
# Quick test script to verify request-response pair tracking is working

echo "=========================================="
echo "Testing Request-Response Pair Tracking"
echo "=========================================="
echo ""

# Check if wrk binary exists
if [ ! -f "./wrk" ]; then
    echo "Error: wrk binary not found. Please build it first with 'make'"
    exit 1
fi

# Test 1: Simple tracking test
echo "Test 1: Simple Counter Tracking"
echo "--------------------------------"
echo "Running: ./wrk -t1 -c3 -d2s -R10 --script=scripts/simple_tracking.lua http://httpbin.org/get"
echo ""
./wrk -t3 -c3 -d4s -R100 --script=scr
ipts/simple_tracking.lua http://httpbin.org/get 2>&1 | grep -E "(Request #|Running|requests in)"
echo ""
echo ""

# Test 2: Request tracking with latency
echo "Test 2: Request Tracking with Latency"
echo "-------------------------------------"
echo "Running: ./wrk -t1 -c2 -d2s -R5 --script=scripts/request_tracking.lua http://httpbin.org/get"
echo ""
./wrk -t3 -c3 -d4s -R500 --script=scripts/request_tracking.lua http://httpbin.org/get 2>&1 | grep -E "(\[REQUEST\]|\[RESPONSE\]|Running|requests in)"
echo ""
echo ""

# Test 3: Advanced tracking with tables
echo "Test 3: Advanced Tracking with Tables"
echo "--------------------------------------"
echo "Running: ./wrk -t1 -c2 -d2s -R5 --script=scripts/advanced_tracking.lua http://httpbin.org/get"
echo ""
./wrk -t3 -c3 -d4s -R500 --script=scripts/advanced_tracking.lua http://httpbin.org/get 2>&1 | grep -E "(Request #|Running|requests in|Total unique)"
echo ""
echo ""

echo "=========================================="
echo "Tests completed!"
echo "=========================================="
echo ""
echo "To see more detailed output, run the tests individually:"
echo "  ./wrk -t1 -c3 -d5s -R10 --script=scripts/simple_tracking.lua http://httpbin.org/get"
echo "  ./wrk -t1 -c3 -d5s -R10 --script=scripts/request_tracking.lua http://httpbin.org/get"
echo "  ./wrk -t1 -c3 -d5s -R10 --script=scripts/advanced_tracking.lua http://httpbin.org/get"

