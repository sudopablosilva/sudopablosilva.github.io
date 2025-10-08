# Monitoração por Shard - Implementação Datadog

## Visão Geral

Este documento explica a implementação de monitoração por shard no pipeline multi-service, permitindo execução simultânea de diferentes versões dos serviços com observabilidade granular no Datadog.

## Comparação: Antes vs Depois

### ❌ Versão Original (Backup)
```go
// Sem configuração de shard
func main() {
    tracer.Start(
        tracer.WithService("service1"),
        tracer.WithEnv("pipeline"),
        tracer.WithServiceVersion("1.2.0"),
    )
    
    // Log fixo
    logFile, err := os.OpenFile("service1.log", ...)
    
    // Porta fixa
    fmt.Println("Service1 running on :8080")
    http.ListenAndServe(":8080", mux)
}

// Spans sem shard
span.SetTag("service.name", "service1")
span.SetTag("correlation.id", correlationID)

// Métricas sem shard
statsdClient.Incr("sli.requests.total", []string{"service:service1"}, 1)

// Logs sem shard
log.WithFields(log.Fields{
    "service": "service1",
    "pipeline.step": 1,
}).Info("Step1 completed")
```

### ✅ Versão com Shard
```go
// Configuração dinâmica de shard
var (
    shardID     string
    servicePort string
)

func init() {
    shardID = os.Getenv("SHARD_ID")
    if shardID == "" {
        shardID = "shard-default"
    }
    
    servicePort = os.Getenv("SERVICE1_PORT")
    if servicePort == "" {
        servicePort = "8080"
    }
}

func main() {
    tracer.Start(
        tracer.WithService("service1"),
        tracer.WithEnv("pipeline"),
        tracer.WithServiceVersion("1.2.0"),
        tracer.WithGlobalTag("shard", shardID),      // ✅ Global shard tag
        tracer.WithGlobalTag("port", servicePort),   // ✅ Global port tag
    )
    
    // Log específico por shard
    logFileName := fmt.Sprintf("service1-%s.log", shardID)
    logFile, err := os.OpenFile(logFileName, ...)
    
    // Porta dinâmica
    fmt.Printf("Service1 running on :%s (shard: %s)\n", servicePort, shardID)
    http.ListenAndServe(":"+servicePort, mux)
}

// Spans com shard completo
span.SetTag("shard", shardID)
span.SetTag("service", "service1")
span.SetTag("service.name", "service1")
span.SetTag("service.port", servicePort)
span.SetTag("env", "pipeline")
span.SetTag("correlation.id", correlationID)

// Métricas com shard
statsdClient.Incr("sli.requests.total", []string{
    "service:service1",
    "shard:" + shardID,
    "port:" + servicePort,
    "endpoint:/",
}, 1)

// Logs com shard
log.WithFields(log.Fields{
    "service": "service1",
    "shard": shardID,
    "port": servicePort,
    "pipeline.step": 1,
}).Info("Step1 completed")
```

## Principais Mudanças Implementadas

### 1. **Configuração Dinâmica de Ambiente**
```go
// Variáveis globais para shard
var (
    shardID     string  // Ex: "shard-baseline", "shard-1", "shard-2"
    servicePort string  // Ex: "8080", "8090", "8100"
)

// Inicialização via variáveis de ambiente
func init() {
    shardID = os.Getenv("SHARD_ID")
    servicePort = os.Getenv("SERVICE1_PORT")
}
```

### 2. **Tags Globais do Tracer**
```go
tracer.Start(
    tracer.WithService("service1"),
    tracer.WithEnv("pipeline"),
    tracer.WithServiceVersion("1.2.0"),
    tracer.WithGlobalTag("shard", shardID),    // ✅ Aplicado a todos os spans
    tracer.WithGlobalTag("port", servicePort), // ✅ Aplicado a todos os spans
)
```

### 3. **Logs Específicos por Shard**
```go
// Arquivo de log único por shard
logFileName := fmt.Sprintf("service1-%s.log", shardID)
// Resulta em: service1-shard-baseline.log, service1-shard-1.log, etc.

// Todos os logs incluem shard
log.WithFields(log.Fields{
    "service": "service1",
    "shard": shardID,           // ✅ Campo shard
    "port": servicePort,        // ✅ Campo port
    "pipeline.step": 1,
}).Info("Step1 completed")
```

### 4. **Spans com Tags Completas**
```go
// Todos os spans incluem informações de shard
span.SetTag("shard", shardID)
span.SetTag("service", "service1")
span.SetTag("service.name", "service1")
span.SetTag("service.port", servicePort)
span.SetTag("env", "pipeline")
```

### 5. **Métricas com Tags de Shard**
```go
// SLI Metrics com shard
statsdClient.Incr("sli.requests.total", []string{
    "service:service1",
    "shard:" + shardID,         // ✅ Tag shard
    "port:" + servicePort,      // ✅ Tag port
    "endpoint:/send-message",
}, 1)

// Business Metrics com shard
statsdClient.Timing("business.pipeline.step1.duration", step1Duration, []string{
    "service:service1",
    "shard:" + shardID,         // ✅ Tag shard
}, 1)

// Pipeline SLI Metrics com shard
statsdClient.Timing("sli.pipeline.duration", step1Duration, []string{
    "service:service1",
    "shard:" + shardID,         // ✅ Tag shard
    "step:1",
}, 1)
```

## Arquitetura de Portas por Shard

### Mapeamento de Portas
```bash
# shard-baseline (versão de referência)
Service1: 8080
Service2: 8081  
Service3: 8082

# shard-1 (versão otimizada)
Service1: 8090
Service2: 8091
Service3: 8092

# shard-2 (versão experimental)
Service1: 8100
Service2: 8101
Service3: 8102
```

