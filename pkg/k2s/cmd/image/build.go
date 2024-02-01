//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/utils"
)

const (
	defaultInputFolder        = "."
	defaultDockerfile         = ""
	defaultWindowsFlag        = false
	defaultPushFlag           = false
	defaultImageNameToBeBuilt = ""
	defaultImageTagToBeBuilt  = ""
)

var (
	inputFolder = "input-folder"
	dockerfile  = "dockerfile"
	windows     = "windows"
	imageName   = "image-name"
	imageTag    = "image-tag"
	push        = "push"
	buildArgs   = "build-arg"

	inputFolderShortHand = "d"
	imageTagShortHand    = "t"
	imageNameShortHand   = "n"
	pushShortHand        = "p"
	dockerfileShortHand  = "f"

	defaultBuildArgs = make([]string, 0)
)

type buildOptions struct {
	InputFolder string
	Dockerfile  string
	Windows     bool
	ImageName   string
	ImageTag    string
	Output      bool
	Push        bool
	BuildArgs   map[string]string
}

func newBuildOptions(inputFolder string, dockerfile string, windows bool, imageName string, imageTag string, buildOutput bool, pushImage bool, buildArgs map[string]string) *buildOptions {
	return &buildOptions{
		InputFolder: inputFolder,
		Dockerfile:  dockerfile,
		Windows:     windows,
		ImageName:   imageName,
		ImageTag:    imageTag,
		Output:      buildOutput,
		Push:        pushImage,
		BuildArgs:   buildArgs,
	}

}

var buildCommandShortDescription = "Build container images"

var buildCommandLongDescription = `
Build container images. 
Linux images are built inside the KubeMaster VM.
Windows images are built on the host.
For GO projects, the environment variables GOPRIVATE, GOPROXY and GOSUMDB will be used in both cases.
By default, the command tries to build a linux container image.
`

var buildCommandExample = `
  # Build a linux container image using Dockerfile present in the current working directory
  k2s image build

  # Build a linux container image using a directory with the dockerfile
  k2s image build --input-folder C:\myFolder

  # Build a linux container image using a directory with the dockerfile with some build arguments
  k2s image build --input-folder C:\myFolder --build-arg="buildArg1=buildArgValue1" --build-arg="buildArg2=buildArgValue2"

  # Build a windows container image using Dockerfile present in the current working directory
  k2s image build --windows

  # Build a windows container image using a directory with the dockerfile
  k2s image build --input-folder C:\myFolder --windows

  # Build a linux container image using a directory with the dockerfile, image name and image tag
  k2s image build --input-folder C:\myFolder --image-name myimage --image-tag tag1

  # Build a linux container image using a directory with the dockerfile, image name, image tag and push to private registry
  k2s image build --input-folder C:\myFolder --image-name k2s-registry.local/<myimage> --image-tag tag1 --push
`

var buildCmd = &cobra.Command{
	Use:     "build",
	Short:   buildCommandShortDescription,
	Long:    buildCommandLongDescription,
	RunE:    buildImage,
	Example: buildCommandExample,
}

func init() {
	addInitFlagsForBuildCommand(buildCmd)
}

