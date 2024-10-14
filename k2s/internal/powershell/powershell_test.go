// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package powershell

import (
	"context"
	"errors"
	"log/slog"
	"os/exec"
	"strconv"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m mockObject) IsEncodedMessage(message string) bool {
	args := m.Called(message)

	return args.Bool(0)
}

func (m mockObject) DecodeMessage(message string, targetType string) ([]byte, error) {
	args := m.Called(message, targetType)

	return args.Get(0).([]byte), args.Error(1)
}

func (m mockObject) WriteStd(line string) {
	m.Called(line)
}

func (m mockObject) WriteErr(line string) {
	m.Called(line)
}

func (m mockObject) Flush() {
	m.Called()
}

func TestPowershellPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "powershell pkg Tests", Label("ci", "powershell"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("powershell pkg", func() {
	Describe("executor", Label("integration"), func() {
		Describe("execute", func() {
			When("command cannot be started", func() {
				It("return error", func(ctx context.Context) {
					cmd := exec.CommandContext(ctx, "this-should-fail")

					sut := &executor{}

					actual, err := sut.execute(cmd, "")

					Expect(err).To(MatchError(ContainSubstring("execution could not be started")))
					Expect(actual).To(BeEmpty())
				})
			})

			When("script outputs text over stderr", func() {
				It("calls stderr writer", func(ctx context.Context) {
					const (
						scriptLoC     = 4
						resultLines   = 1
						errorLines    = 3
						linesPerError = scriptLoC + resultLines + errorLines
						script        = `
							for ($i = 0; $i -lt 5; $i++) {
								Write-Error "$i"
							}
							exit 0
							`
					)

					lineCounter := 0
					numberCounter := 0

					writerMock := &mockObject{}
					writerMock.On(reflection.GetFunctionName(writerMock.WriteErr), mock.MatchedBy(func(line string) bool {
						expectationFulfilled := true

						if (lineCounter+scriptLoC)%linesPerError == 0 {
							expectationFulfilled = Expect(line).To(MatchRegexp(".*: %d", numberCounter))

							numberCounter++
						}

						lineCounter++

						return expectationFulfilled
					})).Times(5 * linesPerError)
					writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

					cmd := exec.CommandContext(ctx, string(Ps5CmdName), script)

					sut := &executor{
						writer: writerMock,
					}

					actual, err := sut.execute(cmd, "")

					Expect(err).ToNot(HaveOccurred())
					Expect(actual).To(BeEmpty())

					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("script outputs text over stdout", func() {
				It("calls stdout writer", func(ctx context.Context) {
					psCmd := `
							for ($i = 0; $i -lt 5; $i++) {
								Write-Output "$i"
							}
							`
					lineCounter := 0

					decoderMock := &mockObject{}
					decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), mock.AnythingOfType("string")).Return(false)

					writerMock := &mockObject{}
					writerMock.On(reflection.GetFunctionName(writerMock.WriteStd), mock.MatchedBy(func(line string) bool {
						number, err := strconv.Atoi(line)

						Expect(err).ToNot(HaveOccurred())

						expectationFulfilled := number == lineCounter

						lineCounter++

						return expectationFulfilled
					})).Times(5)
					writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

					cmd := exec.CommandContext(ctx, string(Ps5CmdName), psCmd)

					sut := &executor{
						decoder: decoderMock,
						writer:  writerMock,
					}

					actual, err := sut.execute(cmd, "")

					Expect(err).ToNot(HaveOccurred())
					Expect(actual).To(BeEmpty())

					decoderMock.AssertExpectations(GinkgoT())
					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("message decoding fails", func() {
				It("returns accumulated decoding errors", func(ctx context.Context) {
					psCmd := `
							for ($i = 0; $i -lt 3; $i++) {
								Write-Output "$i"
							}
							`

					decoderMock := &mockObject{}
					decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), mock.Anything).Return(true)
					decoderMock.On(reflection.GetFunctionName(decoderMock.DecodeMessage), mock.Anything, mock.Anything).Return([]byte{}, errors.New("oops"))

					writerMock := &mockObject{}
					writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

					cmd := exec.CommandContext(ctx, string(Ps5CmdName), psCmd)

					sut := &executor{
						decoder: decoderMock,
						writer:  writerMock,
					}

					actual, err := sut.execute(cmd, "")

					Expect(err).To(MatchError(ContainSubstring("oops\noops\noops")))
					Expect(actual).To(BeEmpty())

					decoderMock.AssertExpectations(GinkgoT())
					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("script outputs messages over stdout", func() {
				It("returns the decoded messages", func(ctx context.Context) {
					psCmd := `
							for ($i = 0; $i -lt 3; $i++) {
								Write-Output "$i"
							}
							`
					msgType := "test-type"
					decodeResult := message("test-result")
					lineCounter := 0

					decoderMock := &mockObject{}
					decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), mock.MatchedBy(func(line string) bool {
						_, err := strconv.Atoi(line)
						return err == nil
					})).Return(true)
					decoderMock.On(reflection.GetFunctionName(decoderMock.DecodeMessage), mock.MatchedBy(func(msg string) bool {
						number, err := strconv.Atoi(msg)

						Expect(err).ToNot(HaveOccurred())

						expectationFulfilled := number == lineCounter

						lineCounter++

						return expectationFulfilled
					}), msgType).Return([]byte(decodeResult), nil)

					writerMock := &mockObject{}
					writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

					cmd := exec.CommandContext(ctx, string(Ps5CmdName), psCmd)

					sut := &executor{
						decoder: decoderMock,
						writer:  writerMock,
					}

					actual, err := sut.execute(cmd, msgType)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual).To(ConsistOf(decodeResult, decodeResult, decodeResult))

					decoderMock.AssertExpectations(GinkgoT())
					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("script exits with non-zero exit code", func() {
				It("returns error", func(ctx context.Context) {
					const script = "exit 1"

					writerMock := &mockObject{}
					writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

					cmd := exec.CommandContext(ctx, string(Ps5CmdName), script)

					sut := &executor{
						writer: writerMock,
					}

					actual, err := sut.execute(cmd, "")

					Expect(err).To(MatchError(ContainSubstring("command execution failed")))
					Expect(actual).To(BeEmpty())

					writerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

	Describe("buildCmdString", Label("unit"), func() {
		When("no additional params", func() {
			It("returns cmd with default params only", func() {
				script := "some-script"
				targetType := "some-type"

				actual := buildCmdString(script, targetType)

				Expect(actual).To(Equal("some-script -EncodeStructuredOutput -MessageType some-type"))
			})
		})

		When("additional params", func() {
			It("returns cmd with all params", func() {
				script := "some-script"
				targetType := "some-type"
				params := []string{"-p1 test", "-p2", "-p3"}

				actual := buildCmdString(script, targetType, params...)

				Expect(actual).To(Equal("some-script -EncodeStructuredOutput -MessageType some-type -p1 test -p2 -p3"))
			})
		})
	})

	Describe("convertToResult", Label("unit"), func() {
		When("number of messages is unequal 1", func() {
			It("returns error", func() {
				actual, err := convertToResult[string]([]message{})

				Expect(err).To(MatchError(ContainSubstring("unexpected number of messages")))
				Expect(actual).To(BeEmpty())

				actual, err = convertToResult[string]([]message{{}, {}})

				Expect(err).To(MatchError(ContainSubstring("unexpected number of messages")))
				Expect(actual).To(BeEmpty())
			})
		})

		When("unmarshalling failes", func() {
			It("returns error", func() {
				msg := message("non-integer")

				actual, err := convertToResult[int]([]message{msg})

				Expect(err).To(MatchError(ContainSubstring("could not unmarshal message")))
				Expect(actual).To(BeZero())
			})
		})

		When("successful", func() {
			It("returns result", func() {
				expected := `["test-msg"]`
				msg := message(expected)

				actual, err := convertToResult[[]string]([]message{msg})

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal([]string{"test-msg"}))
			})
		})
	})
})
