#!/bin/bash
set -euo pipefail

echo "🚀 MULTI-SHARD PIPELINE TEST: 10 Minute Load Test Across All Shards"
echo "=================================================================="
echo "Shard-baseline: localhost:8080-8082"
echo "Shard-1:        localhost:8090-8092" 
echo "Shard-2:        localhost:8100-8102"
echo "Target: 10 minutes of continuous pipeline load with 20% error injection"
echo ""

# Test parameters
TEST_DURATION=600  # 10 minutes
MESSAGES_PER_MINUTE=60
BATCH_SIZE=10
BATCH_INTERVAL=10

# Shard configurations
SHARDS=(
    "shard-baseline:8080"
    "shard-1:8090"
    "shard-2:8100"
)

START_TIME=$(date +%s)
echo "⏱️  Multi-shard test started at: $(date)"
echo ""

# Function to send batch to specific shard
send_shard_batch() {
    local shard_name=$1
    local port=$2
    local batch_num=$3
    local start_msg=$(( (batch_num - 1) * BATCH_SIZE + 1 ))
    local end_msg=$(( batch_num * BATCH_SIZE ))
    local error_count=0

    echo "📦 $shard_name Batch $batch_num: Messages $start_msg-$end_msg"

    for i in $(seq "$start_msg" "$end_msg"); do
        CORRELATION_ID="$shard_name-$(date +%s%N | cut -b1-13)-$i"
        
        # 20% error injection
        RAND_NUM=$((RANDOM % 100))
        if (( RAND_NUM < 20 )); then
            curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" -H "X-Inject-Error: true" http://localhost:$port/send-message > /dev/null &
            ((error_count++))
        else
            curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" http://localhost:$port/send-message > /dev/null &
        fi

        # Health checks
        if (( i % 5 == 0 )); then
            curl -sS -m 5 http://localhost:$port/ > /dev/null &
            curl -sS -m 5 http://localhost:$((port + 1))/ > /dev/null &
            curl -sS -m 5 http://localhost:$((port + 2))/ > /dev/null &
        fi
    done

    wait
    if (( error_count > 0 )); then
        echo "   ✅ $shard_name Batch $batch_num completed (🔥 $error_count errors injected)"
    else
        echo "   ✅ $shard_name Batch $batch_num completed"
    fi
}

batch_num=1
TOTAL_MESSAGES=0

while true; do
    current_time=$(date +%s)
    elapsed=$(( current_time - START_TIME ))
    
    if (( elapsed >= TEST_DURATION )); then
        echo "⏰ 10 minutes completed, stopping multi-shard test..."
        break
    fi
    
    # Send batches to all shards in parallel
    for shard_config in "${SHARDS[@]}"; do
        IFS=':' read -r shard_name port <<< "$shard_config"
        send_shard_batch "$shard_name" "$port" "$batch_num" &
    done
    
    wait  # Wait for all shard batches to complete
    
    TOTAL_MESSAGES=$(( TOTAL_MESSAGES + BATCH_SIZE * ${#SHARDS[@]} ))
    
    remaining=$(( TEST_DURATION - elapsed ))
    minutes_remaining=$(( remaining / 60 ))
    seconds_remaining=$(( remaining % 60 ))
    
    echo "   📈 Progress: ${elapsed}s elapsed, ${minutes_remaining}m ${seconds_remaining}s remaining"
    echo "   📊 Total Messages Sent: $TOTAL_MESSAGES across ${#SHARDS[@]} shards"
    echo ""
    
    batch_num=$(( batch_num + 1 ))
    sleep "$BATCH_INTERVAL"
done

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
THR=$(( TOTAL_MESSAGES / (DURATION > 0 ? DURATION : 1) ))

echo "🎉 10-MINUTE MULTI-SHARD PIPELINE TEST COMPLETED!"
echo "================================================"
echo "⏱️  Total Duration: ${DURATION}s (10 minutes)"
echo "📊 Messages Sent: $TOTAL_MESSAGES across ${#SHARDS[@]} shards"
echo "🚀 Average Throughput: ${THR} messages/second"
echo ""
echo "🎯 Multi-shard performance test complete! Check Datadog dashboard for:"
echo "   • Shard-by-shard performance comparison"
echo "   • Per-shard latency analysis (P95 latencies)"
echo "   • Cross-shard pipeline performance"
echo "   • Shard-specific error rates and success rates"
echo "   • Individual shard throughput metrics"
echo ""
echo "All shards continue running for extended monitoring..."