### Script de Gerenciamento
```bash
# Iniciar shard específico
./manage-services-shard.sh start-shard shard-baseline
./manage-services-shard.sh start-shard shard-1
./manage-services-shard.sh start-shard shard-2

# Parar shard específico
./manage-services-shard.sh stop-shard shard-1

# Comparar performance entre shards
./manage-services-shard.sh compare-shards shard-baseline shard-1

# Listar shards ativos
./manage-services-shard.sh list-shards
```

## Observabilidade no Datadog

### 1. **Filtragem por Shard**
```sql
-- Métricas por shard específico
avg:sli.pipeline.duration{shard:shard-1}
avg:sli.pipeline.duration{shard:shard-baseline}

-- Comparação entre shards
avg:sli.pipeline.duration{shard:shard-baseline} vs avg:sli.pipeline.duration{shard:shard-1}

-- Taxa de sucesso por shard
(sum:sli.pipeline.success{shard:shard-1}.as_count())/(sum:sli.pipeline.total{shard:shard-1}.as_count())*100
```

### 2. **Logs com Contexto de Shard**
```json
{
  "level": "info",
  "msg": "Step1 completed, message sent to Service2",
  "service": "service1",
  "shard": "shard-baseline",
  "port": "8080",
  "pipeline.step": 1,
  "correlation.id": "test-123",
  "dd.trace_id": 1234567890,
  "step1_duration": 21
}
```

### 3. **Traces com Tags de Shard**
```yaml
# Todos os spans incluem:
tags:
  - shard: shard-baseline
  - service: service1
  - service.name: service1
  - service.port: 8080
  - env: pipeline
  - correlation.id: test-123
```

### 4. **Dashboards com Comparação de Shards**
```yaml
# Widget: Pipeline Duration por Shard
query: avg:sli.pipeline.duration{*} by {shard}
visualization: timeseries
legend: 
  - shard-baseline (referência)
  - shard-1 (otimizada)
  - shard-2 (experimental)

# Widget: Taxa de Erro por Shard  
query: (sum:sli.pipeline.total{*} - sum:sli.pipeline.success{*})/sum:sli.pipeline.total{*}*100 by {shard}
visualization: query_value
```

## Casos de Uso

### 1. **Deployment Gradual (Blue-Green)**
```bash
# 1. Manter versão atual (baseline)
./manage-services-shard.sh start-shard shard-baseline

# 2. Deploy nova versão (shard-1)
./manage-services-shard.sh start-shard shard-1

# 3. Comparar métricas no Datadog
# 4. Migrar tráfego gradualmente
# 5. Desativar versão antiga
./manage-services-shard.sh stop-shard shard-baseline
```

### 2. **Teste A/B de Performance**
```bash
# Executar múltiplas versões simultaneamente
./manage-services-shard.sh start-shard shard-baseline
./manage-services-shard.sh start-shard shard-1
./manage-services-shard.sh start-shard shard-2

# Gerar tráfego para todos os shards
bash multi-shard-test.sh  # 10 minutos de teste

# Analisar resultados no Datadog por shard
```

### 3. **Debugging de Versão Específica**
```bash
# Filtrar logs por shard problemático
@shard:shard-2 @service:service1 ERROR

# Filtrar traces por shard
shard:shard-2 service:service1

# Métricas específicas do shard
avg:sli.pipeline.duration{shard:shard-2,service:service1}
```

## Alertas por Shard

### 1. **Performance Delta Entre Shards**
```yaml
query: |
  abs(avg:sli.pipeline.duration{shard:shard-baseline} - avg:sli.pipeline.duration{shard:shard-1}) > 100
message: |
  ⚠️ Performance delta > 100ms entre shards
  Baseline: {{shard-baseline.last_value}}ms (8080-8082)
  Shard-1: {{shard-1.last_value}}ms (8090-8092)
```

### 2. **Taxa de Erro por Shard**
```yaml
query: |
  (sum:sli.pipeline.total{shard:shard-1} - sum:sli.pipeline.success{shard:shard-1})/sum:sli.pipeline.total{shard:shard-1}*100 > 1
message: |
  🚨 Taxa de erro > 1% no {{shard.name}}
  Portas: {{port.name}}
  Atual: {{value}}%
```

## Benefícios da Implementação

### ✅ **Observabilidade Granular**
- Filtragem precisa por shard no Datadog
- Comparação side-by-side de diferentes versões
- Isolamento de métricas por versão

### ✅ **Deployment Seguro**
- Rollback rápido por shard
- Validação de performance antes da migração
- Teste A/B com dados reais

### ✅ **Debugging Eficiente**
- Logs separados por shard
- Traces isolados por versão
- Métricas específicas por implementação

### ✅ **Escalabilidade**
- Múltiplas versões simultâneas
- Portas dinâmicas por shard
- Configuração via variáveis de ambiente

## Checklist de Validação

- [ ] **SHARD_ID** configurado via `os.Getenv()`
- [ ] **SERVICE*_PORT** configurado via `os.Getenv()`
- [ ] **tracer.WithGlobalTag()** para shard e port
- [ ] **Todos os spans** contêm tags `shard` e `service.port`
- [ ] **Todos os logs** contêm campos `shard` e `port`
- [ ] **Todas as métricas** contêm tags `shard:$SHARD_ID`
- [ ] **Logs separados** por shard (`service1-shard-1.log`)
- [ ] **Script de gerenciamento** suporta comandos de shard
- [ ] **Testes funcionais** por shard individual

Esta implementação permite monitoração completa e comparação entre diferentes versões dos serviços executando simultaneamente, fornecendo observabilidade granular essencial para deployments seguros e debugging eficiente.