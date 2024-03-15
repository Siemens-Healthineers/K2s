// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/json"

	se "github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type Spinner interface {
	Stop() error
}

type LoadedImages struct {
	common.CmdResult
	ContainerImages   []containerImage `json:"containerimages"`
	ContainerRegistry *string          `json:"containerregistry"`
	PushedImages      []pushedImage    `json:"pushedimages"`
}

type PrintImages struct {
	ContainerImages   []containerImage `json:"containerimages"`
	ContainerRegistry *string          `json:"containerregistry"`
	PushedImages      []pushedImage    `json:"pushedimages"`
	Error             *string          `json:"error"`
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

	getImagesFunc := func() (*LoadedImages, error) { return getImages(includeK8sImages) }

	if outputOption == jsonOption {
		return printImagesAsJson(getImagesFunc, terminalPrinter.Println)
	}

	return printImagesToUser(getImagesFunc, terminalPrinter)
}

func printImagesAsJson(getImagesFunc func() (*LoadedImages, error), printlnFunc func(m ...any)) error {
	loadedImages, err := getImagesFunc()
	if err != nil {
		return err
	}

	printImages := PrintImages{
		ContainerImages:   loadedImages.ContainerImages,
		ContainerRegistry: loadedImages.ContainerRegistry,
		PushedImages:      loadedImages.PushedImages,
	}

	var deferredErr error
	if loadedImages.Failure != nil {
		printImages.Error = &loadedImages.Failure.Code
		loadedImages.Failure.SuppressCliOutput = true
		deferredErr = loadedImages.Failure
	}

	bytes, err := json.MarshalIndent(printImages)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", errors.Join(deferredErr, err))
	}

	printlnFunc(string(bytes))

	return deferredErr
}

func printImagesToUser(getImagesFunc func() (*LoadedImages, error), printer terminal.TerminalPrinter) error {
	spinner, err := startSpinner(printer)
	if err != nil {
		return err
	}

	defer func() {
		err = spinner.Stop()
		if err != nil {
			slog.Error("spinner stop", "error", err)
		}
	}()

	images, err := getImagesFunc()
	if err != nil {
		return err
	}

	if images.Failure != nil {
		return images.Failure
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

func getImages(includeK8sImages bool) (*LoadedImages, error) {
	cmd := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\lib\\scripts\\k2s\\image\\Get-Images.ps1")

	var params []string
	if includeK8sImages {
		params = []string{"-IncludeK8sImages"}
	}

	images, err := psexecutor.ExecutePsWithStructuredResult[*LoadedImages](cmd, "StoredImages", psexecutor.ExecOptions{}, params...)
	if err != nil {
		if !errors.Is(err, se.ErrSystemNotInstalled) {
			return nil, err
		}
		images = &LoadedImages{CmdResult: common.CreateSystemNotInstalledCmdResult()}
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
