```bash
# v2.0 template-aware flow executor
FLOW_DATA_DIR=workdir/v2.0/data \
FLOW_STAGE=lifecycle \
FLOW_API_PREFIX=/petclinic/api \
FLOW_REUSE_MODE=wrap \
FLOW_FAIL_ON_NON2XX=1 \
FLOW_LOG_EVERY=0 \
./wrk -t2 -c5 -R500 -d20s -s workdir/v2.0/flow_executor_templates.lua http://localhost:9966/
```

```text
Env vars:
  FLOW_DATA_DIR        default: workdir/v2.0/data
  FLOW_STAGE           default: lifecycle
  FLOW_API_PREFIX      default: /petclinic/api
  FLOW_REUSE_MODE      default: wrap   (wrap | stop)
  FLOW_FAIL_ON_NON2XX  default: 1      (1 | 0)
  FLOW_LOG_EVERY       default: 0      (prints every N responses)
  FLOW_IDLE_PATH       default: /owners
```