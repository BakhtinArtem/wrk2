```bash
# example of run command
PERF_METHOD=GET \
PERF_ENDPOINT=/owners \
PERF_API_PREFIX=/petclinic/api \
./wrk -t4 -c10 -R1000 -d30s -s workdir/check/single_endpoint.lua http://localhost:9966/
```