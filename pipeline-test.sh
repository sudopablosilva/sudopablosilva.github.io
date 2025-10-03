#!/bin/bash
set -euo pipefail

echo "🚀 PIPELINE PERFORMANCE TEST: 15 Minute Multi-Step Load Test"
echo "============================================================="
echo "Service1: localhost:8080 → SQS1 → Service2: localhost:8081 → SQS2 → Service3: localhost:8082"
echo "Target: 15 minutes of continuous pipeline load with 20% error injection"
echo ""

# --- helpers --------------------------------------------------------
kill_on_ports() {
  local pids
  pids=$(lsof -tiTCP:8080,8081,8082 -sTCP:LISTEN || true)
  if [[ -n "${pids}" ]]; then
    echo "🔪 Stopping previous services on 8080/8081/8082..."
    kill -15 ${pids} 2>/dev/null || true
    sleep 1
    kill -9 ${pids} 2>/dev/null || true
  fi
}

start_service() {
  local bin="$1" log="$2"
  "$bin" >"$log" 2>&1 &
  echo $!
}

cleanup() {
  echo ""
  echo "🧹 Cleaning up pipeline services..."
  [[ -n "${S1_PID:-}" ]] && kill -15 "$S1_PID" 2>/dev/null || true
  [[ -n "${S2_PID:-}" ]] && kill -15 "$S2_PID" 2>/dev/null || true
  [[ -n "${S3_PID:-}" ]] && kill -15 "$S3_PID" 2>/dev/null || true
  sleep 1
  [[ -n "${S1_PID:-}" ]] && kill -9 "$S1_PID" 2>/dev/null || true
  [[ -n "${S2_PID:-}" ]] && kill -9 "$S2_PID" 2>/dev/null || true
  [[ -n "${S3_PID:-}" ]] && kill -9 "$S3_PID" 2>/dev/null || true
}
trap cleanup EXIT
# -------------------------------------------------------------------

# Clear previous logs in service directories
: > service1/service1.log
: > service2/service2.log
: > service3/service3.log

# Stop anything currently on our ports
kill_on_ports

echo "🔄 Starting pipeline services..."
S1_PID=$(start_service "./service1/main" "service1/service1.log")
S2_PID=$(start_service "./service2/main" "service2/service2.log")
S3_PID=$(start_service "./service3/main" "service3/service3.log")

sleep 3
echo "✅ Pipeline services started:"
echo "   Service1 PID: $S1_PID (Port 8080)"
echo "   Service2 PID: $S2_PID (Port 8081)"
echo "   Service3 PID: $S3_PID (Port 8082)"
echo ""

# Performance test parameters
TEST_DURATION=900  # 15 minutes in seconds
MESSAGES_PER_MINUTE=60
BATCH_SIZE=10
BATCH_INTERVAL=10  # seconds between batches

echo "📊 Pipeline Test Configuration:"
echo "   • Test Duration: 15 minutes"
echo "   • Messages per minute: $MESSAGES_PER_MINUTE"
echo "   • Batch Size: $BATCH_SIZE"
echo "   • Batch Interval: ${BATCH_INTERVAL}s"
echo "   • Error Injection: 20% of messages"
echo ""

START_TIME=$(date +%s)
echo "⏱️  Pipeline test started at: $(date)"
echo ""

# Limit background curl fan-out
limit_jobs() {
  local max="$1"
  while (( $(jobs -rp | wc -l | tr -d ' ') >= max )); do
    wait -n
  done
}

