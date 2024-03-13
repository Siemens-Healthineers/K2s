// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package json_test

import (
	"errors"
	"testing"

	r "github.com/siemens-healthineers/k2s/internal/reflection"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/json"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/load"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) MarshalIndent(data any) ([]byte, error) {
	args := m.Called(data)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *mockObject) Println(msg ...any) {
	m.Called(msg...)
}

func TestJson(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "json Unit Tests", Label("unit", "ci"))
}

var _ = Describe("json", func() {
	Describe("PrintJson", func() {
		When("error occurred", func() {
			It("returns the error", func() {
				input := &load.LoadedStatus{}
				expected := errors.New("oops")
				marshallerMock := &mockObject{}
				marshallerMock.On(r.GetFunctionName(marshallerMock.MarshalIndent), input).Return([]byte{}, expected)
				sut := json.NewJsonPrinter(nil, marshallerMock)

				err := sut.PrintJson(input)

				Expect(err).To(MatchError(expected))
			})
		})

		When("successful", func() {
			It("prints the status as JSON and returns nil", func() {
				input := &load.LoadedStatus{}
				expected := "test"
				marshallerMock := &mockObject{}
				printerMock := &mockObject{}
				marshallerMock.On(r.GetFunctionName(marshallerMock.MarshalIndent), input).Return([]byte(expected), nil)
				printerMock.On(r.GetFunctionName(printerMock.Println), expected).Once()
				sut := json.NewJsonPrinter(printerMock, marshallerMock)

				err := sut.PrintJson(input)

				Expect(err).ToNot(HaveOccurred())
				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
