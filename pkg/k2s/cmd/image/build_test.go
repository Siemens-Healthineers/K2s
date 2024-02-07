//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package image

import (
	"fmt"

	"github.com/google/uuid"
	"github.com/spf13/cobra"

	p "k2s/cmd/params"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("build", func() {
	Describe("extractBuildOptions", func() {
		When("no flags set", func() {
			It("build options are created with default values", func() {
				testCommand := createTestCobraCommand()

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.InputFolder).To(Equal(defaultInputFolder))
				Expect(actual.Dockerfile).To(Equal(defaultDockerfile))
				Expect(actual.Windows).To(Equal(defaultWindowsFlag))
				Expect(actual.Output).To(BeFalse())
				Expect(actual.Push).To(Equal(defaultPushFlag))
				Expect(actual.ImageName).To(Equal(defaultImageNameToBeBuilt))
				Expect(actual.ImageTag).To(Equal(defaultImageTagToBeBuilt))
				Expect(actual.BuildArgs).To(BeEmpty())
				Expect(actual.BuildArgs).NotTo(BeNil())
			})
		})

		When("input folder is set", func() {
			It("build options contain input folder", func() {
				expected := "/tmp/docker-build/testapp"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(inputFolderFlagName, expected)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.InputFolder).To(Equal(expected))
			})
		})

		When("Dockerfile is set", func() {
			It("build options contain Dockerfile", func() {
				expected := "myDockerfile"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(dockerfileFlagName, expected)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Dockerfile).To(Equal(expected))
			})
		})

		When("image is set", func() {
			It("build options contain image", func() {
				imageNameToBeBuilt := "my-image"
				imageTagToBeBuilt := "my-tag"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(imageNameFlagName, imageNameToBeBuilt)
				testCommand.Flags().Set(imageTagFlagName, imageTagToBeBuilt)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.ImageName).To(Equal(imageNameToBeBuilt))
				Expect(actual.ImageTag).To(Equal(imageTagToBeBuilt))
			})
		})

		When("build args are set", func() {
			It("build options contain build args", func() {
				baseImageKey := "BaseImage"
				baseImageValue := "alpine"
				commitIdKey := "CommitId"
				commitIdValue := uuid.New().String()
				expected := make(map[string]string)
				expected[baseImageKey] = baseImageValue
				expected[commitIdKey] = commitIdValue
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgsFlagName, fmt.Sprintf("%s=%s", baseImageKey, baseImageValue))
				testCommand.Flags().Set(buildArgsFlagName, fmt.Sprintf("%s=%s", commitIdKey, commitIdValue))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.BuildArgs).To(Equal(expected))
			})
		})

		When("build args format invalid", func() {
			It("returns error", func() {
				buildArgInIncorrectFormat := "DummyValue"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgsFlagName, buildArgInIncorrectFormat)

				actual, err := extractBuildOptions(testCommand)

				Expect(actual).To(BeNil())
				Expect(err).To(HaveOccurred())
			})
		})

		When("Windows build flag is set", func() {
			It("Windows build is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(windowsFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Windows).To(Equal(expected))
			})
		})

		When("push enabled flag is set", func() {
			It("push is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(pushFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Push).To(Equal(expected))
			})
		})

		When("output enabled flag is set", func() {
			It("output is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(p.OutputFlagName, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Output).To(Equal(expected))
			})
		})
	})

	Describe("buildPsCmd", func() {
		When("only defaults are set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder ."))
			})
		})

		When("Windows option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Windows = true

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -Windows"))
			})
		})

		When("push option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Push = true

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -Push"))
			})
		})

		When("push Windows option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Push = true
				options.Windows = true

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -Windows", " -Push"))
			})
		})

		When("Dockerfile option is set", func() {
			It("returns correct command", func() {
				dockerfilePath := "MyDockerfile"
				options := newDefaultBuildOptions()
				options.Dockerfile = dockerfilePath

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -Dockerfile MyDockerfile"))
			})
		})

		When("input folder option is set", func() {
			It("returns correct command", func() {
				inputFolder := "MyInputFolder"
				options := newDefaultBuildOptions()
				options.InputFolder = inputFolder

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder MyInputFolder"))
			})
		})

		When("image option is set", func() {
			It("returns correct command", func() {
				imageName := "my-image"
				imageTag := "my-tag"
				options := newDefaultBuildOptions()
				options.ImageName = imageName
				options.ImageTag = imageTag

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -ImageName my-image", " -ImageTag my-tag"))
			})
		})

		When("build args are set", func() {
			It("returns correct command", func() {
				baseImageKey := "BaseImage"
				baseImageValue := "alpine"
				commitIdKey := "CommitId"
				commitIdValue := "e5d634c6-306a-42fe-a170-9da27951543b"
				buildArgs := make(map[string]string)
				buildArgs[baseImageKey] = baseImageValue
				buildArgs[commitIdKey] = commitIdValue
				options := newDefaultBuildOptions()
				options.BuildArgs = buildArgs

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -BuildArgs BaseImage=alpine,CommitId=e5d634c6-306a-42fe-a170-9da27951543b"))
			})
		})

		When("log option is set", func() {
			It("returns correct command", func() {
				enabledDetailedLogs := true
				options := newDefaultBuildOptions()
				options.Output = enabledDetailedLogs

				cmd, params := buildPsCmd(options)

				Expect(cmd).To(ContainSubstring("\\smallsetup\\common\\BuildImage.ps1"))
				Expect(params).To(ConsistOf(" -InputFolder .", " -ShowLogs"))
			})
		})
	})
})

func newDefaultBuildOptions() *buildOptions {
	return &buildOptions{
		InputFolder: defaultInputFolder,
		Dockerfile:  defaultDockerfile,
		Windows:     defaultWindowsFlag,
		ImageName:   defaultImageNameToBeBuilt,
		ImageTag:    defaultImageTagToBeBuilt,
		Output:      false,
		Push:        defaultPushFlag,
		BuildArgs:   make(map[string]string),
	}
}

func createTestCobraCommand() *cobra.Command {
	testCommand := &cobra.Command{
		Use: "test-commmand",
	}
	addInitFlagsForBuildCommand(testCommand)

	testCommand.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)

	return testCommand
}
