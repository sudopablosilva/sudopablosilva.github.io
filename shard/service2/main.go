package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
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
var inputQueueURL = "https://sqs.us-east-1.amazonaws.com/025775160945/service-queue-step1"
var outputQueueURL = "https://sqs.us-east-1.amazonaws.com/025775160945/service-queue-step2"

// Shard configuration
var (
	shardID     string
	servicePort string
)

// Helper function to safely get message ID
func getMessageID(msg types.Message) string {
	if msg.MessageId != nil {
		return *msg.MessageId
	}
	return "unknown"
}

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

func init() {
	shardID = os.Getenv("SHARD_ID")
	if shardID == "" {
		shardID = "shard-default"
	}

	servicePort = os.Getenv("SERVICE2_PORT")
	if servicePort == "" {
		servicePort = "8081"
	}
}

func main() {
	tracer.Start(
		tracer.WithService("service2"),
		tracer.WithEnv("pipeline"),
		tracer.WithServiceVersion("1.2.0"),
		tracer.WithGlobalTag("shard", shardID),
		tracer.WithGlobalTag("port", servicePort),
	)
	defer tracer.Stop()

	log.SetFormatter(&log.JSONFormatter{})
	logFileName := fmt.Sprintf("service2-%s.log", shardID)
	logFile, err := os.OpenFile(logFileName, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
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

	go consumeFromStep1()

	mux := httptrace.NewServeMux()
	mux.HandleFunc("/", homeHandler)

	fmt.Printf("Service2 running on :%s (shard: %s)\n", servicePort, shardID)
	log.WithFields(log.Fields{
		"service": "service2",
		"shard":   shardID,
		"port":    servicePort,
	}).Info("Service2 started")
	http.ListenAndServe(":"+servicePort, mux)
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	span, _ := tracer.StartSpanFromContext(r.Context(), "http.request")
	defer span.Finish()

	correlationID := r.Header.Get("X-Correlation-ID")
	if correlationID == "" {
		correlationID = uuid.New().String()
	}

	span.SetTag("shard", shardID)
	span.SetTag("service", "service2")
	span.SetTag("service.name", "service2")
	span.SetTag("service.port", servicePort)
	span.SetTag("env", "pipeline")
	span.SetTag("correlation.id", correlationID)

	// SLI Metrics for health endpoint
	statsdClient.Incr("sli.requests.total", []string{
		"service:service2",
		"shard:" + shardID,
		"port:" + servicePort,
		"endpoint:/",
	}, 1)
	statsdClient.Incr("sli.requests.success", []string{
		"service:service2",
		"shard:" + shardID,
		"port:" + servicePort,
		"endpoint:/",
	}, 1)

	response := map[string]interface{}{
		"message":        "Service2 - Pipeline Step2 Processor",
		"correlation_id": correlationID,
		"service":        "service2",
	}
	json.NewEncoder(w).Encode(response)
}

func consumeFromStep1() {
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		result, err := sqsClient.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:              &inputQueueURL,
			MaxNumberOfMessages:   1,
			WaitTimeSeconds:       20,
			MessageAttributeNames: []string{"All"},
		})
		cancel() // Always cancel context to free resources

		if err != nil {
			// Log SQS receive errors with context
			log.WithFields(log.Fields{
				"service":   "service2",
				"operation": "sqs_receive",
				"shard":     shardID,
				"queue.url": inputQueueURL,
			}).WithError(err).Error("Failed to receive messages from SQS, retrying...")

			statsdClient.Incr("business.pipeline.errors.sqs.receive", []string{"service:service2"}, 1)
			// Brief pause before retry to avoid tight loop
			time.Sleep(5 * time.Second)
			continue
		}

		for _, msg := range result.Messages {
			processStep2Message(msg)
		}
	}
}

