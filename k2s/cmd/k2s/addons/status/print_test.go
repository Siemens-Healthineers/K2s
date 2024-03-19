// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	r "github.com/siemens-healthineers/k2s/internal/reflection"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

type nullableOkay struct {
	value bool
}

type nullableMessage struct {
	value string
}

func (m *mockObject) loadAddonStatus(addonName string) (*LoadedAddonStatus, error) {
	args := m.Called(addonName)

	return args.Get(0).(*LoadedAddonStatus), args.Error(1)
}

func (m *mockObject) marshalIndent(data any) ([]byte, error) {
	args := m.Called(data)

	return args.Get(0).([]byte), args.Error(1)
}

func (mo *mockObject) Println(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintSuccess(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintWarning(m ...any) {
	mo.Called(m...)
}

func (mo *mockObject) PrintHeader(m ...any) {
	mo.Called(m...)
}

func (m *mockObject) PrintCyanFg(text string) string {
	args := m.Called(text)

	return args.String(0)
}

func (mo *mockObject) StartSpinner(m ...any) (any, error) {
	args := mo.Called(m...)

	return args.Get(0), args.Error(1)
}

func (m *mockObject) Stop() error {
	args := m.Called()

	return args.Error(0)
}

func (m *mockObject) PrintProp(prop AddonStatusProp) {
	m.Called(prop)
}

func TestPrint(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons status print Unit Tests", Label("unit", "ci", "status"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("addons status print", func() {
	Describe("JsonPrinter", func() {
		Describe("PrintStatus", func() {
			When("status load error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(&LoadedAddonStatus{}, expectedError)

					sut := NewJsonPrinter(nil, nil)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("cmd failure occurred", func() {
				It("prints JSON with failure and returns silent cmd failure", func() {
					addonName := "test-addon"
					statusBytes := []byte("status-JSON")
					loadedStatus := &LoadedAddonStatus{CmdResult: common.CreateSystemNotInstalledCmdResult()}

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && *status.Error == loadedStatus.Failure.Code
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status-JSON").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					var cmdFailure *common.CmdFailure
					Expect(errors.As(err, &cmdFailure)).To(BeTrue())
					Expect(cmdFailure.Code).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
					Expect(cmdFailure.Message).To(Equal(common.ErrSystemNotInstalledMsg))
					Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
					Expect(cmdFailure.SuppressCliOutput).To(BeTrue())

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("marshalling error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")
					loadStatus := &LoadedAddonStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.Props[0] == loadStatus.Props[0]
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, marshalMock.marshalIndent)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints the status without error", func() {
					addonName := "test-addon"
					loadStatus := &LoadedAddonStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}
					statusBytes := []byte("status")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.Props[0] == loadStatus.Props[0]
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("PrintSystemNotInstalledError", func() {
			When("marshalling error occurred", func() {
				It("returns error without printing", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, marshalMock.marshalIndent)

					err := sut.PrintSystemNotInstalledError(addonName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints JSON with failure and returns silent cmd failure", func() {
					addonName := "test-addon"
					statusBytes := []byte("status-JSON")

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.marshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && *status.Error == setupinfo.ErrSystemNotInstalled.Error()
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status-JSON").Once()

					sut := NewJsonPrinter(printerMock, marshalMock.marshalIndent)

					err := sut.PrintSystemNotInstalledError(addonName)

					var cmdFailure *common.CmdFailure
					Expect(errors.As(err, &cmdFailure)).To(BeTrue())
					Expect(cmdFailure.Code).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
					Expect(cmdFailure.Message).To(Equal(common.ErrSystemNotInstalledMsg))
					Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
					Expect(cmdFailure.SuppressCliOutput).To(BeTrue())

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

	Describe("UserFriendlyPrinter", func() {
		Describe("PrintStatus", func() {
			When("spinner start error occurred", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, expectedError)

					sut := NewUserFriendlyPrinter(printerMock, nil)

					err := sut.PrintStatus("", nil)

					Expect(err).To(MatchError(expectedError))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("spinner type conversion failed", func() {
				It("returns error", func() {
					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return("not-a-spinner", nil)

					sut := NewUserFriendlyPrinter(printerMock, nil)

					err := sut.PrintStatus("", nil)

					Expect(err).To(MatchError(ContainSubstring("could not start")))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("unknown status load error occurred", func() {
				It("returns error", func() {
					addonName := "test-addon"
					expectedError := errors.New("oops")

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(&LoadedAddonStatus{}, expectedError)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(expectedError))

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("cmd failure occurred", func() {
				It("returns cmd failure", func() {
					addonName := "test-addon"
					loadedStatus := &LoadedAddonStatus{CmdResult: common.CreateSystemNotInstalledCmdResult()}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).To(Equal(loadedStatus.Failure))

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status does not contain enabled/disabled information", func() {
				It("returns error", func() {
					addonName := "test-addon"
					loadedStatus := &LoadedAddonStatus{}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).To(MatchError(ContainSubstring("info missing")))

					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is disabled", func() {
				It("prints the disabled-status", func() {
					addonName := "test-addon"
					state := "disabled"
					enabled := false
					loadedStatus := &LoadedAddonStatus{Enabled: &enabled}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is enabled", func() {
				It("prints the enabled-status", func() {
					addonName := "test-addon"
					state := "enabled"
					enabled := true
					loadedStatus := &LoadedAddonStatus{Enabled: &enabled}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					sut := NewUserFriendlyPrinter(printerMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})

				It("prints the addon-specific props", func() {
					addonName := "test-addon"
					enabled := true
					loadedStatus := &LoadedAddonStatus{
						Enabled: &enabled,
						Props: []AddonStatusProp{
							{Name: "p1"},
							{Name: "p2"},
						},
					}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), mock.Anything, mock.Anything, mock.Anything, mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), mock.Anything).Return("colored-text")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.loadAddonStatus), addonName).Return(loadedStatus, nil)

					propPrintMock := &mockObject{}
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), loadedStatus.Props[0]).Once()
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), loadedStatus.Props[1]).Once()

					sut := NewUserFriendlyPrinter(printerMock, propPrintMock)

					err := sut.PrintStatus(addonName, loaderMock.loadAddonStatus)

					Expect(err).ToNot(HaveOccurred())
					propPrintMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("PrintSystemNotInstalledError", func() {
			It("returns system-not-installed command failure", func() {
				sut := NewUserFriendlyPrinter(nil)

				err := sut.PrintSystemNotInstalledError("")

				var cmdFailure *common.CmdFailure
				Expect(errors.As(err, &cmdFailure)).To(BeTrue())
				Expect(cmdFailure.Code).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
				Expect(cmdFailure.Message).To(Equal(common.ErrSystemNotInstalledMsg))
				Expect(cmdFailure.Severity).To(Equal(common.SeverityWarning))
				Expect(cmdFailure.SuppressCliOutput).To(BeFalse())
			})
		})
	})

	Describe("propPrint", func() {
		Describe("PrintProp", func() {
			It("orchestrates text colorization and printing", func() {
				okay := false
				message := "my-msg"
				prop := AddonStatusProp{Okay: &okay, Message: &message}

				printerMock := &mockObject{}
				printerMock.On(r.GetFunctionName(printerMock.PrintWarning), message).Once()

				sut := NewPropPrinter(printerMock)

				sut.PrintProp(prop)

				printerMock.AssertExpectations(GinkgoT())
			})
		})

		DescribeTable("GetPropText", func(name string, value any, okay *nullableOkay, message *nullableMessage, colorizedResult string, expectedResult string) {
			prop := AddonStatusProp{Name: name, Value: value}
			if okay != nil {
				prop.Okay = &okay.value
			}
			if message != nil {
				prop.Message = &message.value
			}

			printerMock := &mockObject{}
			printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), colorizedResult).Return(colorizedResult)

			sut := NewPropPrinter(printerMock)

			result := sut.GetPropText(prop)

			Expect(result).To(Equal(expectedResult))
		},
			Entry("name, value", "test-prop", 123, nil, nil, "123", "test-prop: 123"),
			Entry("name, value, message", "test-prop", 123, nil, &nullableMessage{value: "my-msg"}, "my-msg", "my-msg"),
			Entry("name, value, okay", "test-prop", 123, &nullableOkay{value: true}, nil, "", "test-prop: 123"),
			Entry("name, value, message, okay", "test-prop", 123, &nullableOkay{value: true}, &nullableMessage{value: "my-msg"}, "", "my-msg"),
		)

		Describe("PrintPropText", func() {
			When("no okay-info is present", func() {
				It("prints neutral", func() {
					text := "test"

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(nil, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("okay", func() {
				It("prints success", func() {
					text := "test"
					okay := true

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintSuccess), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(&okay, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("not okay", func() {
				It("prints warning", func() {
					text := "test"
					okay := false

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintWarning), text).Once()

					sut := NewPropPrinter(printerMock)

					sut.PrintPropText(&okay, text)

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
