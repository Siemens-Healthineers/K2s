// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"errors"
	"k2s/setupinfo"
	ks "k2s/status"
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

func (m *mockObject) LoadAddonStatus(addonName string, addonDirectory string) (*AddonLoadStatus, error) {
	args := m.Called(addonName, addonDirectory)

	return args.Get(0).(*AddonLoadStatus), args.Error(1)
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

func (m *mockObject) Stop() error {
	args := m.Called()

	return args.Error(0)
}

func (m *mockObject) PrintProp(prop AddonStatusProp) {
	m.Called(prop)
}

func (m *mockObject) PrintNotInstalledMsg() {
	m.Called()
}

func (m *mockObject) PrintNotRunningMsg() {
	m.Called()
}

func (m *mockObject) PrintAddonNotFoundMsg(dir string, name string) {
	m.Called(dir, name)
}

func (m *mockObject) PrintNoAddonStatusMsg(name string) {
	m.Called(name)
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
			DescribeTable("known status errors occur", func(loadErr error, expectedErrMsg string) {
				addonName := "test-addon"
				addonDirectory := "test-dir"
				statusBytes := []byte("status")

				loaderMock := &mockObject{}
				loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonLoadStatus{}, loadErr)

				marshalMock := &mockObject{}
				marshalMock.On(r.GetFunctionName(marshalMock.MarshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
					return status.Name == addonName && string(*status.Error) == expectedErrMsg
				})).Return(statusBytes, nil)

				printerMock := &mockObject{}
				printerMock.On(r.GetFunctionName(printerMock.Println), "status").Once()

				sut := NewJsonPrinter(printerMock, loaderMock, marshalMock)

				err := sut.PrintStatus(addonName, addonDirectory)

				Expect(err).ToNot(HaveOccurred())
				printerMock.AssertExpectations(GinkgoT())
			},
				Entry("system-not-running", ks.ErrNotRunning, ks.ErrNotRunningMsg),
				Entry("system-not-installed", setupinfo.ErrNotInstalled, string(setupinfo.ErrNotInstalledMsg)),
				Entry("addon-not-found", ErrAddonNotFound, string(errAddonNotFoundMsg)),
				Entry("no-addon-status", ErrNoAddonStatus, string(errNoAddonStatusMsg)),
			)

			When("unknown status load error occurred", func() {
				It("returns error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					expectedError := errors.New("oops")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonLoadStatus{}, expectedError)

					sut := NewJsonPrinter(nil, loaderMock, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("marshalling error occurred", func() {
				It("returns error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					expectedError := errors.New("oops")
					loadStatus := &AddonLoadStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(loaderMock.MarshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.AddonLoadStatus.Props[0] == loadStatus.Props[0]
					})).Return(make([]byte, 0), expectedError)

					sut := NewJsonPrinter(nil, loaderMock, marshalMock)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("successful", func() {
				It("prints the status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					loadStatus := &AddonLoadStatus{Props: []AddonStatusProp{{Name: "test-key", Value: "test-val"}}}
					statusBytes := []byte("status")

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(loadStatus, nil)

					marshalMock := &mockObject{}
					marshalMock.On(r.GetFunctionName(marshalMock.MarshalIndent), mock.MatchedBy(func(status AddonPrintStatus) bool {
						return status.Name == addonName && status.AddonLoadStatus.Props[0] == loadStatus.Props[0]
					})).Return(statusBytes, nil)

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.Println), "status").Once()

					sut := NewJsonPrinter(printerMock, loaderMock, marshalMock)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
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

				sut := NewUserFriendlyPrinter(printerMock, nil, nil, nil)

				sut.PrintStatus("", "")

				printerMock.AssertExpectations(GinkgoT())
			})

			When("spinner start error occurred", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(nil, expectedError)

					sut := NewUserFriendlyPrinter(printerMock, nil, nil, nil)

					err := sut.PrintStatus("", "")

					Expect(err).To(MatchError(expectedError))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("spinner type conversion failed", func() {
				It("returns error", func() {
					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return("not-a-spinner", nil)

					sut := NewUserFriendlyPrinter(printerMock, nil, nil, nil)

					err := sut.PrintStatus("", "")

					Expect(err).To(MatchError(ContainSubstring("could not start")))
					printerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon-not-found error occurred", func() {
				It("prints addon-not-found error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.PrintAddonNotFoundMsg), addonDirectory, addonName).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonLoadStatus{}, ErrAddonNotFound)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, printerMock.PrintAddonNotFoundMsg, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("no-addon-status error occurred", func() {
				It("prints no-addon-status error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)
					printerMock.On(r.GetFunctionName(printerMock.PrintNoAddonStatusMsg), addonName).Once()

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonLoadStatus{}, ErrNoAddonStatus)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, printerMock.PrintNoAddonStatusMsg)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("unknown status load error occurred", func() {
				It("returns error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					expectedError := errors.New("oops")

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(&AddonLoadStatus{}, expectedError)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).To(MatchError(expectedError))
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("status does not contain enabled/disabled information", func() {
				It("returns error", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					status := &AddonLoadStatus{}

					spinnerMock := &mockObject{}
					spinnerMock.On(r.GetFunctionName(spinnerMock.Stop)).Return(nil).Once()

					printerMock := &mockObject{}
					printerMock.On(r.GetFunctionName(printerMock.PrintHeader), mock.Anything)
					printerMock.On(r.GetFunctionName(printerMock.StartSpinner), mock.Anything).Return(spinnerMock, nil)

					loaderMock := &mockObject{}
					loaderMock.On(r.GetFunctionName(loaderMock.LoadAddonStatus), addonName, addonDirectory).Return(status, nil)

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).To(MatchError(ContainSubstring("info missing")))
					spinnerMock.AssertExpectations(GinkgoT())
				})
			})

			When("addon is disabled", func() {
				It("prints the disabled-status", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					state := "disabled"
					enabled := false
					status := &AddonLoadStatus{Enabled: &enabled}

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

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
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
					status := &AddonLoadStatus{Enabled: &enabled}

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

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, nil)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
					printerMock.AssertExpectations(GinkgoT())
					spinnerMock.AssertExpectations(GinkgoT())
				})

				It("prints the addon-specific props", func() {
					addonName := "test-addon"
					addonDirectory := "test-dir"
					enabled := true
					status := &AddonLoadStatus{
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

					sut := NewUserFriendlyPrinter(printerMock, loaderMock, nil, nil, propPrintMock)

					err := sut.PrintStatus(addonName, addonDirectory)

					Expect(err).ToNot(HaveOccurred())
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
