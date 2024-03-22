// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package framework

import (
	"os"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

const (
	defaultTestStepTimeout      = 5 * time.Minute
	defaultTestStepPollInterval = 1 * time.Second
)

func determineProxy() string {
	proxy := os.Getenv("SYSTEM_TEST_PROXY")

	if proxy != "" {
		GinkgoWriter.Println("Proxy set to <", proxy, ">")
	}

	return proxy
}

func determineTestStepTimeout() time.Duration {
	return determineDurationFromEnv("SYSTEM_TEST_TIMEOUT", "Timeout", defaultTestStepTimeout)
}

func determineTestStepPollInterval() time.Duration {
	return determineDurationFromEnv("SYSTEM_TEST_POLL_INTERVAL", "Poll interval", defaultTestStepPollInterval)
}

func determineDurationFromEnv(key string, displayName string, defaultValue time.Duration) time.Duration {
	envValue := os.Getenv(key)

	if envValue != "" {
		GinkgoWriter.Println(displayName, "set to <", envValue, ">")

		value, err := time.ParseDuration(envValue)

		Expect(err).ToNot(HaveOccurred())

		return value
	}

	return defaultValue
}