func addInitFlagsForBuildCommand(cmd *cobra.Command) {
	cmd.Flags().StringP(inputFolder, inputFolderShortHand, defaultInputFolder, "Directory with the build context")
	cmd.Flags().StringP(dockerfile, dockerfileShortHand, defaultDockerfile, "Location of the dockerfile. ")
	cmd.Flags().BoolP(windows, "w", defaultWindowsFlag, "Build a Windows container image")
	cmd.Flags().BoolP(push, pushShortHand, defaultPushFlag, "Push to private registry (--image-name must be named accordingly!)")
	cmd.Flags().StringP(imageName, imageNameShortHand, defaultImageNameToBeBuilt, "Name of the image")
	cmd.Flags().StringP(imageTag, imageTagShortHand, defaultImageNameToBeBuilt, "Tag of the image")
	cmd.Flags().StringSlice(buildArgs, defaultBuildArgs, "Build arguments needed to build the container image.")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func buildImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Building container image..")
	buildOptions, err := extractBuildOptions(cmd)
	if err != nil {
		return err
	}

	buildCommand := createBuildCommand(buildOptions)
	klog.V(3).Infof("Build Command : %s", buildCommand)

	duration, err := utils.ExecutePowershellScript(buildCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Build")

	return nil
}

func extractBuildOptions(cmd *cobra.Command) (*buildOptions, error) {
	inputFolder, _ := cmd.Flags().GetString(inputFolder)

	dockerfileFp, _ := cmd.Flags().GetString(dockerfile)

	windows, _ := strconv.ParseBool(cmd.Flags().Lookup(windows).Value.String())
	out, _ := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	push, _ := strconv.ParseBool(cmd.Flags().Lookup(push).Value.String())

	imageName, _ := cmd.Flags().GetString(imageName)

	imageTag, _ := cmd.Flags().GetString(imageTag)

	buildArguments, err := cmd.Flags().GetStringSlice(buildArgs)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag: %s", buildArgs)
	}

	parsedBuildArguments, err := parseBuildArguments(buildArguments)
	if err != nil {
		return nil, fmt.Errorf("unable to parse build arguments: %s", err.Error())
	}

	printBuildArgs(parsedBuildArguments)

	buildOptions := newBuildOptions(
		inputFolder,
		dockerfileFp,
		windows,
		imageName,
		imageTag,
		out,
		push,
		parsedBuildArguments)
	return buildOptions, nil
}

func createBuildCommand(buildOptions *buildOptions) string {
	buildCommandBase := getBuildCommandBase()

	buildCommand := buildCommandBase + " " +
		"-InputFolder " + buildOptions.InputFolder

	if buildOptions.Dockerfile != "" {
		buildCommand = buildCommand + " -Dockerfile " + buildOptions.Dockerfile
	}

	if buildOptions.Windows {
		buildCommand = buildCommand + " " + "-Windows"
	}

	if buildOptions.ImageName != "" {
		buildCommand = buildCommand + " " + "-ImageName " + buildOptions.ImageName
	}

	if buildOptions.ImageTag != "" {
		buildCommand = buildCommand + " " + "-ImageTag " + buildOptions.ImageTag
	}

	if buildOptions.Output {
		buildCommand += " -ShowLogs"
	}

	if buildOptions.Push {
		buildCommand += " -Push"
	}

	if len(buildOptions.BuildArgs) > 0 {
		buildArgList := make([]string, 0)
		for buildArgName, buildArgValue := range buildOptions.BuildArgs {
			buildArgList = append(buildArgList, fmt.Sprintf("%s=%s", buildArgName, buildArgValue))
		}
		buildCommand += " " + "-BuildArgs " + strings.Join(buildArgList, ",")
	}

	return buildCommand
}

func parseBuildArguments(arguments []string) (map[string]string, error) {
	buildArgsMap := make(map[string]string, len(arguments))

	for _, argument := range arguments {
		parts := strings.Split(argument, "=")
		if len(parts) != 2 {
			return nil, errors.New(
				"the build argument was not specified in correct format. The format of the build argument should be of format argumentName=argumentValue")
		}
		buildArgsMap[parts[0]] = parts[1]
	}
	return buildArgsMap, nil
}

func printBuildArgs(buildArgs map[string]string) {
	klog.V(4).Info("Printing all build arguments....")
	for argName, argValue := range buildArgs {
		klog.V(4).Info(fmt.Sprintf("%s=%s\n", argName, argValue))
	}
}

func getBuildCommandBase() string {
	commonDir := utils.GetInstallationDirectory() + "\\smallsetup\\common"
	buildCommandBase := utils.FormatScriptFilePath(commonDir + "\\" + "BuildImage.ps1")

	return buildCommandBase
}
