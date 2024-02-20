//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/utils"
	"k2s/utils/psexecutor"
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

const (
	defaultInputFolder        = "."
	defaultDockerfile         = ""
	defaultWindowsFlag        = false
	defaultPushFlag           = false
	defaultImageNameToBeBuilt = ""
	defaultImageTagToBeBuilt  = ""

	inputFolderFlagName = "input-folder"
	dockerfileFlagName  = "dockerfile"
	windowsFlagName     = "windows"
	imageNameFlagName   = "image-name"
	imageTagFlagName    = "image-tag"
	pushFlagName        = "push"
	buildArgsFlagName   = "build-arg"

	inputFolderShortHand = "d"
	imageTagShortHand    = "t"
	imageNameShortHand   = "n"
	pushShortHand        = "p"
	dockerfileShortHand  = "f"
)

var (
	defaultBuildArgs = make([]string, 0)

	buildCommandShortDescription = "Build container images"

	buildCommandLongDescription = `
Build container images. 
Linux images are built inside the KubeMaster VM.
Windows images are built on the host.
For GO projects, the environment variables GOPRIVATE, GOPROXY and GOSUMDB will be used in both cases.
By default, the command tries to build a linux container image.
`

	buildCommandExample = `
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

	buildCmd = &cobra.Command{
		Use:     "build",
		Short:   buildCommandShortDescription,
		Long:    buildCommandLongDescription,
		RunE:    buildImage,
		Example: buildCommandExample,
	}
)

func init() {
	addInitFlagsForBuildCommand(buildCmd)
}

func addInitFlagsForBuildCommand(cmd *cobra.Command) {
	cmd.Flags().StringP(inputFolderFlagName, inputFolderShortHand, defaultInputFolder, "Directory with the build context")
	cmd.Flags().StringP(dockerfileFlagName, dockerfileShortHand, defaultDockerfile, "Location of the dockerfile. ")
	cmd.Flags().BoolP(windowsFlagName, "w", defaultWindowsFlag, "Build a Windows container image")
	cmd.Flags().BoolP(pushFlagName, pushShortHand, defaultPushFlag, "Push to private registry (--image-name must be named accordingly!)")
	cmd.Flags().StringP(imageNameFlagName, imageNameShortHand, defaultImageNameToBeBuilt, "Name of the image")
	cmd.Flags().StringP(imageTagFlagName, imageTagShortHand, defaultImageNameToBeBuilt, "Tag of the image")
	cmd.Flags().StringSlice(buildArgsFlagName, defaultBuildArgs, "Build arguments needed to build the container image.")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func buildImage(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Building container image..")
	buildOptions, err := extractBuildOptions(cmd)
	if err != nil {
		return err
	}

	psCmd, params := buildPsCmd(buildOptions)
	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image build")

	return nil
}

func extractBuildOptions(cmd *cobra.Command) (*buildOptions, error) {
	inputFolder, err := cmd.Flags().GetString(inputFolderFlagName)
	if err != nil {
		return nil, err
	}

	dockerfile, err := cmd.Flags().GetString(dockerfileFlagName)
	if err != nil {
		return nil, err
	}

	windows, err := strconv.ParseBool(cmd.Flags().Lookup(windowsFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	output, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	push, err := strconv.ParseBool(cmd.Flags().Lookup(pushFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return nil, err
	}

	imageTag, err := cmd.Flags().GetString(imageTagFlagName)
	if err != nil {
		return nil, err
	}

	buildArguments, err := cmd.Flags().GetStringSlice(buildArgsFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", buildArgsFlagName, err)
	}

	parsedBuildArguments, err := parseBuildArguments(buildArguments)
	if err != nil {
		return nil, fmt.Errorf("unable to parse build arguments: %w", err)
	}

	if klog.V(4).Enabled() {
		printBuildArgs(parsedBuildArguments, 4)
	}

	return &buildOptions{
		InputFolder: inputFolder,
		Dockerfile:  dockerfile,
		Windows:     windows,
		ImageName:   imageName,
		ImageTag:    imageTag,
		Output:      output,
		Push:        push,
		BuildArgs:   parsedBuildArguments,
	}, nil
}

func parseBuildArguments(arguments []string) (map[string]string, error) {
	buildArgsMap := make(map[string]string, len(arguments))

	for _, argument := range arguments {
		parts := strings.Split(argument, "=")
		if len(parts) != 2 {
			errMsg := "the build argument was not specified in correct format. The format of the build argument should be of format argumentName=argumentValue"
			return nil, errors.New(errMsg)
		}
		buildArgsMap[parts[0]] = parts[1]
	}
	return buildArgsMap, nil
}

func buildPsCmd(buildOptions *buildOptions) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\common\\BuildImage.ps1")
	params = append(params, " -InputFolder "+buildOptions.InputFolder)

	if buildOptions.Dockerfile != "" {
		params = append(params, " -Dockerfile "+buildOptions.Dockerfile)
	}

	if buildOptions.Windows {
		params = append(params, " -Windows")
	}

	if buildOptions.ImageName != "" {
		params = append(params, " -ImageName "+buildOptions.ImageName)
	}

	if buildOptions.ImageTag != "" {
		params = append(params, " -ImageTag "+buildOptions.ImageTag)
	}

	if buildOptions.Output {
		params = append(params, " -ShowLogs")
	}

	if buildOptions.Push {
		params = append(params, " -Push")
	}

	if len(buildOptions.BuildArgs) > 0 {
		buildArgList := make([]string, 0)
		for buildArgName, buildArgValue := range buildOptions.BuildArgs {
			buildArgList = append(buildArgList, fmt.Sprintf("%s=%s", buildArgName, buildArgValue))
		}
		params = append(params, " -BuildArgs "+strings.Join(buildArgList, ","))
	}

	return
}

func printBuildArgs(buildArgs map[string]string, level klog.Level) {
	klog.V(level).Info("Printing all build arguments....")
	for argName, argValue := range buildArgs {
		klog.V(level).Info(fmt.Sprintf("%s=%s\n", argName, argValue))
	}
}