func processStep2Message(msg types.Message) {
	step2Start := time.Now()
	var message PipelineMessage

	// Parse message body with error handling
	if err := json.Unmarshal([]byte(*msg.Body), &message); err != nil {
		log.WithFields(log.Fields{
			"service":    "service2",
			"operation":  "json_unmarshal",
			"shard":      shardID,
			"message.id": getMessageID(msg),
			"queue.url":  inputQueueURL,
		}).WithError(err).Error("Failed to unmarshal pipeline message, skipping")

		statsdClient.Incr("business.pipeline.errors.json.unmarshal", []string{"service:service2"}, 1)

		// Delete malformed message to prevent infinite reprocessing
		if _, delErr := sqsClient.DeleteMessage(context.TODO(), &sqs.DeleteMessageInput{
			QueueUrl:      &inputQueueURL,
			ReceiptHandle: msg.ReceiptHandle,
		}); delErr != nil {
			log.WithError(delErr).Error("Failed to delete malformed message")
		}
		return
	}

	correlationID := message.CorrelationID
	if correlationID == "" {
		correlationID = uuid.New().String()
	}

	// Extract trace context from SQS message attributes
	carrier := make(map[string]string)
	for key, attr := range msg.MessageAttributes {
		if attr.StringValue != nil {
			carrier[key] = *attr.StringValue
		}
	}

	// Extract span context and create child span
	spanCtx, err := tracer.Extract(tracer.TextMapCarrier(carrier))
	var span *tracer.Span
	if err != nil {
		// Trace extraction failed, start new span
		span, _ = tracer.StartSpanFromContext(context.Background(), "sqs.receive")
		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"service":        "service2",
			"shard":          shardID,
			"operation":      "trace_extract",
		}).WithError(err).Debug("Failed to extract trace context, starting new span")
	} else {
		span = tracer.StartSpan("sqs.receive", tracer.ChildOf(spanCtx))
	}
	defer span.Finish()

	// Datadog span tags
	span.SetTag("span.kind", "consumer")
	span.SetTag("messaging.system", "sqs")
	span.SetTag("messaging.destination", "service-queue-step1")
	span.SetTag("messaging.operation", "receive")
	span.SetTag("shard", shardID)
	span.SetTag("service", "service2")
	span.SetTag("service.name", "service2")
	span.SetTag("service.port", servicePort)
	span.SetTag("env", "pipeline")
	span.SetTag("correlation.id", correlationID)
	span.SetTag("pipeline.step", 2)
	span.SetTag("aws.service", "sqs")
	span.SetTag("aws.operation", "ReceiveMessage")

	// Calculate step1 to step2 duration
	if step1Time, err := time.Parse(time.RFC3339Nano, message.Pipeline.Step1Complete); err == nil {
		step1ToStep2Duration := step2Start.Sub(step1Time)
		statsdClient.Timing("business.pipeline.step1_to_step2.duration", step1ToStep2Duration, []string{"service:service2"}, 1)
	}

	// Check for errors from step1 or inject new errors
	processingFailed := message.ErrorType == "invalid_data"
	if processingFailed {
		statsdClient.Incr("business.pipeline.errors.step2", []string{"service:service2", "type:inherited"}, 1)
		span.SetTag("error.inherited", true)
		span.SetTag("error", true)
		span.SetTag("error.msg", fmt.Sprintf("inherited error from step1: %s", message.ErrorType))
		span.SetTag("error.type", "BusinessLogicError")

		// Log detailed error information
		log.WithFields(log.Fields{
			"dd.trace_id":    span.Context().TraceID(),
			"correlation.id": correlationID,
			"service":        "service2",
			"shard":          shardID,
			"pipeline.step":  2,
			"error.type":     message.ErrorType,
			"error.source":   "step1",
			"message.data":   message.Data,
			"action":         "skipping_step2_processing",
		}).Error("Step2 processing failed - inherited error from step1, message will not be forwarded to step3")

		// Delete message from queue to prevent reprocessing
		if _, err := sqsClient.DeleteMessage(context.TODO(), &sqs.DeleteMessageInput{
			QueueUrl:      &inputQueueURL,
			ReceiptHandle: msg.ReceiptHandle,
		}); err != nil {
			log.WithFields(log.Fields{
				"correlation.id": correlationID,
				"error":          err.Error(),
			}).Error("Failed to delete failed message from step1 queue")
		}

		// SLI Error Metrics
		statsdClient.Incr("sli.processing.total", []string{"service:service2", "operation:message_processing"}, 1)
		statsdClient.Incr("sli.processing.error", []string{"service:service2", "operation:message_processing", "error_type:inherited_error"}, 1)

		statsdClient.Incr("business.pipeline.failed.step2", []string{"service:service2"}, 1)
		return
	}

	// Step2 processing simulation
	time.Sleep(30 * time.Millisecond)
	step2Duration := time.Since(step2Start)

	// Update message for step3
	message.Data = "Processed by service2: " + message.Data
	message.Pipeline.Step2Complete = time.Now().Format(time.RFC3339Nano)
	message.Pipeline.CurrentStep = 2

	// SLI Metrics for SLO tracking
	statsdClient.Incr("sli.processing.total", []string{"service:service2", "operation:message_processing"}, 1)
	statsdClient.Incr("sli.processing.success", []string{"service:service2", "operation:message_processing"}, 1)
	if step2Duration <= 50*time.Millisecond {
		statsdClient.Incr("sli.latency.under_50ms", []string{"service:service2"}, 1)
	}
	statsdClient.Timing("sli.processing_time", step2Duration, []string{"service:service2", "operation:message_processing"}, 1)

	// Business Metrics
	statsdClient.Timing("business.pipeline.step2.duration", step2Duration, []string{"service:service2"}, 1)
	statsdClient.Incr("business.pipeline.messages.step2", []string{"service:service2"}, 1)
	statsdClient.Timing("sli.pipeline.duration", step2Duration, []string{
		"service:service2",
		"shard:" + shardID,
		"step:2",
	}, 1)

	// Send to step3 queue with proper trace propagation
	sqsSendSpan := tracer.StartSpan("sqs.send", tracer.ChildOf(span.Context()))
	defer sqsSendSpan.Finish()

	sqsSendSpan.SetTag("span.kind", "producer")
	sqsSendSpan.SetTag("messaging.system", "sqs")
	sqsSendSpan.SetTag("messaging.destination", "service-queue-step2")
	sqsSendSpan.SetTag("shard", shardID)
	sqsSendSpan.SetTag("service.name", "service2")
	sqsSendSpan.SetTag("service.port", servicePort)
	sqsSendSpan.SetTag("correlation.id", correlationID)
	sqsSendSpan.SetTag("aws.service", "sqs")
	sqsSendSpan.SetTag("aws.operation", "SendMessage")

	// Inject trace context for Service3
	carrierOut := make(map[string]string)
	if err := tracer.Inject(sqsSendSpan.Context(), tracer.TextMapCarrier(carrierOut)); err != nil {
		// Tracing injection failure is not critical, log and continue
		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"service":        "service2",
			"shard":          shardID,
			"operation":      "trace_inject",
		}).WithError(err).Debug("Failed to inject trace context, continuing without tracing")
	}

	// Convert carrier to SQS message attributes
	msgAttrs := map[string]types.MessageAttributeValue{
		"correlation-id": {
			DataType:    &[]string{"String"}[0],
			StringValue: &correlationID,
		},
	}
	for key, value := range carrierOut {
		msgAttrs[key] = types.MessageAttributeValue{
			DataType:    &[]string{"String"}[0],
			StringValue: &value,
		}
	}

	// Marshal message body
	msgBody, err := json.Marshal(message)
	if err != nil {
		sqsSendSpan.SetTag("error", true)
		sqsSendSpan.SetTag("error.msg", err.Error())
		sqsSendSpan.SetTag("error.type", fmt.Sprintf("%T", err))
		span.SetTag("error", true)
		span.SetTag("error.msg", err.Error())
		log.WithFields(log.Fields{
			"dd.trace_id":    span.Context().TraceID(),
			"correlation.id": correlationID,
			"service":        "service2",
			"shard":          shardID,
			"pipeline.step":  2,
			"operation":      "json_marshal",
		}).WithError(err).Error("Failed to marshal message for step3")
		return
	}

	// Send message to step3 queue
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:          &outputQueueURL,
		MessageBody:       &[]string{string(msgBody)}[0],
		MessageAttributes: msgAttrs,
	})

	if err != nil {
		sqsSendSpan.SetTag("error", true)
		sqsSendSpan.SetTag("error.msg", err.Error())
		sqsSendSpan.SetTag("error.type", fmt.Sprintf("%T", err))
		span.SetTag("error", true)
		span.SetTag("error.msg", err.Error())
		log.WithFields(log.Fields{
			"dd.trace_id":    span.Context().TraceID(),
			"correlation.id": correlationID,
			"service":        "service2",
			"shard":          shardID,
			"pipeline.step":  2,
			"operation":      "sqs_send",
			"queue.url":      outputQueueURL,
		}).WithError(err).Error("Failed to send message to step3 queue")

		// SLI Error Metrics
		statsdClient.Incr("sli.processing.total", []string{"service:service2", "operation:message_processing"}, 1)
		statsdClient.Incr("sli.processing.error", []string{"service:service2", "operation:message_processing", "error_type:sqs_send_failure"}, 1)

		statsdClient.Incr("business.pipeline.errors.sqs.send", []string{"service:service2"}, 1)
		return
	}

	// Delete from step1 queue
	if _, err := sqsClient.DeleteMessage(context.TODO(), &sqs.DeleteMessageInput{
		QueueUrl:      &inputQueueURL,
		ReceiptHandle: msg.ReceiptHandle,
	}); err != nil {
		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"error":          err.Error(),
		}).Error("Failed to delete processed message from step1 queue")
	}

	log.WithFields(log.Fields{
		"dd.trace_id":    span.Context().TraceID(),
		"correlation.id": correlationID,
		"service":        "service2",
		"shard":          shardID,
		"pipeline.step":  2,
		"step2_duration": step2Duration.Milliseconds(),
	}).Info("Step2 completed, message sent to step3")
}
