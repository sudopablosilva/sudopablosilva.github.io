# Datadog Agent Setup for Go Services

Quick reference for managing Datadog Agent on macOS and configuring Go application monitoring.

## Agent Management Commands

### Start/Stop Agent
```bash
# Stop Datadog Agent
sudo launchctl stop com.datadoghq.agent

# Start Datadog Agent  
sudo launchctl start com.datadoghq.agent

# Check Agent Status
sudo datadog-agent status
```

### Agent Status Check
```bash
# Full status
sudo datadog-agent status

# Check specific components
sudo datadog-agent status | grep -A 5 "APM Agent"
sudo datadog-agent status | grep -A 5 "DogStatsD"
sudo datadog-agent status | grep -A 5 "Logs Agent"
```

## Go Application Configuration

### Go Integration Config
Create or edit: `/opt/datadog-agent/etc/conf.d/go.d/conf.yaml`

```yaml
init_config:

instances:
  - # Enable Go runtime metrics collection
    collect_runtime_metrics: true
    
    # Service discovery for Go processes
    service_checks:
      - name: "go.can_connect"
        url: "http://localhost:8080"
        timeout: 5
      - name: "go.can_connect" 
        url: "http://localhost:8081"
        timeout: 5
      - name: "go.can_connect"
        url: "http://localhost:8082"
        timeout: 5

    # Custom tags for all Go services
    tags:
      - "env:pipeline"
      - "project:multi-service-pipeline"
      - "language:go"
```

### Log Collection Setup
Add to `/opt/datadog-agent/etc/datadog.yaml`:

```yaml
logs_enabled: true

logs_config:
  container_collect_all: false
  
# Custom log sources
logs:
  - type: file
    path: "/Users/pcsilva/poc_go_datadog_logs/multi-service-pipeline/service1/service1.log"
    service: "service1"
    source: "go"
    tags:
      - "env:pipeline"
      - "service:service1"
      
  - type: file
    path: "/Users/pcsilva/poc_go_datadog_logs/multi-service-pipeline/service2/service2.log"
    service: "service2"
    source: "go"
    tags:
      - "env:pipeline" 
      - "service:service2"
      
  - type: file
    path: "/Users/pcsilva/poc_go_datadog_logs/multi-service-pipeline/service2-slow/service2-slow.log"
    service: "service2-slow"
    source: "go"
    tags:
      - "env:pipeline"
      - "service:service2-slow"
      - "performance:degraded"
      
  - type: file
    path: "/Users/pcsilva/poc_go_datadog_logs/multi-service-pipeline/service3/service3.log"
    service: "service3"
    source: "go"
    tags:
      - "env:pipeline"
      - "service:service3"
```

## APM Configuration

### Enable APM in datadog.yaml
```yaml
apm_config:
  enabled: true
  apm_non_local_traffic: false
  
# DogStatsD for custom metrics
dogstatsd_config:
  enabled: true
  bind_host: 127.0.0.1
  port: 8125
  non_local_traffic: false
```

## Quick Setup Workflow

1. **Configure Go integration**:
   ```bash
   sudo mkdir -p /opt/datadog-agent/etc/conf.d/go.d/
   sudo vim /opt/datadog-agent/etc/conf.d/go.d/conf.yaml
   ```

2. **Add log collection paths**:
   ```bash
   sudo vim /opt/datadog-agent/etc/datadog.yaml
   ```

3. **Restart agent**:
   ```bash
   sudo launchctl stop com.datadoghq.agent
   sudo launchctl start com.datadoghq.agent
   ```

4. **Verify configuration**:
   ```bash
   sudo datadog-agent status
   sudo datadog-agent configcheck
   ```

## Troubleshooting

### Check Agent Logs
```bash
# Main agent log
tail -f /opt/datadog-agent/logs/agent.log

# APM agent log  
tail -f /opt/datadog-agent/logs/trace-agent.log

# DogStatsD log
tail -f /opt/datadog-agent/logs/dogstatsd.log
```

### Validate Configuration
```bash
# Check configuration syntax
sudo datadog-agent configcheck

# Test connectivity
sudo datadog-agent check go

# Validate log collection
sudo datadog-agent check logs_agent
```

### Common Issues
- **Permission denied**: Ensure agent has read access to log files
- **Port conflicts**: Verify DogStatsD port 8125 is available
- **APM not working**: Check `DD_TRACE_ENABLED=true` environment variable

## Performance Comparison Demo

1. **Start normal pipeline**:
   ```bash
   ./manage-services.sh start
   ./manage-services.sh load-test
   ```

2. **Switch to degraded pipeline**:
   ```bash
   ./manage-services.sh stop
   ./manage-services.sh start-slow
   ./manage-services.sh load-test
   ```

3. **Compare in Datadog**:
   - APM traces: `service2` vs `service2-slow`
   - SLI metrics: Processing time differences
   - Service map: Performance bottleneck visualization