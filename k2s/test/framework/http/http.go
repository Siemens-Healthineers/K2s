// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package http

import (
	"context"
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
	httpClient *http.Client
	executor   failsafe.Executor[*http.Response]
}

func NewResilientHttpClient(requestTimeout time.Duration) *ResilientHttpClient {
	retryPolicy := retrypolicy.Builder[*http.Response]().
		WithBackoff(time.Second, time.Minute).
		WithJitterFactor(.25).
		WithMaxRetries(5).
		WithMaxDuration(requestTimeout).
		OnRetry(func(e failsafe.ExecutionEvent[*http.Response]) {
			GinkgoWriter.Println("Last attempt failed with error: ", e.LastError())
			GinkgoWriter.Printf("This is retry no. %d, elapsed time so far: %v,  retrying\n", e.Retries(), e.ElapsedTime())
		}).
		Build()

	return &ResilientHttpClient{
		httpClient: &http.Client{},
		executor:   failsafe.NewExecutor(retryPolicy),
	}
}

// GetJson performs a GET request to the given URL, checks the payload for valid JSON and returns the payload as a byte array.
// It retries failed requests according to the retry policy.
func (c *ResilientHttpClient) GetJson(ctx context.Context, url string) ([]byte, error) {
	GinkgoWriter.Println("Calling http GET on <", url, ">")

	executor := c.executor.WithContext(ctx)

	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	failsafeRequest := failsafehttp.NewRequestWithExecutor(request, c.httpClient, executor)

	response, err := failsafeRequest.Do()
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected http status code <%d>", response.StatusCode)
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
