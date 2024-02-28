// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package runningstate_test

import (
	"k2s/cmd/status/common"
	rs "k2s/cmd/status/runningstate"
	"strings"
	"test/reflection"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (mo *mockObject) PrintSuccess(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintInfoln(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintTreeListItems(items []string) {
	mo.Called(items)
}

func TestRunningstate(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "runningstate Unit Tests", Label("unit", "ci"))
}

var _ = Describe("runningstate", func() {
	Describe("PrintRunningState", func() {
		When("no info provided", func() {
			It("returns error", func() {
				sut := rs.NewRunningStatePrinter(nil)

				actual, err := sut.PrintRunningState(nil)

				Expect(err).To(MatchError(MatchRegexp("no.+info retrieved")))
				Expect(actual).To(BeFalse())
			})
		})

		When("system is running", func() {
			It("logs success and proceeds", func() {
				state := &common.RunningState{IsRunning: true}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintSuccess), mock.MatchedBy(func(m string) bool {
					return strings.Contains(m, "is running")
				}))

				sut := rs.NewRunningStatePrinter(printerMock)

				actual, err := sut.PrintRunningState(state)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeTrue())

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		When("system is not running", func() {
			It("logs info and does not proceed", func() {
				state := &common.RunningState{
					IsRunning: false,
					Issues:    []string{"problem-1", "problem-2"}}

				printerMock := &mockObject{}
				printerMock.On(reflection.GetFunctionName(printerMock.PrintInfoln), mock.MatchedBy(func(m string) bool {
					return strings.Contains(m, "is not running")
				}))
				printerMock.On(reflection.GetFunctionName(printerMock.PrintTreeListItems), state.Issues)

				sut := rs.NewRunningStatePrinter(printerMock)

				actual, err := sut.PrintRunningState(state)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(BeFalse())

				printerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
