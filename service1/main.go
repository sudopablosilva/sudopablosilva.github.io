package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"time"

	"github.com/DataDog/datadog-go/statsd"
	httptrace "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/google/uuid"
	log "github.com/sirupsen/logrus"
)

var sqsClient *sqs.Client
var statsdClient *statsd.Client
var queueURL = "https://sqs.us-east-1.amazonaws.com/025775160945/service-queue-step1"

type PipelineMessage struct {
	CorrelationID string `json:"correlation_id"`
	Data          string `json:"data"`
	Pipeline      struct {
		StartTime     string `json:"start_time"`
		Step1Complete string `json:"step1_complete,omitempty"`
		Step2Complete string `json:"step2_complete,omitempty"`
		CurrentStep   int    `json:"current_step"`
	} `json:"pipeline"`
	ErrorType string `json:"error_type,omitempty"`
}

func main() {
	tracer.Start(
		tracer.WithService("service1"),
		tracer.WithEnv("pipeline"),
		tracer.WithServiceVersion("1.2.0"),
	)
	defer tracer.Stop()

	log.SetFormatter(&log.JSONFormatter{})
	logFile, err := os.OpenFile("service1.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.WithError(err).Warn("Failed to open log file, using stdout")
	} else {
		// Use defer for proper resource cleanup
		defer func() {
			if closeErr := logFile.Close(); closeErr != nil {
				log.WithError(closeErr).Error("Failed to close log file")
			}
		}()
		log.SetOutput(logFile)
	}

	statsdClient, err = statsd.New("127.0.0.1:8125")
	if err != nil {
		log.WithError(err).Fatal("Failed to initialize StatsD client")
	}
	// Use defer for proper resource cleanup
	defer func() {
		if closeErr := statsdClient.Close(); closeErr != nil {
			log.WithError(closeErr).Error("Failed to close StatsD client")
		}
	}()

	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion("us-east-1"),
		config.WithSharedConfigProfile("controlplane-pcsilva"))
	if err != nil {
		log.WithError(err).Fatal("Failed to load AWS configuration")
	}
	sqsClient = sqs.NewFromConfig(cfg)

	mux := httptrace.NewServeMux()
	mux.HandleFunc("/", homeHandler)
	mux.HandleFunc("/send-message", sendMessageHandler)

	fmt.Println("Service1 running on :8080")
	log.Info("Service1 started")
	http.ListenAndServe(":8080", mux)
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	span, _ := tracer.StartSpanFromContext(r.Context(), "http.request")
	defer span.Finish()

	correlationID := r.Header.Get("X-Correlation-ID")
	if correlationID == "" {
		correlationID = uuid.New().String()
	}

	span.SetTag("service.name", "service1")
	span.SetTag("correlation.id", correlationID)

	// SLI Metrics for health endpoint
	statsdClient.Incr("sli.requests.total", []string{"service:service1", "endpoint:/"}, 1)
	statsdClient.Incr("sli.requests.success", []string{"service:service1", "endpoint:/"}, 1)

	response := map[string]interface{}{
		"message":        "Service1 - Pipeline Entry Point",
		"correlation_id": correlationID,
		"service":        "service1",
	}
	json.NewEncoder(w).Encode(response)
}

func sendMessageHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	start := time.Now()
	// Main pipeline entry span
	pipelineSpan, ctx := tracer.StartSpanFromContext(r.Context(), "pipeline.step1.process")
	defer pipelineSpan.Finish()

	correlationID := r.Header.Get("X-Correlation-ID")
	if correlationID == "" {
		correlationID = uuid.New().String()
	}
	injectError := r.Header.Get("X-Inject-Error") == "true"

	pipelineSpan.SetTag("service.name", "service1")
	pipelineSpan.SetTag("correlation.id", correlationID)
	pipelineSpan.SetTag("pipeline.step", 1)
	pipelineSpan.SetTag("pipeline.step.name", "order_processing")

	// Business logic processing span
	processingSpan := pipelineSpan.StartChild("pipeline.step1.business_logic")
	processingSpan.SetTag("correlation.id", correlationID)
	processingSpan.SetTag("operation", "validate_and_prepare_order")

	// Create pipeline message with start timestamp
	message := PipelineMessage{
		CorrelationID: correlationID,
		Data:          "Initial data from service1",
	}
	message.Pipeline.StartTime = time.Now().Format(time.RFC3339Nano)
	message.Pipeline.CurrentStep = 1

	if injectError {
		message.ErrorType = "invalid_data"
		statsdClient.Incr("business.pipeline.errors.step1", []string{"service:service1"}, 1)
		processingSpan.SetTag("error.injected", true)
		processingSpan.SetTag("error", true)
		pipelineSpan.SetTag("error.injected", true)
		pipelineSpan.SetTag("error", true)

		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"service":        "service1",
			"pipeline.step":  1,
			"error.type":     "invalid_data",
			"error.injected": true,
		}).Warn("Error injection activated - message marked as invalid_data")
	}

	// Step1 processing simulation
	time.Sleep(20 * time.Millisecond)
	step1Duration := time.Since(start)
	message.Pipeline.Step1Complete = time.Now().Format(time.RFC3339Nano)
	processingSpan.Finish()

	// SLI Metrics for SLO tracking
	statsdClient.Incr("sli.requests.total", []string{"service:service1", "endpoint:/send-message"}, 1)
	if !injectError {
		statsdClient.Incr("sli.requests.success", []string{"service:service1", "endpoint:/send-message"}, 1)
	} else {
		statsdClient.Incr("sli.requests.error", []string{"service:service1", "endpoint:/send-message", "error_type:invalid_data"}, 1)
	}
	if step1Duration <= 50*time.Millisecond {
		statsdClient.Incr("sli.latency.under_50ms", []string{"service:service1"}, 1)
	}
	statsdClient.Timing("sli.response_time", step1Duration, []string{"service:service1", "endpoint:/send-message"}, 1)

	// Business Metrics
	statsdClient.Timing("business.pipeline.step1.duration", step1Duration, []string{"service:service1"}, 1)
	statsdClient.Incr("business.pipeline.messages.step1", []string{"service:service1"}, 1)

	// Send to Service2 via SQS
	if err := sendToService2(ctx, pipelineSpan, message, correlationID); err != nil {
		pipelineSpan.SetTag("error", true)
		pipelineSpan.SetTag("error.msg", err.Error())
		pipelineSpan.SetTag("error.type", fmt.Sprintf("%T", err))
		// Add stack trace for better debugging
		buf := make([]byte, 2048)
		n := runtime.Stack(buf, false)
		pipelineSpan.SetTag("error.stack", string(buf[:n]))
		processingSpan.SetTag("error", true)
		processingSpan.SetTag("error.msg", err.Error())
		processingSpan.SetTag("error.stack", string(buf[:n]))

		// Log detailed error with context
		log.WithFields(log.Fields{
			"dd.trace_id":    pipelineSpan.Context().TraceIDLower(),
			"correlation.id": correlationID,
			"service":        "service1",
			"pipeline.step":  1,
			"operation":      "send_to_service2",
			"queue.url":      queueURL,
		}).WithError(err).Error("Failed to send message to Service2")

		// SLI Error Metrics
		statsdClient.Incr("sli.requests.total", []string{"service:service1", "endpoint:/send-message"}, 1)
		statsdClient.Incr("sli.requests.error", []string{"service:service1", "endpoint:/send-message", "error_type:sqs_send_failure"}, 1)

		// Classify error type for metrics
		if fmt.Sprintf("%T", err) == "*fmt.wrapError" {
			statsdClient.Incr("business.pipeline.errors.sqs.send", []string{"service:service1"}, 1)
		} else {
			statsdClient.Incr("business.pipeline.errors.unknown", []string{"service:service1"}, 1)
		}

		http.Error(w, "Internal server error: failed to process pipeline message", http.StatusInternalServerError)
		return
	}

	log.WithFields(log.Fields{
		"dd.trace_id":    pipelineSpan.Context().TraceIDLower(),
		"correlation.id": correlationID,
		"service":        "service1",
		"pipeline.step":  1,
		"step1_duration": step1Duration.Milliseconds(),
		"error.injected": injectError,
	}).Info("Step1 completed, message sent to Service2")

	response := map[string]interface{}{
		"message":        "Pipeline started - Step1 completed",
		"correlation_id": correlationID,
		"step":           1,
		"duration_ms":    step1Duration.Milliseconds(),
	}
	json.NewEncoder(w).Encode(response)
}

