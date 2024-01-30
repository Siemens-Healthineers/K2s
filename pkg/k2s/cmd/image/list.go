// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	"k2s/providers/marshalling"
	"k2s/providers/terminal"
	"k2s/setupinfo"
	"k2s/utils"
)

const (
	includeK8sImages = "include-k8s-images"
	outputFlagName   = "output"
	jsonOption       = "json"
)

var (
	containerImagesTableHeaders = []string{"ImageId", "Repository", "Tag", "Node", "Size"}
	pushedImagesTableHeaders    = []string{"Name", "Tag"}
)

var listCmd = &cobra.Command{
	Use:     "ls",
	Short:   "List images",
	RunE:    listImages,
	Example: imagelistCommandExample,
}

const imagelistCommandExample = `
  # List all the container images from the K2s cluster
  k2s image ls

  # List all the container images including kubernetes container images from the K2s cluster
  k2s image ls -A

  # List all the container images in JSON output format
  k2s image ls -o json
`

type containerImages struct {
	ImageId    string `json:"imageid"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Node       string `json:"node"`
	Size       string `json:"size"`
}

type pushedImages struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

type StoredImages struct {
	ContainerImages   []containerImages     `json:"containerimages"`
	ContainerRegistry *string               `json:"containerregistry"`
	PushedImages      []pushedImages        `json:"pushedimages"`
	Error             *setupinfo.SetupError `json:"error"`
}

func init() {
	listCmd.Flags().BoolP(includeK8sImages, "A", false, "Include kubernetes container images if specified")
	listCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func startSpinner(terminalPrinter terminal.TerminalPrinter) error {
	_, err := terminalPrinter.StartSpinner("Gathering images stored in the cluster")
	if err != nil {
		return err
	}
	return nil
}

func getStoredImages(includeK8sImages bool) (*StoredImages, error) {
	cmd := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\lib\\scripts\\k2s\\image\\Get-Images.ps1")

	var params []string
	if includeK8sImages {
		params = []string{"-IncludeK8sImages"}
	}

	images, err := utils.ExecutePsWithStructuredResult[*StoredImages](cmd, "StoredImages", utils.ExecOptions{}, params...)
	if err == setupinfo.ErrNotInstalled {
		errMsg := setupinfo.ErrNotInstalledMsg
		return &StoredImages{Error: &errMsg}, nil
	}

	return images, err
}

func printAvailableImages(terminalPrinter terminal.TerminalPrinter, containerImages []containerImages) {
	terminalPrinter.Println()
	terminalPrinter.PrintHeader("Available Images")

	containerImagesTable := [][]string{containerImagesTableHeaders}
	for _, containerImage := range containerImages {
		row := []string{containerImage.ImageId, containerImage.Repository, containerImage.Tag, containerImage.Node, containerImage.Size}
		containerImagesTable = append(containerImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(containerImagesTable)
}

func printAvailableImagesInContainerRegistry(terminalPrinter terminal.TerminalPrinter, containerRegistry string, pushedImages []pushedImages) {
	terminalPrinter.Println()
	terminalPrinter.PrintHeader(fmt.Sprintf("Images available in registry: %s", containerRegistry))

	pushedImagesTable := [][]string{pushedImagesTableHeaders}
	for _, pushedImage := range pushedImages {
		row := []string{pushedImage.Name, pushedImage.Tag}
		pushedImagesTable = append(pushedImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(pushedImagesTable)
}

func printImagesAsJson(storedImages *StoredImages, tp terminal.TerminalPrinter) {
	jsonMarshaller := marshalling.NewJsonMarshaller()
	bytes, err := jsonMarshaller.MarshalIndent(storedImages)
	if err != nil {
		klog.Errorf("error happened during list images. Error: %s", err)
	}

	tp.Println(string(bytes))
}

func printImagesToUser(images *StoredImages, printer terminal.TerminalPrinter) error {
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

func listImages(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag 'o'", outputOption)
	}

	includeK8sImagesFlag, _ := strconv.ParseBool(cmd.Flags().Lookup(includeK8sImages).Value.String())

	terminalPrinter := terminal.NewTerminalPrinter()

	if outputOption != jsonOption {
		if err := startSpinner(terminalPrinter); err != nil {
			return err
		}
	}

	images, err := getStoredImages(includeK8sImagesFlag)
	if err != nil {
		return err
	}

	if images.Error != nil {
		switch *images.Error {
		case setupinfo.ErrNotInstalledMsg:
			if outputOption == jsonOption {
				break
			}
			common.PrintNotInstalledMessage()
			return nil
		case setupinfo.ErrNotRunningMsg:
			if outputOption == jsonOption {
				break
			}
			common.PrintNotRunningMessage()
			return nil
		default:
			return fmt.Errorf("unknown error while listing images: %s", *images.Error)
		}
	}

	if outputOption == jsonOption {
		printImagesAsJson(images, terminalPrinter)
	} else {
		printImagesToUser(images, terminalPrinter)
	}

	return nil
}
