// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host_test

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type stdWriterMock struct {
	mock.Mock
}

func (m *stdWriterMock) WriteStdOut(message string) {
	m.Called(message)
}

func (m *stdWriterMock) WriteStdErr(message string) {
	m.Called(message)
}

func (m *stdWriterMock) Flush() {
	m.Called()
}

func TestHostPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "host pkg Integration Tests", Label("integration", "ci", "host"))
}

var _ = Describe("host pkg", func() {
	Describe("SystemDrive", func() {
		It("returns Windows system drive with trailing backslash", func() {
			drive := host.SystemDrive()

			Expect(drive).To(Equal("C:\\"))
		})
	})
	Describe("CreateDirIfNotExisting", func() {
		var dirToCreate string

		BeforeEach(func() {
			dirToCreate = filepath.Join(GinkgoT().TempDir(), "create", "me")

			GinkgoWriter.Println("Dir to create:", dirToCreate)
		})

		Context("dir not existing", func() {
			It("creates the dir", func() {
				Expect(host.PathExists(dirToCreate)).To(BeFalse())

				Expect(host.CreateDirIfNotExisting(dirToCreate)).To(Succeed())

				Expect(host.PathExists(dirToCreate)).To(BeTrue())
			})
		})

		Context("dir already existing", func() {
			It("returns without error", func() {
				Expect(os.MkdirAll(dirToCreate, os.ModePerm)).To(Succeed())
				Expect(host.PathExists(dirToCreate)).To(BeTrue())

				Expect(host.CreateDirIfNotExisting(dirToCreate)).To(Succeed())
			})
		})
	})

	Describe("ExecutableDir", func() {
		It("returns an existing directory", func() {
			dir, err := host.ExecutableDir()

			Expect(err).ToNot(HaveOccurred())

			GinkgoWriter.Println("Executable dir:", dir)

			info, err := os.Stat(dir)
			Expect(err).ToNot(HaveOccurred())
			Expect(info.IsDir()).To(BeTrue())
		})
	})

	Describe("PathExists", func() {
		When("path exists", func() {
			It("returns true", func() {
				input, err := os.Executable()
				Expect(err).ToNot(HaveOccurred())

				result := host.PathExists(input)

				Expect(result).To(BeTrue())
			})
		})

		When("path does not exist", func() {
			It("returns false", func() {
				input := filepath.Join(GinkgoT().TempDir(), "non-existent")

				result := host.PathExists(input)

				Expect(result).To(BeFalse())
			})
		})
	})

	Describe("ExecuteCmd", func() {
		When("command cannot be started", func() {
			It("returns error", func(ctx context.Context) {
				writerMock := &stdWriterMock{}

				sut := host.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("this-should-fail")

				Expect(err).To(MatchError(ContainSubstring("command could not be started")))
			})
		})

		When("command outputs text over stderr", func() {
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

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdErr), mock.MatchedBy(func(line string) bool {
					expectationFulfilled := true

					if (lineCounter+scriptLoC)%linesPerError == 0 {
						expectationFulfilled = Expect(line).To(MatchRegexp(".*: %d", numberCounter))

						numberCounter++
					}

					lineCounter++

					return expectationFulfilled
				})).Times(5 * linesPerError)
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := host.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).ToNot(HaveOccurred())

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		When("command outputs text over stdout", func() {
			It("calls stdout writer", func(ctx context.Context) {
				const script = `
						for ($i = 0; $i -lt 5; $i++) {
							Write-Output "$i"
						}
						`
				lineCounter := 0

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdOut), mock.MatchedBy(func(line string) bool {
					number, err := strconv.Atoi(line)

					Expect(err).ToNot(HaveOccurred())

					expectationFulfilled := number == lineCounter

					lineCounter++

					return expectationFulfilled
				})).Times(5)
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := host.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).ToNot(HaveOccurred())

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		When("command exits with non-zero exit code", func() {
			It("returns error with exit status text", func(ctx context.Context) {
				const script = "exit 123"

				writerMock := &stdWriterMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := host.NewCmdExecutor(writerMock).WithContext(ctx)

				err := sut.ExecuteCmd("powershell", script)

				Expect(err).To(MatchError(SatisfyAll(
					ContainSubstring("command failed"),
					ContainSubstring("exit status 123"),
				)))

				writerMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
