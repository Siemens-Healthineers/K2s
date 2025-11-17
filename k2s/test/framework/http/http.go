// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package http

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/failsafe-go/failsafe-go"
	"github.com/failsafe-go/failsafe-go/failsafehttp"
	"github.com/failsafe-go/failsafe-go/retrypolicy"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
)

type ResilientHttpClient struct {
	executor failsafe.Executor[*http.Response]
}

func NewResilientHttpClient(requestTimeout time.Duration) *ResilientHttpClient {
	retryPolicy := retrypolicy.NewBuilder[*http.Response]().
		WithBackoff(time.Second, time.Minute).
		WithJitterFactor(.25).
		WithMaxRetries(5).
		WithMaxDuration(requestTimeout).
		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
			GinkgoWriter.Println("Last attempt failed with error: ", e.LastError())
			GinkgoWriter.Printf("This is retry no. %d, elapsed time so far: %v,  retrying\n", e.Retries(), e.ElapsedTime())
		}).
		HandleIf(func(response *http.Response, err error) bool {
			if err != nil {
				return true
			}
			if response != nil && response.StatusCode >= 400 {
				GinkgoWriter.Println("Failed due to status code: ", response.StatusCode)
				return true
			}
			return false
		}).
		Build()

	// failsafe v0.9.0 removed NewExecutor in favor of the With(...) factory for composing policies.
	// Migration: replace failsafe.NewExecutor(retryPolicy) with failsafe.With(retryPolicy).
	return &ResilientHttpClient{executor: failsafe.With(retryPolicy)}
}

// func NewResilientHttpClient(requestTimeout time.Duration) *http.Client {
//     // 1. Build a standard retry policy with a generic type of *http.Response.
// 	// This makes the policy independent of the specific execution context.
// 	retryPolicy := retrypolicy.Builder[*http.Response]().
// 		WithBackoff(time.Second, time.Minute).
// 		WithJitterFactor(.25).
// 		WithMaxRetries(5).
// 		WithMaxDuration(requestTimeout).
// 		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
// 			ginkgo.GinkgoWriter.Println("Last attempt failed with error: ", e.LastError())
// 			ginkgo.GinkgoWriter.Printf("This is retry no. %d, elapsed time so far: %v, retrying\n", e.Retries(), e.ElapsedTime())
// 		}).
// 		// 2. Use the failsafehttp.IsFailure helper, which handles both network errors and status codes >= 400.
// 		HandleIf(failsafehttp.IsFailure).
// 		Build()

//     // 3. Create a new Failsafe HTTP Client using the WithRetryPolicy option.
//     // This is the new, recommended way to create a resilient HTTP client.
// 	return failsafehttp.NewClient(failsafehttp.WithRetryPolicy(retryPolicy))
// }

// GetJson performs a GET request to the given URL, checks the payload for valid JSON and returns the payload as a byte array.
// It retries failed requests according to the retry policy.
func (c *ResilientHttpClient) GetJson(ctx context.Context, url string) ([]byte, error) {
	GinkgoWriter.Println("Calling http GET on <", url, ">")

	executor := c.executor.WithContext(ctx)

	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	failsafeRequest := failsafehttp.NewRequestWithExecutor(request, http.DefaultClient, executor)

	response, err := failsafeRequest.Do()
	if err != nil {
		return nil, err
	}
	if response.Header.Get("Content-Type") != "application/json; charset=utf-8" {
		return nil, fmt.Errorf("unexpected content type <%s>", response.Header.Get("Content-Type"))
	}

	defer response.Body.Close()

	payload, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, err
	}
	if !json.Valid(payload) {
		return nil, fmt.Errorf("invalid JSON payload")
	}
	return payload, nil
}

// Get performs a GET request to the given URL and returns the payload as a byte array.
// It retries failed requests according to the retry policy.
func (c *ResilientHttpClient) Get(ctx context.Context, url string, tlsConfig *tls.Config, headers ...map[string]string) ([]byte, error) {
	GinkgoWriter.Println("Calling http GET on <", url, ">")

	executor := c.executor.WithContext(ctx)

	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	// Add headers if provided
	if len(headers) > 0 {
		for key, value := range headers[0] {
			request.Header.Add(key, value)
		}
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	if tlsConfig != nil {
		GinkgoWriter.Println("Using custom TLS config")
		transport.TLSClientConfig = tlsConfig
	}

	httpClient := &http.Client{Transport: transport}

	failsafeRequest := failsafehttp.NewRequestWithExecutor(request, httpClient, executor)

	response, err := failsafeRequest.Do()
	if err != nil {
		return nil, err
	}

	defer response.Body.Close()

	return io.ReadAll(response.Body)
}
