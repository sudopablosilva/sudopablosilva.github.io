package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"time"

	"github.com/DataDog/datadog-go/statsd"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/google/uuid"
	log "github.com/sirupsen/logrus"
	httptrace "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
)

var sqsClient *sqs.Client
var statsdClient *statsd.Client
var queueURL = "https://sqs.us-east-1.amazonaws.com/025775160945/service-queue-step2"

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
		tracer.WithService("service3"),
		tracer.WithEnv("pipeline"),
		tracer.WithServiceVersion("1.2.0"),
	)
	defer tracer.Stop()

	log.SetFormatter(&log.JSONFormatter{})
	if logFile, err := os.OpenFile("service3.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666); err == nil {
		defer logFile.Close()
		log.SetOutput(logFile)
	} else {
		log.WithError(err).Warn("Failed to open log file, using stdout")
	}

	var err error
	statsdClient, err = statsd.New("127.0.0.1:8125")
	if err != nil {
		log.Fatal(err)
	}
	defer statsdClient.Close()

	cfg, err := config.LoadDefaultConfig(context.TODO(),
		config.WithRegion("us-east-1"),
		config.WithSharedConfigProfile("controlplane-pcsilva"))
	if err != nil {
		panic(err)
	}
	sqsClient = sqs.NewFromConfig(cfg)

	go consumeFromStep2()

	mux := httptrace.NewServeMux()
	mux.HandleFunc("/", homeHandler)

	log.Info("Service3 running on :8082")
	http.ListenAndServe(":8082", mux)
}

func homeHandler(w http.ResponseWriter, r *http.Request) {
	span, _ := tracer.StartSpanFromContext(r.Context(), "http.request")
	defer span.Finish()

	correlationID := r.Header.Get("X-Correlation-ID")
	if correlationID == "" {
		correlationID = uuid.New().String()
	}

	span.SetTag("service.name", "service3")
	span.SetTag("correlation.id", correlationID)

	// SLI Metrics for health endpoint
	statsdClient.Incr("sli.requests.total", []string{"service:service3", "endpoint:/"}, 1)
	statsdClient.Incr("sli.requests.success", []string{"service:service3", "endpoint:/"}, 1)

	response := map[string]interface{}{
		"message":        "Service3 - Pipeline Final Step",
		"correlation_id": correlationID,
		"service":        "service3",
	}
	json.NewEncoder(w).Encode(response)
}

func consumeFromStep2() {
	for {
		result, err := sqsClient.ReceiveMessage(context.TODO(), &sqs.ReceiveMessageInput{
			QueueUrl:              &queueURL,
			MaxNumberOfMessages:   1,
			WaitTimeSeconds:       20,
			MessageAttributeNames: []string{"All"},
		})

		if err != nil {
			continue
		}

		for _, msg := range result.Messages {
			processStep3Message(msg)
		}
	}
}

func processStep3Message(msg types.Message) {
	step3Start := time.Now()
	var message PipelineMessage
	if err := json.Unmarshal([]byte(*msg.Body), &message); err != nil {
		log.WithFields(log.Fields{
			"service":     "service3",
			"operation":   "json_unmarshal",
			"queue.url":   queueURL,
		}).WithError(err).Error("Failed to unmarshal pipeline message, skipping")
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
		span, _ = tracer.StartSpanFromContext(context.Background(), "sqs.receive")
		log.WithFields(log.Fields{
			"correlation.id": correlationID,
			"service":        "service3",
			"operation":      "trace_extract",
		}).WithError(err).Debug("Failed to extract trace context, starting new span")
	} else {
		span = tracer.StartSpan("sqs.receive", tracer.ChildOf(spanCtx))
	}
	defer span.Finish()

	// Datadog span tags
	span.SetTag("span.kind", "consumer")
	span.SetTag("messaging.system", "sqs")
	span.SetTag("messaging.destination", "service-queue-step2")
	span.SetTag("messaging.operation", "receive")
	span.SetTag("service.name", "service3")
	span.SetTag("correlation.id", correlationID)
	span.SetTag("pipeline.step", 3)
	span.SetTag("aws.service", "sqs")
	span.SetTag("aws.operation", "ReceiveMessage")

	// Calculate step2 to step3 duration
	if step2Time, err := time.Parse(time.RFC3339Nano, message.Pipeline.Step2Complete); err == nil {
		step2ToStep3Duration := step3Start.Sub(step2Time)
		statsdClient.Timing("business.pipeline.step2_to_step3.duration", step2ToStep3Duration, []string{"service:service3"}, 1)
	}

	// Step3 processing simulation
	time.Sleep(40 * time.Millisecond)
	step3Duration := time.Since(step3Start)

	// Calculate end-to-end pipeline duration
	if startTime, err := time.Parse(time.RFC3339Nano, message.Pipeline.StartTime); err == nil {
		endToEndDuration := time.Since(startTime)
		statsdClient.Timing("business.pipeline.end_to_end.duration", endToEndDuration, []string{"service:service3"}, 1)

		// Calculate individual step durations from timestamps
		if step1Time, err := time.Parse(time.RFC3339Nano, message.Pipeline.Step1Complete); err == nil {
			step1Duration := step1Time.Sub(startTime)
			statsdClient.Timing("business.pipeline.step1.calculated_duration", step1Duration, []string{"service:service3"}, 1)

			if step2Time, err := time.Parse(time.RFC3339Nano, message.Pipeline.Step2Complete); err == nil {
				step2Duration := step2Time.Sub(step1Time)
				statsdClient.Timing("business.pipeline.step2.calculated_duration", step2Duration, []string{"service:service3"}, 1)
			}
		}
	}

	// SLI Metrics for SLO tracking
	statsdClient.Incr("sli.processing.total", []string{"service:service3", "operation:final_processing"}, 1)
	statsdClient.Incr("sli.processing.success", []string{"service:service3", "operation:final_processing"}, 1)
	if step3Duration <= 60*time.Millisecond {
		statsdClient.Incr("sli.latency.under_60ms", []string{"service:service3"}, 1)
	}
	statsdClient.Timing("sli.processing_time", step3Duration, []string{"service:service3", "operation:final_processing"}, 1)

	// End-to-end SLI metrics
	if startTime, err := time.Parse(time.RFC3339Nano, message.Pipeline.StartTime); err == nil {
		endToEndDuration := time.Since(startTime)
		statsdClient.Incr("sli.pipeline.total", []string{"pipeline:multi_service"}, 1)
		statsdClient.Incr("sli.pipeline.success", []string{"pipeline:multi_service"}, 1)
		if endToEndDuration <= 300*time.Millisecond {
			statsdClient.Incr("sli.pipeline.under_300ms", []string{"pipeline:multi_service"}, 1)
		}
		if endToEndDuration <= 1*time.Second {
			statsdClient.Incr("sli.pipeline.under_1s", []string{"pipeline:multi_service"}, 1)
		}
		statsdClient.Timing("sli.pipeline.duration", endToEndDuration, []string{"pipeline:multi_service"}, 1)
	}

	// Business Metrics
	statsdClient.Timing("business.pipeline.step3.duration", step3Duration, []string{"service:service3"}, 1)
	statsdClient.Incr("business.pipeline.messages.step3", []string{"service:service3"}, 1)
	statsdClient.Incr("business.pipeline.completed", []string{"service:service3"}, 1)

	// Delete message from queue
	sqsClient.DeleteMessage(context.TODO(), &sqs.DeleteMessageInput{
		QueueUrl:      &queueURL,
		ReceiptHandle: msg.ReceiptHandle,
	})

	log.WithFields(log.Fields{
		"dd.trace_id":       span.Context().TraceID(),
		"correlation.id":    correlationID,
		"service":           "service3",
		"pipeline.step":     3,
		"step3_duration":    step3Duration.Milliseconds(),
		"pipeline_complete": true,
		"message.data":      message.Data,
		"error.type":        message.ErrorType,
		"pipeline.start":    message.Pipeline.StartTime,
		"pipeline.step1":    message.Pipeline.Step1Complete,
		"pipeline.step2":    message.Pipeline.Step2Complete,
	}).Info("Pipeline completed - Step3 finished")
}
