//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package image

import (
	"fmt"
	"regexp"

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
				testCommand.Flags().Set(inputFolder, expected)

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.InputFolder).To(Equal(expected))
			})
		})

		When("Dockerfile is set", func() {
			It("build options contain Dockerfile", func() {
				expected := "myDockerfile"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(dockerfile, expected)

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
				testCommand.Flags().Set(imageName, imageNameToBeBuilt)
				testCommand.Flags().Set(imageTag, imageTagToBeBuilt)

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
				testCommand.Flags().Set(buildArgs, fmt.Sprintf("%s=%s", baseImageKey, baseImageValue))
				testCommand.Flags().Set(buildArgs, fmt.Sprintf("%s=%s", commitIdKey, commitIdValue))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.BuildArgs).To(Equal(expected))
			})
		})

		When("build args format invalid", func() {
			It("returns error", func() {
				buildArgInIncorrectFormat := "DummyValue"
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(buildArgs, buildArgInIncorrectFormat)

				actual, err := extractBuildOptions(testCommand)

				Expect(actual).To(BeNil())
				Expect(err).To(HaveOccurred())
			})
		})

		When("Windows build flag is set", func() {
			It("Windows build is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(windows, fmt.Sprintf("%t", expected))

				actual, err := extractBuildOptions(testCommand)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Windows).To(Equal(expected))
			})
		})

		When("push enabled flag is set", func() {
			It("push is enabled in build options", func() {
				expected := true
				testCommand := createTestCobraCommand()
				testCommand.Flags().Set(push, fmt.Sprintf("%t", expected))

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

	Describe("createBuildCommand", func() {
		When("only defaults are set", func() {
			It("returns correct command", func() {
				defaultOptions := newDefaultBuildOptions()
				expected := getBuildCommandBase() + " -InputFolder ."

				actual := createBuildCommand(defaultOptions)

				Expect(actual).To(Equal(expected))
			})
		})

		When("Windows option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Windows = true
				expected := getBuildCommandBase() + " -InputFolder . -Windows"

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("push option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Push = true
				expected := getBuildCommandBase() + " -InputFolder . -Push"

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("push Windows option is set", func() {
			It("returns correct command", func() {
				options := newDefaultBuildOptions()
				options.Push = true
				options.Windows = true
				expected := getBuildCommandBase() + " -InputFolder . -Windows -Push"

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("Dockerfile option is set", func() {
			It("returns correct command", func() {
				dockerfilePath := "MyDockerfile"
				options := newDefaultBuildOptions()
				options.Dockerfile = dockerfilePath
				expected := fmt.Sprintf("%s -InputFolder . -Dockerfile %s", getBuildCommandBase(), dockerfilePath)

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("input folder option is set", func() {
			It("returns correct command", func() {
				inputFolder := "MyInputFolder"
				options := newDefaultBuildOptions()
				options.InputFolder = inputFolder
				expected := fmt.Sprintf("%s -InputFolder %s", getBuildCommandBase(), inputFolder)

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("image option is set", func() {
			It("returns correct command", func() {
				imageName := "my-image"
				imageTag := "my-tag"
				options := newDefaultBuildOptions()
				options.ImageName = imageName
				options.ImageTag = imageTag
				expected := fmt.Sprintf("%s -InputFolder . -ImageName %s -ImageTag %s", getBuildCommandBase(), imageName, imageTag)

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})

		When("build args are set", func() {
			It("returns correct command", func() {
				baseImageKey := "BaseImage"
				baseImageValue := "alpine"
				commitIdKey := "CommitId"
				commitIdValue := uuid.New().String()
				buildArgs := make(map[string]string)
				buildArgs[baseImageKey] = baseImageValue
				buildArgs[commitIdKey] = commitIdValue
				options := newDefaultBuildOptions()
				options.BuildArgs = buildArgs
				expected := fmt.Sprintf("%s -InputFolder . -BuildArgs %s=%s,%s=%s", getBuildCommandBase(), baseImageKey, baseImageValue, commitIdKey, commitIdValue)

				actual := createBuildCommand(options)

				expectBuildCommandsWIthBuildArgsToBeEqual(actual, expected)
			})
		})

		When("log option is set", func() {
			It("returns correct command", func() {
				enabledDetailedLogs := true
				options := newDefaultBuildOptions()
				options.Output = enabledDetailedLogs
				expected := fmt.Sprintf("%s -InputFolder . -ShowLogs", getBuildCommandBase())

				actual := createBuildCommand(options)

				Expect(actual).To(Equal(expected))
			})
		})
	})
})

func newDefaultBuildOptions() *buildOptions {
	defaultBuildArgsMap := make(map[string]string)
	return newBuildOptions(
		defaultInputFolder,
		defaultDockerfile,
		defaultWindowsFlag,
		defaultImageNameToBeBuilt,
		defaultImageTagToBeBuilt,
		false,
		defaultPushFlag,
		defaultBuildArgsMap)
}

func createTestCobraCommand() *cobra.Command {
	testCommand := &cobra.Command{
		Use: "test-commmand",
	}
	addInitFlagsForBuildCommand(testCommand)

	testCommand.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)

	return testCommand
}

func expectBuildCommandsWIthBuildArgsToBeEqual(actual string, expected string) {
	expectedBuildArgsMap := extractBuildArguments(expected)
	actualBuildArgsMap := extractBuildArguments(actual)

	Expect(actualBuildArgsMap).To(Equal(expectedBuildArgsMap))
}

func extractBuildArguments(buildCommandWithBuildArgs string) map[string]string {
	// Extract the -BuildArgs value using regular expression
	re := regexp.MustCompile(`-BuildArgs\s+([^ ]+)`)
	matches := re.FindStringSubmatch(buildCommandWithBuildArgs)

	if len(matches) != 2 {
		fmt.Println("No -BuildArgs value found")
		return nil
	}

	buildArgs := matches[1]

	// Extract key-value pairs using regular expression
	re = regexp.MustCompile(`(\w+)=([^,]+)`)
	kvMatches := re.FindAllStringSubmatch(buildArgs, -1)

	buildArgsMap := make(map[string]string)
	// Print the extracted key-value pairs
	for _, match := range kvMatches {
		key := match[1]
		value := match[2]
		buildArgsMap[key] = value
	}

	return buildArgsMap
}