func sendToService2(ctx context.Context, parentSpan *tracer.Span, message PipelineMessage, correlationID string) error {
	// Span for sending message to Service2
	sendSpan := parentSpan.StartChild("pipeline.step1.send_to_service2")
	defer sendSpan.Finish()

	sendSpan.SetTag("correlation.id", correlationID)
	sendSpan.SetTag("target.service", "service2")
	sendSpan.SetTag("messaging.operation", "send_to_next_step")

	// SQS queue interaction span
	sqsSpan := sendSpan.StartChild("sqs.send_message.service_queue_step1")
	defer sqsSpan.Finish()

	sqsSpan.SetTag("span.kind", "producer")
	sqsSpan.SetTag("messaging.system", "sqs")
	sqsSpan.SetTag("messaging.destination", "service-queue-step1")
	sqsSpan.SetTag("messaging.destination.kind", "queue")
	sqsSpan.SetTag("correlation.id", correlationID)
	sqsSpan.SetTag("aws.service", "sqs")
	sqsSpan.SetTag("aws.operation", "SendMessage")
	sqsSpan.SetTag("aws.queue.name", "service-queue-step1")

	// Inject trace context using Datadog TextMap carrier
	carrier := make(map[string]string)
	if err := tracer.Inject(sqsSpan.Context(), tracer.TextMapCarrier(carrier)); err != nil {
		// Tracing injection failure is not critical, log and continue
		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"service":        "service1",
			"operation":      "trace_inject",
		}).WithError(err).Warn("Failed to inject trace context, continuing without tracing")
	}

	// Convert carrier to SQS message attributes
	msgAttrs := map[string]types.MessageAttributeValue{
		"correlation-id": {
			DataType:    &[]string{"String"}[0],
			StringValue: &correlationID,
		},
	}
	for key, value := range carrier {
		msgAttrs[key] = types.MessageAttributeValue{
			DataType:    &[]string{"String"}[0],
			StringValue: &value,
		}
	}

	// Marshal message body
	msgBody, err := json.Marshal(message)
	if err != nil {
		buf := make([]byte, 2048)
		n := runtime.Stack(buf, false)
		sqsSpan.SetTag("error", true)
		sqsSpan.SetTag("error.msg", err.Error())
		sqsSpan.SetTag("error.type", fmt.Sprintf("%T", err))
		sqsSpan.SetTag("error.stack", string(buf[:n]))
		sendSpan.SetTag("error", true)
		sendSpan.SetTag("error.msg", err.Error())
		sendSpan.SetTag("error.stack", string(buf[:n]))
		return fmt.Errorf("failed to marshal pipeline message for service2: %w", err)
	}

	// Send message to SQS
	_, err = sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:          &queueURL,
		MessageBody:       &[]string{string(msgBody)}[0],
		MessageAttributes: msgAttrs,
	})

	if err != nil {
		sqsSpan.SetTag("error", true)
		sqsSpan.SetTag("error.msg", err.Error())
		sqsSpan.SetTag("error.type", fmt.Sprintf("%T", err))
		sendSpan.SetTag("error", true)
		sendSpan.SetTag("error.msg", err.Error())
		// Wrap error with context
		return fmt.Errorf("failed to send message to service2 queue [correlation_id=%s, queue=%s]: %w",
			correlationID, queueURL, err)
	}

	sqsSpan.SetTag("message.sent", true)
	sendSpan.SetTag("message.sent", true)
	return nil
}
