// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"testing"

	r "test/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
	"k8s.io/klog/v2"
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

func (m *mockObject) LoadAddonStatus(addonName string, addonDirectory string) (*AddonStatus, error) {
	args := m.Called(addonName, addonDirectory)

	return args.Get(0).(*AddonStatus), args.Error(1)
}

func (m *mockObject) MarshalIndent(data any) ([]byte, error) {
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

func (mo *mockObject) Fail(m ...any) {
	mo.Called(m...)
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
	RunSpecs(t, "addons status print Unit Tests", Label("unit"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("addons status print", func() {
	Describe("JsonPrinter", func() {
		Describe("PrintStatus", func() {
			When("status load error occurred", func() {
				It("returns without printing", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonStatus{}, errors.New("oops"))

					sut := NewJsonPrinter(nil, loaderMock, nil)

					sut.PrintStatus(addonName, addonDirectory)
				})
			})

			When("marshalling error occurred", func() {
				It("returns without printing", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					status := &AddonStatus{}

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(loaderMock.MarshalIndent), status).Return(make([]byte, 0), errors.New("oops"))

					sut := NewJsonPrinter(nil, loaderMock, marshalMock)

					sut.PrintStatus(addonName, addonDirectory)
				})
			})

			When("successful", func() {
				It("prints the status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					status := &AddonStatus{}
					statusBytes := []byte("status")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.MarshalIndent), status).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status").Once()

					sut := NewJsonPrinter(printerMock, loaderMock, marshalMock)

					sut.PrintStatus(addonName, addonDirectory)

					printerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

	Describe("UserFriendlyPrinter", func() {
		Describe("PrintStatus", func() {
			It("prints the header", func() {
				printerMock := &mockObject{}
				printerMock.On(r.GetFunctionName(printerMock.PrintHeader), "ADDON STATUS").Once()
				printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, errors.New("oops"))
				printerMock.On(r.GetFunctionName(printerMock.Println))

				sut := NewUserFriendlyPrinter(printerMock, nil)

				sut.PrintStatus("", "")

				printerMock.AssertExpectations(GinkgoT())
			})

			When("spinner start error occurred", func() {
				It("returns without printing the status", func() {
					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, errors.New("oops"))
					printerMock.On(r.GetFunctionName(printerMock.Println)).Once()

					sut := NewUserFriendlyPrinter(printerMock, nil)

					sut.PrintStatus("", "")

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("spinner type conversion failed", func() {
				It("returns without printing the status", func() {
					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return("not-a-spinner", nil)
					printerMock.On(r.GetFunctionName(printerMock.Println)).Once()

					sut := NewUserFriendlyPrinter(printerMock, nil)

					sut.PrintStatus("", "")

					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status load error occurred", func() {
				It("returns without printing the status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Fail), mock.Anything).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println)).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonStatus{}, errors.New("oops"))

					sut := NewUserFriendlyPrinter(printerMock, loaderMock)

					sut.PrintStatus(addonName, addonDirectory)

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status contains error", func() {
				It("prints the status error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					err := "test-error"
					status := &AddonStatus{Error: &err}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), err).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock)

					sut.PrintStatus(addonName, addonDirectory)

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status does not contain enabled/disabled information", func() {
				It("returns without printing the error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					status := &AddonStatus{}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock)

					sut.PrintStatus(addonName, addonDirectory)

					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is disabled", func() {
				It("prints the disabled-status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					state := "disabled"
					enabled := false
					status := &AddonStatus{Name: addonName, Enabled: &enabled}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock)

					sut.PrintStatus(addonName, addonDirectory)

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is enabled", func() {
				It("prints the enabled-status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					state := "enabled"
					enabled := true
					status := &AddonStatus{Name: addonName, Enabled: &enabled}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.Println), "Addon", addonName, "is", state).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), addonName).Return(addonName).Once()
					printerMock.On(r.GetFunctionName(printerMock.PrintCyanFg), state).Return(state).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock)

					sut.PrintStatus(addonName, addonDirectory)

					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})

				It("prints the addon-specific props", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					enabled := true
					status := &AddonStatus{
						Name:    addonName,
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
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					propPrintMock := &mockObject{}
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), status.Props[0]).Once()
					propPrintMock.On(r.GetFunctionName(propPrintMock.PrintProp), status.Props[1]).Once()

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, propPrintMock)

					sut.PrintStatus(addonName, addonDirectory)

					propPrintMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})
		})

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
