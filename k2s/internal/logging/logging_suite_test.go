// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging_test

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
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

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("logging", func() {
	Describe("RootLogDir", Label("integration"), func() {
		It("returns root log dir on Windows system drive", func() {
			dir := logging.RootLogDir()

			Expect(dir).To(Equal("C:\\var\\log"))
		})
	})

	Describe("GlobalLogFilePath", Label("integration"), func() {
		It("returns global file path on Windows system drive", func() {
			dir := logging.GlobalLogFilePath()

			Expect(dir).To(Equal("C:\\var\\log\\k2s.log"))
		})
	})

	Describe("InitializeLogFile", Label("integration", "ci"), func() {
		When("dir not existing", func() {
			It("creates dir and log file", func() {
				tempDir := GinkgoT().TempDir()
				logFilePath := filepath.Join(tempDir, "test-dir", "test.log")

				GinkgoWriter.Println("Creating test log file <", logFilePath, ">..")

				result := logging.InitializeLogFile(logFilePath)
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

				result := logging.InitializeLogFile(logFilePath)
				DeferCleanup(func() {
					GinkgoWriter.Println("Closing test log file <", logFilePath, ">..")
					Expect(result.Close()).To(Succeed())
				})

				_, err = result.WriteString("test")
				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("SetVerbosity", Label("unit", "ci"), func() {
		When("verbosity parsing failed", func() {
			It("returns error", func() {
				const verbosity = "<invalid>"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).To(MatchError(ContainSubstring("cannot convert")))
			})
		})

		When("verbosity passed as word", func() {
			It("returns correct level", func() {
				const verbosity = "debug"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).ToNot(HaveOccurred())
				Expect(levelVar.Level()).To(Equal(slog.LevelDebug))
			})
		})

		When("verbosity passed as number", func() {
			It("returns correct level", func() {
				const verbosity = "4"
				levelVar := new(slog.LevelVar)

				err := logging.SetVerbosity(verbosity, levelVar)

				Expect(err).ToNot(HaveOccurred())
				Expect(levelVar.Level()).To(Equal(slog.LevelWarn))
			})
		})
	})

	Describe("LevelToLowerString", Label("unit", "ci"), func() {
		It("converts level to lower string", func() {
			actual := logging.LevelToLowerString(slog.LevelWarn)

			Expect(actual).To(Equal("warn"))
		})
	})

	Describe("ShortenSourceAttribute", Label("unit", "ci"), func() {
		When("attribute is not source attribute", func() {
			It("does nothing", func() {
				input := slog.Attr{Key: "some-key", Value: slog.StringValue("some-value")}

				actual := logging.ShortenSourceAttribute(nil, input)

				Expect(actual).To(Equal(input))
			})
		})

		When("attribute is source attribute", func() {
			It("shortens the properties", func() {
				source := &slog.Source{
					Function: "some-function",
					File:     "c:\\this\\is\\a\\full\\file.path",
				}
				input := slog.Attr{Key: slog.SourceKey, Value: slog.AnyValue(source)}

				actual := logging.ShortenSourceAttribute(nil, input)

				actualSource := actual.Value.Any().(*slog.Source)

				Expect(actualSource.Function).To(BeEmpty())
				Expect(actualSource.File).To(Equal("file.path"))
			})
		})
	})

	Describe("LogBuffer", Label("unit", "ci"), func() {
		Describe("NewLogBuffer", func() {
			When("buffer limit is 0", func() {
				It("limit is reset to default", func() {
					const arbitraryOffset = 10
					called := false

					flushMock := &mockObject{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything).Once().Run(func(args mock.Arguments) {
						called = true

						buffer := args.Get(0).([]string)
						Expect(buffer).To(HaveLen(int(logging.DefaultBufferLimit)))
					})

					config := logging.BufferConfig{
						Limit:     0,
						FlushFunc: flushMock.Flush,
					}

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= int(logging.DefaultBufferLimit)+arbitraryOffset; i++ {
						buffer.Log("test")
					}

					Expect(called).To(BeTrue())
					flushMock.AssertExpectations(GinkgoT())
				})
			})

			When("flush function is nil", func() {
				It("function is set to stub doing nothing", func() {
					config := logging.BufferConfig{
						FlushFunc: nil,
						Limit:     5,
					}
					runs := config.Limit * 2 // ensure flush is called at least once

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= int(runs); i++ {
						buffer.Log("test")
					}
				})
			})

			When("limit and flush function set", func() {
				It("flush function is invoked when the limit is reached", func() {
					const limit = 5
					const invocations = 15
					expectedFlushTimes := invocations / limit

					flushMock := &mockObject{}
					flushMock.On(reflection.GetFunctionName(flushMock.Flush), mock.Anything).Times(expectedFlushTimes).Run(func(args mock.Arguments) {
						buffer := args.Get(0).([]string)
						Expect(buffer).To(HaveLen(limit))
					})

					config := logging.BufferConfig{
						Limit:     limit,
						FlushFunc: flushMock.Flush,
					}

					buffer := logging.NewLogBuffer(config)

					for i := 0; i <= invocations; i++ {
						buffer.Log("test")
					}

					flushMock.AssertExpectations(GinkgoT())
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

					logger := logging.NewLogBuffer(config)

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

					logger := logging.NewLogBuffer(config)

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

				logger := logging.NewLogBuffer(config)

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
