#!/bin/bash

# Multi-Service Pipeline Management Script
# Usage: ./manage-services.sh [start|stop|restart|status|logs]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE1_DIR="$SCRIPT_DIR/service1"
SERVICE2_DIR="$SCRIPT_DIR/service2"
SERVICE2_SLOW_DIR="$SCRIPT_DIR/service2-slow"
SERVICE3_DIR="$SCRIPT_DIR/service3"

# PID files
PID_DIR="$SCRIPT_DIR/.pids"
mkdir -p "$PID_DIR"
SERVICE1_PID="$PID_DIR/service1.pid"
SERVICE2_PID="$PID_DIR/service2.pid"
SERVICE2_SLOW_PID="$PID_DIR/service2-slow.pid"
SERVICE3_PID="$PID_DIR/service3.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if a service is running
is_running() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$pid_file"
            return 1
        fi
    fi
    return 1
}

# Build a single service
build_service() {
    local service_name="$1"
    local service_dir="$2"
    
    log "Building $service_name..."
    cd "$service_dir"
    
    if go build -o main main.go; then
        success "$service_name built successfully"
        return 0
    else
        error "$service_name build failed"
        return 1
    fi
}

# Start a single service
start_service() {
    local service_name="$1"
    local service_dir="$2"
    local pid_file="$3"
    local port="$4"
    local use_binary="${5:-false}"
    
    if is_running "$pid_file"; then
        warn "$service_name is already running (PID: $(cat "$pid_file"))"
        return 0
    fi
    
    log "Starting $service_name..."
    cd "$service_dir"
    
    # Start the service and capture PID
    if [[ "$use_binary" == "true" && -f "main" ]]; then
        ./main > "${service_name}.log" 2>&1 &
    else
        go run main.go > "${service_name}.log" 2>&1 &
    fi
    local pid=$!
    echo "$pid" > "$pid_file"
    
    # Wait a moment and check if it's still running
    sleep 2
    if is_running "$pid_file"; then
        success "$service_name started successfully (PID: $pid, Port: $port)"
        return 0
    else
        error "$service_name failed to start"
        return 1
    fi
}

# Stop a single service
stop_service() {
    local service_name="$1"
    local pid_file="$2"
    
    if ! is_running "$pid_file"; then
        warn "$service_name is not running"
        return 0
    fi
    
    local pid=$(cat "$pid_file")
    log "Stopping $service_name (PID: $pid)..."
    
    # Try graceful shutdown first
    if kill -TERM "$pid" 2>/dev/null; then
        # Wait up to 5 seconds for graceful shutdown
        for i in {1..5}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            warn "Graceful shutdown failed, force killing $service_name"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    
    rm -f "$pid_file"
    success "$service_name stopped"
}

# Build all services
build_all() {
    log "Building all pipeline services..."
    
    build_service "service1" "$SERVICE1_DIR"
    build_service "service2" "$SERVICE2_DIR"
    build_service "service3" "$SERVICE3_DIR"
    
    success "All services built successfully!"
}