send_batch() {
  local batch_num=$1
  local start_msg=$(( (batch_num - 1) * BATCH_SIZE + 1 ))
  local end_msg=$(( batch_num * BATCH_SIZE ))
  local error_count=0

  echo "📦 Pipeline Batch $batch_num: Messages $start_msg-$end_msg"

  for i in $(seq "$start_msg" "$end_msg"); do
    limit_jobs 100

    # Generate correlation ID for pipeline flow
    CORRELATION_ID="pipeline-$(date +%s%N | cut -b1-13)-$i"

    # Send message with random error injection (20% chance)
    RAND_NUM=$((RANDOM % 100))
    if (( RAND_NUM < 20 )); then
      curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" -H "X-Inject-Error: true" http://localhost:8080/send-message > /dev/null &
      ((error_count++))
    else
      curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" http://localhost:8080/send-message > /dev/null &
    fi

    # Health checks for all services
    if (( i % 5 == 0 )); then
      curl -sS -m 5 http://localhost:8080/ > /dev/null &
      curl -sS -m 5 http://localhost:8081/ > /dev/null &
      curl -sS -m 5 http://localhost:8082/ > /dev/null &
    fi
  done

  # Wait for batch to complete
  wait
  if (( error_count > 0 )); then
    echo "   ✅ Batch $batch_num completed (🔥 $error_count errors injected)"
  else
    echo "   ✅ Batch $batch_num completed"
  fi
}

batch_num=1
TOTAL_MESSAGES=0

while true; do
  current_time=$(date +%s)
  elapsed=$(( current_time - START_TIME ))
  
  # Check if 15 minutes have passed
  if (( elapsed >= TEST_DURATION )); then
    echo "⏰ 15 minutes completed, stopping pipeline test..."
    break
  fi
  
  send_batch "$batch_num"
  TOTAL_MESSAGES=$(( TOTAL_MESSAGES + BATCH_SIZE ))
  
  remaining=$(( TEST_DURATION - elapsed ))
  minutes_remaining=$(( remaining / 60 ))
  seconds_remaining=$(( remaining % 60 ))
  
  # Quick pipeline status check
  STEP1_COMPLETED=$(grep -c "Step1 completed" service1/service1.log 2>/dev/null || echo "0")
  STEP2_COMPLETED=$(grep -c "Step2 completed" service2/service2.log 2>/dev/null || echo "0")
  STEP3_COMPLETED=$(grep -c "Pipeline completed" service3/service3.log 2>/dev/null || echo "0")
  PIPELINE_ERRORS=$(grep -c "Error injection" service1/service1.log 2>/dev/null || echo "0")
  
  echo "   📈 Progress: ${elapsed}s elapsed, ${minutes_remaining}m ${seconds_remaining}s remaining"
  echo "   📊 Pipeline Status: $TOTAL_MESSAGES sent → $STEP1_COMPLETED step1 → $STEP2_COMPLETED step2 → $STEP3_COMPLETED completed (🔥 $PIPELINE_ERRORS errors)"
  echo ""
  
  batch_num=$(( batch_num + 1 ))
  sleep "$BATCH_INTERVAL"
done

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
THR=$(( TOTAL_MESSAGES / (DURATION > 0 ? DURATION : 1) ))

echo "🎉 15-MINUTE PIPELINE PERFORMANCE TEST COMPLETED!"
echo "==============================================="
echo "⏱️  Total Duration: ${DURATION}s (15 minutes)"
echo "📊 Messages Sent: $TOTAL_MESSAGES"
echo "🚀 Average Throughput: ${THR} messages/second"
echo ""

echo "📈 Final Pipeline Results:"
echo "Step1 completions: $(grep -c "Step1 completed" service1/service1.log || echo 0)"
echo "Step2 completions: $(grep -c "Step2 completed" service2/service2.log || echo 0)"
echo "Step3 completions: $(grep -c "Pipeline completed" service3/service3.log || echo 0)"
echo "Pipeline errors: $(grep -c "Error injection" service1/service1.log || echo 0)"
echo "Step2 failures: $(grep -c "Step2 processing failed" service2/service2.log || echo 0)"
echo ""
echo "🎯 Pipeline performance test complete! Check Datadog dashboard for:"
echo "   • Step-by-step duration analysis (P95 latencies)"
echo "   • End-to-end pipeline performance"
echo "   • Inter-step queue latency tracking"
echo "   • Error propagation through pipeline steps"
echo "   • Pipeline throughput and success rates"
echo ""
echo "Pipeline services left running for continued monitoring..."
echo "Service1 PID: $S1_PID | Service2 PID: $S2_PID | Service3 PID: $S3_PID"