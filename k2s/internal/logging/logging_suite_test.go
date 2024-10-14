// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package logging_test

import (
	"testing"

	"github.com/siemens-healthineers/k2s/internal/logging"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Flush(buffer []string) {
	m.Called(buffer)
}

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Logging Tests", Label("logging"))
}

var _ = Describe("logging", func() {
	Describe("RootLogDir", Label("integration"), func() {
		It("return root log dir on Windows system drive", func() {
			dir := logging.RootLogDir()

			Expect(dir).To(Equal("C:\\var\\log"))
		})
	})

	Describe("LogBuffer", Label("unit", "ci"), func() {
		Describe("NewLogBuffer", func() {
			When("buffer limit is 0", func() {
				It("returns error", func() {
					config := logging.BufferConfig{
						Limit: 0,
					}

					result, err := logging.NewLogBuffer(config)

					Expect(result).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("limit must be greater than 0")))
				})
			})

			When("flush function is nil", func() {
				It("returns error", func() {
					config := logging.BufferConfig{
						Limit: 1,
					}

					result, err := logging.NewLogBuffer(config)

					Expect(result).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("flush function must not be nil")))
				})
			})

			When("config is valid", func() {
				It("returns buffer", func() {
					config := logging.BufferConfig{
						Limit: 1,
						FlushFunc: func(buffer []string) {
							// empty
						},
					}

					result, err := logging.NewLogBuffer(config)

					Expect(result).ToNot(BeNil())
					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("Log", func() {
			When("buffer limit is not reached", func() {
				It("log line is written to buffer only", func() {
					flushMock := &mockObject{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					config := logging.BufferConfig{
						Limit:     4,
						FlushFunc: flushMock.Flush,
					}

					logger, err := logging.NewLogBuffer(config)

					Expect(err).ToNot(HaveOccurred())

					logger.Log("a")
					logger.Log("b")
					logger.Log("c")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					logger.Flush()

					flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
				})
			})

			When("buffer limit is reached", func() {
				It("log line is written to buffer and buffer is flushed", func() {
					flushMock := &mockObject{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					config := logging.BufferConfig{
						Limit:     3,
						FlushFunc: flushMock.Flush,
					}

					logger, err := logging.NewLogBuffer(config)

					Expect(err).ToNot(HaveOccurred())

					logger.Log("a")
					logger.Log("b")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					logger.Log("c")

					flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					flushMock.Calls = []mock.Call{}

					logger.Log("d")

					flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
				})
			})
		})

		Describe("Flush", func() {
			It("flushes the content in correct format and emties the buffer", func() {
				flushMock := &mockObject{}
				flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

				config := logging.BufferConfig{
					Limit:     4,
					FlushFunc: flushMock.Flush,
				}

				logger, err := logging.NewLogBuffer(config)

				Expect(err).ToNot(HaveOccurred())

				logger.Log("a")
				logger.Log("b")
				logger.Log("c")

				flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)

				logger.Flush()

				flushMock.AssertCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.MatchedBy(func(buffer []string) bool {
					return Expect(buffer).To(ContainElements([]string{"a", "b", "c"}))
				}))

				flushMock.Calls = []mock.Call{}

				logger.Flush()

				flushMock.AssertNotCalled(GinkgoT(), reflection.GetFunctionName(flushMock.Flush), mock.Anything)
			})
		})
	})
})
