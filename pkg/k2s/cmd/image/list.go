// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	"k2s/cmd/params"
	"k2s/providers/marshalling"
	"k2s/providers/terminal"
	"k2s/setupinfo"
	"k2s/status"
	"k2s/utils"
)

type Spinner interface {
	Stop() error
}

type Images struct {
	common.CmdResult
	ContainerImages   []containerImage `json:"containerimages"`
	ContainerRegistry *string          `json:"containerregistry"`
	PushedImages      []pushedImage    `json:"pushedimages"`
}

type containerImage struct {
	ImageId    string `json:"imageid"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Node       string `json:"node"`
	Size       string `json:"size"`
}

type pushedImage struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

const (
	includeK8sImages = "include-k8s-images"
	outputFlagName   = "output"
	jsonOption       = "json"

	cmdExample = `
  # List all the container images from the K2s cluster
  k2s image ls

  # List all the container images including kubernetes container images from the K2s cluster
  k2s image ls -A

  # List all the container images in JSON output format
  k2s image ls -o json
`
)

var (
	containerImagesTableHeaders = []string{"ImageId", "Repository", "Tag", "Node", "Size"}
	pushedImagesTableHeaders    = []string{"Name", "Tag"}

	listCmd = &cobra.Command{
		Use:     "ls",
		Short:   "List images",
		RunE:    listImages,
		Example: cmdExample,
	}
)

func init() {
	listCmd.Flags().BoolP(includeK8sImages, "A", false, "Include kubernetes container images if specified")
	listCmd.Flags().StringP(params.OutputFlagName, params.OutputFlagShorthand, "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func listImages(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag '%s'", outputOption, params.OutputFlagName)
	}

	includeK8sImages, err := strconv.ParseBool(cmd.Flags().Lookup(includeK8sImages).Value.String())
	if err != nil {
		return err
	}

	terminalPrinter := terminal.NewTerminalPrinter()

	getImagesFunc := func() (*Images, error) { return getImages(includeK8sImages) }

	if outputOption == jsonOption {
		return printImagesAsJson(getImagesFunc, terminalPrinter.Println)
	}

	return printImagesToUser(getImagesFunc, terminalPrinter)
}

func printImagesAsJson(getImagesFunc func() (*Images, error), printlnFunc func(m ...any)) error {
	images, err := getImagesFunc()
	if err != nil {
		if errors.Is(err, status.ErrNotRunning) {
			errMsg := common.CmdError(status.ErrNotRunningMsg)
			images = &Images{CmdResult: common.CmdResult{Error: &errMsg}}
		} else if errors.Is(err, setupinfo.ErrNotInstalled) {
			errMsg := common.CmdError(setupinfo.ErrNotInstalledMsg)
			images = &Images{CmdResult: common.CmdResult{Error: &errMsg}}
		} else {
			return err
		}
	}

	jsonMarshaller := marshalling.NewJsonMarshaller()
	bytes, err := jsonMarshaller.MarshalIndent(images)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", err)
	}

	printlnFunc(string(bytes))

	return nil
}

func printImagesToUser(getImagesFunc func() (*Images, error), printer terminal.TerminalPrinter) error {
	spinner, err := startSpinner(printer)
	if err != nil {
		return err
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			klog.Error(err)
		}
	}()

	images, err := getImagesFunc()
	if err != nil {
		return err
	}

	if len(images.ContainerImages) > 0 {
		printAvailableImages(printer, images.ContainerImages)
	} else {
		printer.PrintInfoln("No container images were found in the cluster")
	}

	if images.ContainerRegistry != nil && *images.ContainerRegistry != "" {
		if len(images.PushedImages) == 0 {
			printer.PrintInfoln("No pushed images in registry " + *images.ContainerRegistry)
		} else {
			printAvailableImagesInContainerRegistry(printer, *images.ContainerRegistry, images.PushedImages)
		}
	}

	return nil
}

func startSpinner(terminalPrinter terminal.TerminalPrinter) (Spinner, error) {
	startResult, err := terminalPrinter.StartSpinner("Gathering images stored in the cluster...")
	if err != nil {
		return nil, err
	}

	spinner, ok := startResult.(Spinner)
	if !ok {
		return nil, errors.New("could not start operation")
	}

	return spinner, nil
}

func getImages(includeK8sImages bool) (*Images, error) {
	cmd := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\lib\\scripts\\k2s\\image\\Get-Images.ps1")

	var params []string
	if includeK8sImages {
		params = []string{"-IncludeK8sImages"}
	}

	images, err := utils.ExecutePsWithStructuredResult[*Images](cmd, "StoredImages", utils.ExecOptions{}, params...)
	if err != nil {
		return nil, err
	}

	if images.Error != nil {
		return nil, images.Error.ToError()
	}

	return images, nil
}

func printAvailableImages(terminalPrinter terminal.TerminalPrinter, containerImages []containerImage) {
	terminalPrinter.Println()
	terminalPrinter.PrintHeader("Available Images")

	containerImagesTable := [][]string{containerImagesTableHeaders}
	for _, containerImage := range containerImages {
		row := []string{containerImage.ImageId, containerImage.Repository, containerImage.Tag, containerImage.Node, containerImage.Size}
		containerImagesTable = append(containerImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(containerImagesTable)
}

func printAvailableImagesInContainerRegistry(terminalPrinter terminal.TerminalPrinter, containerRegistry string, pushedImages []pushedImage) {
	terminalPrinter.Println()
	terminalPrinter.PrintHeader(fmt.Sprintf("Images available in registry: %s", containerRegistry))

	pushedImagesTable := [][]string{pushedImagesTableHeaders}
	for _, pushedImage := range pushedImages {
		row := []string{pushedImage.Name, pushedImage.Tag}
		pushedImagesTable = append(pushedImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(pushedImagesTable)
}
