#!/bin/bash

# Multi-Service Pipeline Shard Management Script
# Usage: ./manage-services-shard.sh [start-shard|stop-shard|compare-shards|list-shards] [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE1_DIR="$SCRIPT_DIR/service1"
SERVICE2_DIR="$SCRIPT_DIR/service2"
SERVICE3_DIR="$SCRIPT_DIR/service3"

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

# Função para calcular porta base por shard
get_port_base() {
    local shard_id="$1"
    case "$shard_id" in
        "shard-baseline") echo "8080" ;;
        "shard-1") echo "8090" ;;
        "shard-2") echo "8100" ;;
        "shard-3") echo "8110" ;;
        *) 
            local num=$(echo "$shard_id" | grep -o '[0-9]*' | head -1)
            if [[ -n "$num" ]]; then
                echo $((8080 + num * 10))
            else
                echo "8080"
            fi
            ;;
    esac
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

# Função para iniciar serviço com variáveis de ambiente
start_service_with_env() {
    local service_name="$1"
    local service_dir="$2"
    local port="$3"
    local shard_id="$4"
    
    log "Starting $service_name on port $port with shard $shard_id..."
    cd "$service_dir"
    
    # Definir variável de porta específica do serviço
    case "$service_name" in
        "service1") export SERVICE1_PORT="$port" ;;
        "service2") export SERVICE2_PORT="$port" ;;
        "service3") export SERVICE3_PORT="$port" ;;
    esac
    
    # Iniciar serviço com variáveis de ambiente
    nohup env SHARD_ID="$shard_id" ./main > "${service_name}-${shard_id}.log" 2>&1 &
    local pid=$!
    
    # Aguardar inicialização
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        success "$service_name started successfully (PID: $pid, Port: $port, Shard: $shard_id)"
    else
        error "$service_name failed to start"
        return 1
    fi
    
    cd - > /dev/null
}

# Função para iniciar serviços por shard
start_shard() {
    local shard_id="$1"
    if [[ -z "$shard_id" ]]; then
        echo "Usage: $0 start-shard <shard-id>"
        echo "Examples:"
        echo "  $0 start-shard shard-baseline"
        echo "  $0 start-shard shard-1"
        echo "  $0 start-shard shard-2"
        exit 1
    fi
    
    local port_base=$(get_port_base "$shard_id")
    local service1_port=$port_base
    local service2_port=$((port_base + 1))
    local service3_port=$((port_base + 2))
    
    log "Starting services for shard: $shard_id"
    log "Port mapping: Service1:$service1_port, Service2:$service2_port, Service3:$service3_port"
    
    # Verificar se portas estão disponíveis
    for port in $service1_port $service2_port $service3_port; do
        if lsof -ti:$port > /dev/null 2>&1; then
            warn "Port $port is already in use"
            echo "Stopping existing processes on ports $service1_port-$service3_port..."
            lsof -ti:$service1_port,$service2_port,$service3_port | xargs kill -TERM 2>/dev/null || true
            sleep 2
            break
        fi
    done
    
    # Build services
    build_service "service1" "$SERVICE1_DIR"
    build_service "service2" "$SERVICE2_DIR"
    build_service "service3" "$SERVICE3_DIR"
    
    # Start services com variáveis de ambiente específicas do shard
    start_service_with_env "service1" "$SERVICE1_DIR" "$service1_port" "$shard_id"
    start_service_with_env "service2" "$SERVICE2_DIR" "$service2_port" "$shard_id"
    start_service_with_env "service3" "$SERVICE3_DIR" "$service3_port" "$shard_id"
    
    echo ""
    success "All services started for shard: $shard_id"
    echo ""
    log "Service URLs:"
    echo "  • Service1: http://localhost:$service1_port (shard: $shard_id)"
    echo "  • Service2: http://localhost:$service2_port (shard: $shard_id)"
    echo "  • Service3: http://localhost:$service3_port (shard: $shard_id)"
    echo ""
    log "Test command:"
    echo "  curl -X POST -H \"X-Correlation-ID: test-$shard_id\" http://localhost:$service1_port/send-message"
}

# Função para comparar shards
compare_shards() {
    local shard1="$1"
    local shard2="$2"
    
    if [[ -z "$shard1" || -z "$shard2" ]]; then
        echo "Usage: $0 compare-shards <shard1> <shard2>"
        exit 1
    fi
    
    log "Comparing performance between $shard1 and $shard2"
    
    local port1=$(get_port_base "$shard1")
    local port2=$(get_port_base "$shard2")
    
    echo "Testing $shard1 (port $port1)..."
    time curl -s -X POST -H "X-Correlation-ID: compare-$shard1" http://localhost:$port1/send-message
    
    echo "Testing $shard2 (port $port2)..."
    time curl -s -X POST -H "X-Correlation-ID: compare-$shard2" http://localhost:$port2/send-message
    
    echo ""
    log "Check Datadog for detailed comparison:"
    echo "  • Metrics: sli.pipeline.duration{shard:$shard1} vs sli.pipeline.duration{shard:$shard2}"
    echo "  • Logs: @shard:$shard1 vs @shard:$shard2"
    echo "  • Traces: shard:$shard1 vs shard:$shard2"
}

# Função para parar shard específico
stop_shard() {
    local shard_id="$1"
    if [[ -z "$shard_id" ]]; then
        echo "Usage: $0 stop-shard <shard-id>"
        exit 1
    fi
    
    local port_base=$(get_port_base "$shard_id")
    local ports="$port_base,$((port_base + 1)),$((port_base + 2))"
    
    log "Stopping services for shard: $shard_id (ports: $ports)"
    
    local pids=$(lsof -ti:$ports 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill -TERM 2>/dev/null || true
        sleep 2
        echo "$pids" | xargs kill -KILL 2>/dev/null || true
        success "Stopped all services for shard: $shard_id"
    else
        warn "No services running for shard: $shard_id"
    fi
}

# Função para listar shards ativos
list_shards() {
    log "Active shards:"
    for port in $(seq 8080 10 8200); do
        if lsof -ti:$port > /dev/null 2>&1; then
            local shard_name=""
            case "$port" in
                "8080") shard_name="shard-baseline" ;;
                "8090") shard_name="shard-1" ;;
                "8100") shard_name="shard-2" ;;
                "8110") shard_name="shard-3" ;;
                *) shard_name="shard-$((($port - 8080) / 10))" ;;
            esac
            echo "  • $shard_name: ports $port-$((port + 2))"
        fi
    done
}

# Main command handling
case "${1:-}" in
    "start-shard")
        start_shard "$2"
        ;;
    "stop-shard")
        stop_shard "$2"
        ;;
    "compare-shards")
        compare_shards "$2" "$3"
        ;;
    "list-shards")
        list_shards
        ;;
    "help"|"-h"|"--help"|"")
        echo "Multi-Service Pipeline Shard Management"
        echo ""
        echo "Usage: $0 [COMMAND] [OPTIONS]"
        echo ""
        echo "Shard Commands:"
        echo "  start-shard <shard-id>     Start services for specific shard"
        echo "  stop-shard <shard-id>      Stop services for specific shard"
        echo "  compare-shards <s1> <s2>   Compare performance between shards"
        echo "  list-shards                List active shards"
        echo ""
        echo "Examples:"
        echo "  $0 start-shard shard-baseline    # Start baseline shard (ports 8080-8082)"
        echo "  $0 start-shard shard-1           # Start optimized shard (ports 8090-8092)"
        echo "  $0 compare-shards shard-baseline shard-1"
        echo "  $0 stop-shard shard-1"
        ;;
    *)
        error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac