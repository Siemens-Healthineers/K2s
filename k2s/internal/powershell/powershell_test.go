// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type decoderMock struct {
	mock.Mock
}

type writerMock struct {
	mock.Mock
}

func (m *decoderMock) IsEncodedMessage(message string) bool {
	args := m.Called(message)

	return args.Bool(0)
}

func (m *decoderMock) DecodeMessage(message string, targetType string) ([]byte, error) {
	args := m.Called(message, targetType)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *writerMock) WriteStdOut(message string) {
	m.Called(message)
}

func (m *writerMock) WriteStdErr(message string) {
	m.Called(message)
}

func (m *writerMock) Flush() {
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
	Describe("structuredOutputWriter", func() {
		Describe("WriteStdOut", func() {
			When("message is not encoded", func() {
				It("passes message to inner writer", func() {
					const message = "this is not encoded"

					decoderMock := &decoderMock{}
					decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), message).Return(false)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.WriteStdOut), message).Once()

					sut := &structuredOutputWriter{
						decoder:   decoderMock,
						stdWriter: writerMock,
					}

					sut.WriteStdOut(message)

					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("message is encoded", func() {
				When("decoding fails", func() {
					It("decoding errors are accumulated", func() {
						const message = "faulty message"
						const targetType = "some-type"

						decoderMock := &decoderMock{}
						decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), message).Return(true)
						decoderMock.On(reflection.GetFunctionName(decoderMock.DecodeMessage), message, targetType).Return([]byte{}, errors.New("oops"))

						sut := &structuredOutputWriter{
							decoder:    decoderMock,
							targetType: targetType,
						}

						sut.WriteStdOut(message)
						sut.WriteStdOut(message)
						sut.WriteStdOut(message)

						Expect(sut.decodeErrors).To(ConsistOf(
							MatchError("oops"),
							MatchError("oops"),
							MatchError("oops"),
						))
						Expect(sut.messages).To(BeEmpty())
					})
				})

				When("decoding succeeds", func() {
					It("messages are accumulated", func() {
						const inputMessage = "some-message"
						const targetType = "some-type"
						decodedMessage := []byte(inputMessage)

						decoderMock := &decoderMock{}
						decoderMock.On(reflection.GetFunctionName(decoderMock.IsEncodedMessage), inputMessage).Return(true)
						decoderMock.On(reflection.GetFunctionName(decoderMock.DecodeMessage), inputMessage, targetType).Return(decodedMessage, nil)

						sut := &structuredOutputWriter{
							decoder:    decoderMock,
							targetType: targetType,
						}

						sut.WriteStdOut(inputMessage)
						sut.WriteStdOut(inputMessage)
						sut.WriteStdOut(inputMessage)

						Expect(sut.messages).To(ConsistOf(
							message(inputMessage),
							message(inputMessage),
							message(inputMessage),
						))
						Expect(sut.decodeErrors).To(BeEmpty())
					})
				})
			})
		})

		Describe("WriteStdErr", func() {
			It("passes message to inner writer", func() {
				const message = "msg"

				writerMock := &writerMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdErr), message).Once()

				sut := &structuredOutputWriter{stdWriter: writerMock}

				sut.WriteStdErr(message)

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		Describe("Flush", func() {
			It("calls function of inner writer", func() {
				writerMock := &writerMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := &structuredOutputWriter{stdWriter: writerMock}

				sut.Flush()

				writerMock.AssertExpectations(GinkgoT())
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