# Start all services
start_all() {
    local use_binary="${1:-false}"
    log "Starting all pipeline services..."
    
    # Kill any existing processes on the ports
    log "Checking for existing processes on ports 8080, 8081, 8082..."
    local existing_pids=$(lsof -tiTCP:8080,8081,8082 -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$existing_pids" ]]; then
        warn "Found existing processes on target ports, stopping them..."
        echo "$existing_pids" | xargs kill -TERM 2>/dev/null || true
        sleep 2
        echo "$existing_pids" | xargs kill -KILL 2>/dev/null || true
    fi
    
    # Start services in order
    start_service "service1" "$SERVICE1_DIR" "$SERVICE1_PID" "8080" "$use_binary"
    start_service "service2" "$SERVICE2_DIR" "$SERVICE2_PID" "8081" "$use_binary"
    start_service "service3" "$SERVICE3_DIR" "$SERVICE3_PID" "8082" "$use_binary"
    
    echo ""
    success "All services started successfully!"
    echo ""
    log "Service URLs:"
    echo "  • Service1: http://localhost:8080"
    echo "  • Service2: http://localhost:8081"
    echo "  • Service3: http://localhost:8082"
    echo ""
    log "Log files:"
    echo "  • Service1: $SERVICE1_DIR/service1.log"
    echo "  • Service2: $SERVICE2_DIR/service2.log"
    echo "  • Service3: $SERVICE3_DIR/service3.log"
}

# Stop all services
stop_all() {
    log "Stopping all pipeline services..."
    
    stop_service "service1" "$SERVICE1_PID"
    stop_service "service2" "$SERVICE2_PID"
    stop_service "service3" "$SERVICE3_PID"
    
    # Clean up any remaining processes
    local remaining_pids=$(lsof -tiTCP:8080,8081,8082 -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$remaining_pids" ]]; then
        warn "Cleaning up remaining processes..."
        echo "$remaining_pids" | xargs kill -KILL 2>/dev/null || true
    fi
    
    success "All services stopped"
}

# Show service status
show_status() {
    echo ""
    log "Pipeline Services Status:"
    echo "========================="
    
    local all_running=true
    
    # Check each service
    for service in "service1:$SERVICE1_PID:8080" "service2:$SERVICE2_PID:8081" "service3:$SERVICE3_PID:8082"; do
        IFS=':' read -r name pid_file port <<< "$service"
        
        if is_running "$pid_file"; then
            local pid=$(cat "$pid_file")
            echo -e "  ${GREEN}●${NC} $name (PID: $pid, Port: $port) - ${GREEN}RUNNING${NC}"
        else
            echo -e "  ${RED}●${NC} $name (Port: $port) - ${RED}STOPPED${NC}"
            all_running=false
        fi
    done
    
    echo ""
    if $all_running; then
        success "All services are running"
    else
        warn "Some services are not running"
    fi
    
    # Show recent log entries
    echo ""
    log "Recent log entries (last 3 lines per service):"
    echo "=============================================="
    
    for service_dir in "$SERVICE1_DIR" "$SERVICE2_DIR" "$SERVICE3_DIR"; do
        local service_name=$(basename "$service_dir")
        local log_file="$service_dir/${service_name}.log"
        
        if [[ -f "$log_file" ]]; then
            echo ""
            echo -e "${BLUE}$service_name:${NC}"
            tail -3 "$log_file" 2>/dev/null | sed 's/^/  /' || echo "  No recent logs"
        else
            echo ""
            echo -e "${BLUE}$service_name:${NC}"
            echo "  Log file not found"
        fi
    done
}

# Show logs
show_logs() {
    local service="$1"
    local lines="${2:-20}"
    
    case "$service" in
        "1"|"service1")
            log "Service1 logs (last $lines lines):"
            tail -"$lines" "$SERVICE1_DIR/service1.log" 2>/dev/null || echo "No logs found"
            ;;
        "2"|"service2")
            log "Service2 logs (last $lines lines):"
            tail -"$lines" "$SERVICE2_DIR/service2.log" 2>/dev/null || echo "No logs found"
            ;;
        "3"|"service3")
            log "Service3 logs (last $lines lines):"
            tail -"$lines" "$SERVICE3_DIR/service3.log" 2>/dev/null || echo "No logs found"
            ;;
        "all"|"")
            for i in 1 2 3; do
                echo ""
                show_logs "$i" "$lines"
            done
            ;;
        *)
            error "Invalid service: $service. Use 1, 2, 3, or 'all'"
            exit 1
            ;;
    esac
}

# Main command handling
case "${1:-}" in
    "build")
        build_all
        ;;
    "start")
        start_all
        ;;
    "start-built")
        start_all true
        ;;
    "stop")
        stop_all
        ;;
    "restart")
        stop_all
        sleep 2
        start_all
        ;;
    "rebuild")
        stop_all
        build_all
        start_all true
        ;;
    "status")
        show_status
        ;;
    "logs")
        show_logs "${2:-all}" "${3:-20}"
        ;;
    "test")
        log "Testing pipeline with a single request..."
        if ! is_running "$SERVICE1_PID"; then
            error "Service1 is not running. Start services first with: $0 start"
            exit 1
        fi
        
        CORRELATION_ID="test-$(date +%s)"
        log "Sending test request with correlation ID: $CORRELATION_ID"
        
        curl -s -X POST \
            -H "X-Correlation-ID: $CORRELATION_ID" \
            -H "Content-Type: application/json" \
            http://localhost:8080/send-message
        
        echo ""
        log "Test request sent. Check logs with: $0 logs"
        ;;
    "test-error")
        log "Testing pipeline with error injection..."
        if ! is_running "$SERVICE1_PID"; then
            error "Service1 is not running. Start services first with: $0 start"
            exit 1
        fi
        
        CORRELATION_ID="test-error-$(date +%s)"
        log "Sending test request with error injection and correlation ID: $CORRELATION_ID"
        
        curl -s -X POST \
            -H "X-Correlation-ID: $CORRELATION_ID" \
            -H "X-Inject-Error: true" \
            -H "Content-Type: application/json" \
            http://localhost:8080/send-message
        
        echo ""
        log "Error test request sent. Check logs with: $0 logs"
        ;;
    "load-test")
        log "Starting 15-minute pipeline load test..."
        if ! is_running "$SERVICE1_PID"; then
            error "Services not running. Start with: $0 start"
            exit 1
        fi
        
        # Test parameters
        TEST_DURATION=900  # 15 minutes
        MESSAGES_PER_MINUTE=60
        BATCH_SIZE=10
        BATCH_INTERVAL=10
        
        echo "📊 Load Test Configuration:"
        echo "   • Duration: 15 minutes"
        echo "   • Messages/minute: $MESSAGES_PER_MINUTE"
        echo "   • Batch size: $BATCH_SIZE"
        echo "   • Error injection: 20%"
        echo ""
        
        START_TIME=$(date +%s)
        batch_num=1
        TOTAL_MESSAGES=0
        
        # Limit concurrent jobs
        limit_jobs() {
            local max="$1"
            while (( $(jobs -rp | wc -l | tr -d ' ') >= max )); do
                wait -n
            done
        }
        
        while true; do
            current_time=$(date +%s)
            elapsed=$(( current_time - START_TIME ))
            
            if (( elapsed >= TEST_DURATION )); then
                log "15 minutes completed, stopping load test..."
                break
            fi
            
            log "Batch $batch_num: Sending $BATCH_SIZE messages..."
            
            for i in $(seq 1 $BATCH_SIZE); do
                limit_jobs 50
                
                CORRELATION_ID="load-test-$(date +%s%N | cut -b1-13)-$i"
                
                # 20% error injection
                if (( RANDOM % 100 < 20 )); then
                    curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" -H "X-Inject-Error: true" http://localhost:8080/send-message > /dev/null &
                else
                    curl -sS -m 5 -X POST -H "X-Correlation-ID: $CORRELATION_ID" http://localhost:8080/send-message > /dev/null &
                fi
            done
            
            wait
            TOTAL_MESSAGES=$(( TOTAL_MESSAGES + BATCH_SIZE ))
            
            # Status update
            remaining=$(( TEST_DURATION - elapsed ))
            minutes_remaining=$(( remaining / 60 ))
            
            STEP1_COMPLETED=$(grep -c "Step1 completed" "$SERVICE1_DIR/service1.log" 2>/dev/null || echo "0")
            STEP3_COMPLETED=$(grep -c "Pipeline completed" "$SERVICE3_DIR/service3.log" 2>/dev/null || echo "0")
            
            log "Progress: ${elapsed}s elapsed, ${minutes_remaining}m remaining | Sent: $TOTAL_MESSAGES | Completed: $STEP3_COMPLETED"
            
            batch_num=$(( batch_num + 1 ))
            sleep "$BATCH_INTERVAL"
        done
        
        END_TIME=$(date +%s)
        DURATION=$(( END_TIME - START_TIME ))
        
        echo ""
        success "15-minute load test completed!"
        echo "Messages sent: $TOTAL_MESSAGES"
        echo "Duration: ${DURATION}s"
        echo "Throughput: $(( TOTAL_MESSAGES / (DURATION > 0 ? DURATION : 1) )) msg/s"
        echo ""
        log "Final results:"
        echo "Step1 completed: $(grep -c "Step1 completed" "$SERVICE1_DIR/service1.log" || echo 0)"
        echo "Pipeline completed: $(grep -c "Pipeline completed" "$SERVICE3_DIR/service3.log" || echo 0)"
        echo "Errors injected: $(grep -c "Error injection" "$SERVICE1_DIR/service1.log" || echo 0)"
        ;;
    "start-slow")
        log "Starting services with degraded service2..."
        # Kill any existing processes on the ports
        log "Checking for existing processes on ports 8080, 8081, 8082..."
        existing_pids=$(lsof -tiTCP:8080,8081,8082 -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$existing_pids" ]]; then
            warn "Found existing processes on target ports, stopping them..."
            echo "$existing_pids" | xargs kill -TERM 2>/dev/null || true
            sleep 2
            echo "$existing_pids" | xargs kill -KILL 2>/dev/null || true
        fi
        
        # Start services with slow service2
        start_service "service1" "$SERVICE1_DIR" "$SERVICE1_PID" "8080" "false"
        start_service "service2-slow" "$SERVICE2_SLOW_DIR" "$SERVICE2_SLOW_PID" "8082" "false"
        start_service "service3" "$SERVICE3_DIR" "$SERVICE3_PID" "8081" "false"
        
        echo ""
        success "Services started with degraded service2!"
        echo ""
        log "Service URLs:"
        echo "  • Service1: http://localhost:8080"
        echo "  • Service2-Slow: http://localhost:8082 (DEGRADED PERFORMANCE)"
        echo "  • Service3: http://localhost:8081"
        echo ""
        log "Log files:"
        echo "  • Service1: $SERVICE1_DIR/service1.log"
        echo "  • Service2-Slow: $SERVICE2_SLOW_DIR/service2-slow.log"
        echo "  • Service3: $SERVICE3_DIR/service3.log"
        ;;
    "start-parallel")
        log "Starting all services with parallel service2 versions for comparison..."
        # Kill any existing processes on the ports
        log "Checking for existing processes on ports 8080, 8081, 8082, 8083..."
        existing_pids=$(lsof -tiTCP:8080,8081,8082,8083 -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$existing_pids" ]]; then
            warn "Found existing processes on target ports, stopping them..."
            echo "$existing_pids" | xargs kill -TERM 2>/dev/null || true
            sleep 2
            echo "$existing_pids" | xargs kill -KILL 2>/dev/null || true
        fi
        
        # Start all services with both service2 versions
        start_service "service1" "$SERVICE1_DIR" "$SERVICE1_PID" "8080" "false"
        start_service "service2" "$SERVICE2_DIR" "$SERVICE2_PID" "8081" "false"
        start_service "service2-slow" "$SERVICE2_SLOW_DIR" "$SERVICE2_SLOW_PID" "8082" "false"
        start_service "service3" "$SERVICE3_DIR" "$SERVICE3_PID" "8083" "false"
        
        echo ""
        success "All services started with parallel service2 versions!"
        echo ""
        log "Service URLs:"
        echo "  • Service1: http://localhost:8080"
        echo "  • Service2 (Normal): http://localhost:8081"
        echo "  • Service2-Slow: http://localhost:8082 (DEGRADED PERFORMANCE)"
        echo "  • Service3: http://localhost:8083"
        echo ""
        log "Log files:"
        echo "  • Service1: $SERVICE1_DIR/service1.log"
        echo "  • Service2: $SERVICE2_DIR/service2.log"
        echo "  • Service2-Slow: $SERVICE2_SLOW_DIR/service2-slow.log"
        echo "  • Service3: $SERVICE3_DIR/service3.log"
        echo ""
        log "Both service2 versions process the same SQS queues - compare performance in Datadog!"
        ;;
    "start-optimized")
        log "Starting optimized v1.2.0 services with reduced latency..."
        # Kill any existing processes on the ports
        log "Checking for existing processes on ports 8080, 8081, 8082..."
        existing_pids=$(lsof -tiTCP:8080,8081,8082 -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$existing_pids" ]]; then
            warn "Found existing processes on target ports, stopping them..."
            echo "$existing_pids" | xargs kill -TERM 2>/dev/null || true
            sleep 2
            echo "$existing_pids" | xargs kill -KILL 2>/dev/null || true
        fi
        
        # Build and start optimized services
        build_service "service1" "$SERVICE1_DIR"
        build_service "service2" "$SERVICE2_DIR"
        build_service "service3" "$SERVICE3_DIR"
        
        start_service "service1" "$SERVICE1_DIR" "$SERVICE1_PID" "8080" "true"
        start_service "service2" "$SERVICE2_DIR" "$SERVICE2_PID" "8081" "true"
        start_service "service3" "$SERVICE3_DIR" "$SERVICE3_PID" "8082" "true"
        
        echo ""
        success "Optimized v1.2.0 services started!"
        echo ""
        log "Service URLs:"
        echo "  • Service1: http://localhost:8080 (v1.2.0)"
        echo "  • Service2: http://localhost:8081 (v1.2.0)"
        echo "  • Service3: http://localhost:8082 (v1.2.0)"
        echo ""
        log "Performance improvements:"
        echo "  • Service1: 50ms → 20ms (-60%)"
        echo "  • Service2: 75ms → 30ms (-60%)"
        echo "  • Service3: 100ms → 40ms (-60%)"
        echo "  • Total pipeline: ~225ms → ~90ms (-60%)"
        ;;
    "help"|"-h"|"--help"|"")
        echo "Multi-Service Pipeline Management Script"
        echo ""
        echo "Usage: $0 [COMMAND] [OPTIONS]"
        echo ""
        echo "Commands:"
        echo "  build         Build all services (creates binaries)"
        echo "  start         Start all services (using go run)"
        echo "  start-built   Start all services (using pre-built binaries)"
        echo "  start-slow    Start services with degraded service2 (for performance comparison)"
        echo "  start-parallel Start all services with both service2 versions in parallel for comparison"
        echo "  start-optimized Start optimized v1.2.0 services with reduced latency"
        echo "  rebuild       Stop, build, and start all services"
        echo "  stop          Stop all services"
        echo "  restart       Restart all services"
        echo "  status        Show service status and recent logs"
        echo "  logs [SERVICE] [LINES]  Show logs (SERVICE: 1,2,3,all; default: all, 20 lines)"
        echo "  test          Send a test request through the pipeline"
        echo "  test-error    Send a test request with error injection"
        echo "  load-test     Run 15-minute pipeline load test"
        echo "  help          Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 start                 # Start all services"
        echo "  $0 start-slow           # Start with degraded service2"
        echo "  $0 logs 2 50            # Show last 50 lines of service2 logs"
        echo "  $0 test                 # Send a test request"
        echo "  $0 load-test            # Run 15-minute performance test"
        echo "  $0 start-optimized      # Start optimized v1.2.0 services"
        ;;
    *)
        error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac