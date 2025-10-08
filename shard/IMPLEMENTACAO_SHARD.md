# Implementação de Monitoramento por Shard

## Visão Geral

Implementação de monitoramento granular por shard para os serviços service1, service2 e service3, executando localmente em portas diferentes para simular múltiplos shards.

## Arquitetura de Portas por Shard

### Mapeamento de Portas
```
SHARD-BASELINE:
- Service1: 8080
- Service2: 8081  
- Service3: 8082

SHARD-1:
- Service1: 8090
- Service2: 8091
- Service3: 8092

SHARD-2:
- Service1: 8100
- Service2: 8101
- Service3: 8102

SHARD-N:
- Service1: 81X0
- Service2: 81X1
- Service3: 81X2
```

### Cálculo Automático de Portas
```bash
# Função para calcular porta base por shard
get_port_base() {
    local shard_id="$1"
    case "$shard_id" in
        "shard-baseline") echo "8080" ;;
        "shard-1") echo "8090" ;;
        "shard-2") echo "8100" ;;
        "shard-3") echo "8110" ;;
        *) 
            # Para shard-N, usar 8000 + (N * 10)
            local num=$(echo "$shard_id" | grep -o '[0-9]*')
            echo $((8080 + num * 10))
            ;;
    esac
}
```

## Configuração de Shard via Variável de Ambiente

### Variáveis Obrigatórias por Shard
```bash
# Shard Baseline
export SHARD_ID="shard-baseline"
export SERVICE1_PORT="8080"
export SERVICE2_PORT="8081"
export SERVICE3_PORT="8082"

# Shard-1 (Versão Otimizada)
export SHARD_ID="shard-1"
export SERVICE1_PORT="8090"
export SERVICE2_PORT="8091"
export SERVICE3_PORT="8092"

# Shard-2
export SHARD_ID="shard-2"
export SERVICE1_PORT="8100"
export SERVICE2_PORT="8101"
export SERVICE3_PORT="8102"
```

## Implementação nos Serviços

### Leitura de Configuração por Shard
```go
// Adicionar em cada main.go
var (
    shardID     string
    servicePort string
)

func init() {
    shardID = os.Getenv("SHARD_ID")
    if shardID == "" {
        shardID = "shard-default"
        log.Warn("SHARD_ID not set, using default")
    }
    
    // Service1: SERVICE1_PORT, Service2: SERVICE2_PORT, etc.
    servicePort = os.Getenv("SERVICE1_PORT") // Ajustar por serviço
    if servicePort == "" {
        servicePort = "8080" // Default port
    }
}

func main() {
    // Configurar tracer com shard
    tracer.Start(
        tracer.WithService("service1"),
        tracer.WithEnv("pipeline"),
        tracer.WithServiceVersion("1.2.0"),
        tracer.WithGlobalTag("shard", shardID),
        tracer.WithGlobalTag("port", servicePort),
    )
    defer tracer.Stop()
    
    // Iniciar servidor na porta específica do shard
    fmt.Printf("Service1 running on :%s (shard: %s)\n", servicePort, shardID)
    http.ListenAndServe(":"+servicePort, mux)
}
```

### Tags Obrigatórias em Spans
```go
// Todos os spans devem incluir
span.SetTag("shard", shardID)
span.SetTag("service.name", "service1")
span.SetTag("service.port", servicePort)
span.SetTag("correlation.id", correlationID)
span.SetTag("pipeline.step", 1)
```

### Logs Estruturados com Shard
```go
// Todos os logs devem incluir
log.WithFields(log.Fields{
    "dd.trace_id":    span.Context().TraceID(),
    "correlation.id": correlationID,
    "service":        "service1",
    "shard":          shardID,
    "port":           servicePort,
    "pipeline.step":  1,
    "duration_ms":    duration.Milliseconds(),
}).Info("Pipeline step completed")
```

### Métricas com Tag de Shard
```go
// Todas as métricas SLI devem incluir
statsdClient.Incr("sli.requests.total", []string{
    "service:service1",
    "shard:" + shardID,
    "port:" + servicePort,
    "version:1.2.0",
    "endpoint:/send-message"
}, 1)

statsdClient.Incr("sli.pipeline.success", []string{
    "pipeline:multi_service",
    "shard:" + shardID
}, 1)

statsdClient.Timing("sli.pipeline.duration", endToEndDuration, []string{
    "pipeline:multi_service",
    "shard:" + shardID
}, 1)
```

## Script de Gerenciamento Atualizado

### manage-services.sh - Implementação Completa
```bash
#!/bin/bash

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
    SHARD_ID="$shard_id" SERVICE1_PORT="$service1_port" start_service_with_env "service1" "$SERVICE1_DIR" "$service1_port"
    SHARD_ID="$shard_id" SERVICE2_PORT="$service2_port" start_service_with_env "service2" "$SERVICE2_DIR" "$service2_port"
    SHARD_ID="$shard_id" SERVICE3_PORT="$service3_port" start_service_with_env "service3" "$SERVICE3_DIR" "$service3_port"
    
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

# Função para iniciar serviço com variáveis de ambiente
start_service_with_env() {
    local service_name="$1"
    local service_dir="$2"
    local port="$3"
    
    log "Starting $service_name on port $port with shard $SHARD_ID..."
    cd "$service_dir"
    
    # Definir variável de porta específica do serviço
    case "$service_name" in
        "service1") export SERVICE1_PORT="$port" ;;
        "service2") export SERVICE2_PORT="$port" ;;
        "service3") export SERVICE3_PORT="$port" ;;
    esac
    
    # Iniciar serviço com variáveis de ambiente
    nohup env SHARD_ID="$SHARD_ID" ./main > "${service_name}-${SHARD_ID}.log" 2>&1 &
    local pid=$!
    
    # Aguardar inicialização
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        success "$service_name started successfully (PID: $pid, Port: $port, Shard: $SHARD_ID)"
    else
        error "$service_name failed to start"
        return 1
    fi
    
    cd - > /dev/null
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

# Atualizar case statement principal
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
```

## Queries Datadog com Filtro de Shard e Porta

### SLOs por Shard Específico
```sql
-- Pipeline Success Rate por Shard
(sum:sli.pipeline.success{shard:shard-1}.as_count())/(sum:sli.pipeline.total{shard:shard-1}.as_count())*100

-- Pipeline Duration por Shard
avg:sli.pipeline.duration{shard:shard-1}

-- Comparação de Performance Entre Shards
avg:sli.pipeline.duration{shard:shard-baseline} vs avg:sli.pipeline.duration{shard:shard-1}

-- Métricas por Porta (para debugging)
sum:sli.requests.total{port:8090} by {service}
```

### Alertas com Filtro de Shard
```yaml
# Alert: Performance Delta Entre Shards
query: |
  abs(avg:sli.pipeline.duration{shard:shard-baseline} - avg:sli.pipeline.duration{shard:shard-1}) > 100
message: |
  ⚠️ Performance delta between shards > 100ms
  Baseline: {{shard-baseline.last_value}}ms (ports 8080-8082)
  Shard-1: {{shard-1.last_value}}ms (ports 8090-8092)
  
# Alert: Shard Error Rate
query: |
  (sum:sli.pipeline.total{shard:shard-1} - sum:sli.pipeline.success{shard:shard-1})/sum:sli.pipeline.total{shard:shard-1}*100 > 1
message: |
  🚨 Pipeline error rate > 1% on {{shard.name}}
  Ports: Check services on 8090-8092
  Current: {{value}}%
```

## Processo de Deployment Gradual

### Fluxo Completo
```bash
# 1. Estabelecer baseline
./manage-services.sh start-shard shard-baseline
# Aguardar 24h para métricas baseline

# 2. Deploy versão otimizada
./manage-services.sh start-shard shard-1
# Monitorar por 2h

# 3. Comparar performance
./manage-services.sh compare-shards shard-baseline shard-1

# 4. Validar no Datadog
# - Verificar SLOs por shard
# - Comparar métricas de latência
# - Analisar logs por shard

# 5. Aprovar próximo shard (se validação OK)
./manage-services.sh start-shard shard-2

# 6. Rollback se necessário
./manage-services.sh stop-shard shard-2
```

## Validação de Implementação

### Checklist Obrigatório
- [ ] **SHARD_ID** definido via variável de ambiente
- [ ] **Portas específicas** por shard (8080+, 8090+, 8100+)
- [ ] **Todos os spans** contêm tags `shard` e `port`
- [ ] **Todos os logs** contêm campos `shard` e `port`
- [ ] **Todas as métricas SLI** contêm tags `shard:$SHARD_ID`
- [ ] **Script manage-services.sh** suporta comandos de shard
- [ ] **Logs separados** por shard (service1-shard-1.log)

### Comandos de Teste
```bash
# Iniciar múltiplos shards
./manage-services.sh start-shard shard-baseline
./manage-services.sh start-shard shard-1
./manage-services.sh start-shard shard-2

# Listar shards ativos
./manage-services.sh list-shards

# Testar cada shard
curl -X POST -H "X-Correlation-ID: test-baseline" http://localhost:8080/send-message
curl -X POST -H "X-Correlation-ID: test-shard1" http://localhost:8090/send-message
curl -X POST -H "X-Correlation-ID: test-shard2" http://localhost:8100/send-message

# Comparar performance
./manage-services.sh compare-shards shard-baseline shard-1

# Verificar no Datadog
# Métricas: sli.pipeline.duration{shard:shard-1}
# Logs: @shard:shard-1 @port:8090
# Traces: shard:shard-1
```

## Estrutura de Arquivos por Shard

```
multi-service-pipeline/
├── service1/
│   ├── main.go (com SHARD_ID e SERVICE1_PORT)
│   ├── service1-shard-baseline.log
│   ├── service1-shard-1.log
│   └── service1-shard-2.log
├── service2/
│   ├── main.go (com SHARD_ID e SERVICE2_PORT)
│   ├── service2-shard-baseline.log
│   ├── service2-shard-1.log
│   └── service2-shard-2.log
├── service3/
│   ├── main.go (com SHARD_ID e SERVICE3_PORT)
│   ├── service3-shard-baseline.log
│   ├── service3-shard-1.log
│   └── service3-shard-2.log
├── manage-services.sh (com comandos de shard)
└── IMPLEMENTACAO_SHARD.md
```

**CRÍTICO**: Todos os spans, logs e métricas DEVEM conter as informações de shard e porta para permitir filtragem granular e comparação entre diferentes versões executando simultaneamente em portas distintas.