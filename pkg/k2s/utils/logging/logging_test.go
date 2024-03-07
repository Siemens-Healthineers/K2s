// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging_test

import (
	r "test/reflection"
	"testing"

	sut "k2s/utils/logging"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
	"k8s.io/klog/v2"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Flush(args ...any) {
	m.Called(args...)
}

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "logging Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("logBuffer", func() {
	Describe("NewLogBuffer", func() {
		When("buffer limit is 0", func() {
			It("returns error", func() {
				config := sut.BufferConfig{
					Limit: 0,
				}

				result, err := sut.NewLogBuffer(config)

				Expect(result).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("limit must be greater than 0")))
			})
		})

		When("flush function is nil", func() {
			It("returns error", func() {
				config := sut.BufferConfig{
					Limit: 1,
				}

				result, err := sut.NewLogBuffer(config)

				Expect(result).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("flush function must not be nil")))
			})
		})

		When("config is valid", func() {
			It("returns buffer", func() {
				config := sut.BufferConfig{
					Limit: 1,
					FlushFunc: func(args ...any) {
						// empty
					},
				}

				result, err := sut.NewLogBuffer(config)

				Expect(result).ToNot(BeNil())
				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("Log", func() {
		When("buffer limit is not reached", func() {
			It("log line is written to buffer only", func() {
				flushMock := &mockObject{}
				flushMock.On(r.GetFunctionName(flushMock.Flush), mock.Anything)

				config := sut.BufferConfig{
					Limit:     4,
					FlushFunc: flushMock.Flush,
				}

				logger, err := sut.NewLogBuffer(config)

				Expect(err).ToNot(HaveOccurred())

				logger.Log("a")
				logger.Log("b")
				logger.Log("c")

				flushMock.AssertNotCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)

				logger.Flush()

				flushMock.AssertCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)
			})
		})

		When("buffer limit is reached", func() {
			It("log line is written to buffer and buffer is flushed", func() {
				flushMock := &mockObject{}
				flushMock.On(r.GetFunctionName(flushMock.Flush), mock.Anything)

				config := sut.BufferConfig{
					Limit:     3,
					FlushFunc: flushMock.Flush,
				}

				logger, err := sut.NewLogBuffer(config)

				Expect(err).ToNot(HaveOccurred())

				logger.Log("a")
				logger.Log("b")

				flushMock.AssertNotCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)

				logger.Log("c")

				flushMock.AssertCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)
			})
		})
	})

	Describe("Flush", func() {
		It("flushes the content in correct format and emties the buffer", func() {
			flushMock := &mockObject{}
			flushMock.On(r.GetFunctionName(flushMock.Flush), mock.Anything)

			config := sut.BufferConfig{
				Limit:     4,
				FlushFunc: flushMock.Flush,
			}

			logger, err := sut.NewLogBuffer(config)

			Expect(err).ToNot(HaveOccurred())

			logger.Log("a")
			logger.Log("b")
			logger.Log("c")

			flushMock.AssertNotCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)

			logger.Flush()

			flushMock.AssertCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.MatchedBy(func(squashedResult string) bool {
				return squashedResult == "a\nb\nc"
			}))

			flushMock.Calls = []mock.Call{}

			logger.Flush()

			flushMock.AssertNotCalled(GinkgoT(), r.GetFunctionName(flushMock.Flush), mock.Anything)
		})
	})
})
