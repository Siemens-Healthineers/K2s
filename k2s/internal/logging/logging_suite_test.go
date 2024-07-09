// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging

import (
	"os"
	"path/filepath"
	"testing"

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
		It("returns root log dir on Windows system drive", func() {
			dir := RootLogDir()

			Expect(dir).To(Equal("C:\\var\\log"))
		})
	})

	Describe("GlobalLogFilePath", Label("integration"), func() {
		It("returns global file path on Windows system drive", func() {
			dir := GlobalLogFilePath()

			Expect(dir).To(Equal("C:\\var\\log\\k2s.log"))
		})
	})

	Describe("InitializeLogFile", func() {
		When("dir not existing", func() {
			It("creates dir and log file", func() {
				tempDir := GinkgoT().TempDir()
				logFilePath := filepath.Join(tempDir, "test-dir", "test.log")

				GinkgoWriter.Println("Creating test log file <", logFilePath, ">..")

				result := InitializeLogFile(logFilePath)
				DeferCleanup(func() {
					GinkgoWriter.Println("Closing test log file <", logFilePath, ">..")
					Expect(result.Close()).To(Succeed())
				})

				_, err := result.WriteString("test")
				Expect(err).ToNot(HaveOccurred())
			})
		})

		When("dir and log file existing", func() {
			It("opens existing log file", func() {
				tempDir := GinkgoT().TempDir()
				logFilePath := filepath.Join(tempDir, "test.log")
				logFile, err := os.OpenFile(
					logFilePath,
					os.O_APPEND|os.O_CREATE|os.O_WRONLY,
					os.ModePerm,
				)
				Expect(err).ToNot(HaveOccurred())

				_, err = logFile.WriteString("initial-content")
				Expect(err).ToNot(HaveOccurred())
				Expect(logFile.Close()).To(Succeed())

				GinkgoWriter.Println("Opening test log file <", logFilePath, ">..")

				result := InitializeLogFile(logFilePath)
				DeferCleanup(func() {
					GinkgoWriter.Println("Closing test log file <", logFilePath, ">..")
					Expect(result.Close()).To(Succeed())
				})

				_, err = result.WriteString("test")
				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("LogBuffer", Label("unit", "ci"), func() {
		Describe("NewLogBuffer", func() {
			When("buffer limit is 0", func() {
				It("limit is reset to default", func() {
					config := BufferConfig{
						Limit: 0,
					}

					result := NewLogBuffer(config)

					Expect(result.config.Limit).To(Equal(DefaultBufferLimit))
				})
			})

			When("flush function is nil", func() {
				It("function is set to default", func() {
					config := BufferConfig{
						FlushFunc: nil,
					}

					result := NewLogBuffer(config)

					Expect(result.config.FlushFunc).NotTo(BeNil())
				})
			})

			When("limit and flush function set", func() {
				It("config values set correctly", func() {
					called := false
					config := BufferConfig{
						Limit:     1,
						FlushFunc: func(_ []string) { called = true },
					}

					result := NewLogBuffer(config)
					result.config.FlushFunc(nil)

					Expect(result.config.Limit).To(Equal(config.Limit))
					Expect(called).To(BeTrue())
				})
			})
		})

		Describe("Log", func() {
			When("buffer limit is not reached", func() {
				It("log line is written to buffer only", func() {
					flushMock := &mockObject{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything)

					config := BufferConfig{
						Limit:     4,
						FlushFunc: flushMock.Flush,
					}

					logger := NewLogBuffer(config)

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

					config := BufferConfig{
						Limit:     3,
						FlushFunc: flushMock.Flush,
					}

					logger := NewLogBuffer(config)

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

				config := BufferConfig{
					Limit:     4,
					FlushFunc: flushMock.Flush,
				}

				logger := NewLogBuffer(config)

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
