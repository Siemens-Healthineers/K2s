// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/providers/marshalling"
	"k2s/providers/terminal"
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
  # List all the container images from the k2s cluster
  k2s image ls

  # List all the container images including kubernetes container images from the k2s cluster
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
	ContainerImages   []containerImages `json:"containerimages"`
	ContainerRegistry string            `json:"containerregistry"`
	PushedImages      []pushedImages    `json:"pushedimages"`
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

func getStoredImages(listImagesCommand string) (*StoredImages, error) {
	powerShellExecutor := utils.NewPsExecutor()
	unmarshaller := marshalling.NewJsonUnmarshaller()

	messages, err := powerShellExecutor.ExecuteWithStructuredResultData(listImagesCommand)
	if err != nil {
		return nil, err
	}

	if len(messages) != 1 {
		errorMessage := fmt.Sprintf("unexpected number of messages. Expected 1, but got %d", len(messages))
		return nil, errors.New(errorMessage)
	}

	message := messages[0]

	if message.Type() != "StoredImages" {
		errorMessage := fmt.Sprintf("unexpected message type. Expected 'Addons', but got '%s'", message.Type())
		return nil, errors.New(errorMessage)
	}

	var storedImages StoredImages
	err = unmarshaller.Unmarshal(message.Data(), &storedImages)
	if err != nil {
		return nil, err
	}

	return &storedImages, nil
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

func printStatusAsJson(storedImages *StoredImages, tp terminal.TerminalPrinter) {
	jsonMarshaller := marshalling.NewJsonMarshaller()
	bytes, err := jsonMarshaller.MarshalIndent(storedImages)
	if err != nil {
		klog.Errorf("Error happened during list images. Error: %s", err)
	}

	tp.Println(string(bytes))
}

func printStatusToUser(storedImages *StoredImages, tp terminal.TerminalPrinter) {
	if len(storedImages.ContainerImages) > 0 {
		printAvailableImages(tp, storedImages.ContainerImages)
	} else {
		tp.Println("No container images were found stored in the cluster")
	}

	if storedImages.ContainerRegistry != "" {
		if len(storedImages.PushedImages) == 0 {
			tp.Println("No pushed images in registry " + storedImages.ContainerRegistry)
		} else {
			printAvailableImagesInContainerRegistry(tp, storedImages.ContainerRegistry, storedImages.PushedImages)
		}
	}
}

func listImages(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("Parameter '%s' not supported for flag 'o'", outputOption)
	}

	includeK8sImagesFlag, _ := strconv.ParseBool(cmd.Flags().Lookup(includeK8sImages).Value.String())
	listImagesCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ListImages.ps1")
	if includeK8sImagesFlag {
		listImagesCommand += " -IncludeK8sImages"
	}
	listImagesCommand += " -EncodeStructuredOutput"

	klog.V(3).Infof("List images command: %s", listImagesCommand)

	terminalPrinter := terminal.NewTerminalPrinter()

	if outputOption != jsonOption {
		if err := startSpinner(terminalPrinter); err != nil {
			return err
		}
	}

	storedImages, err := getStoredImages(listImagesCommand)
	if err != nil {
		return err
	}

	if outputOption == jsonOption {
		printStatusAsJson(storedImages, terminalPrinter)
	} else {
		printStatusToUser(storedImages, terminalPrinter)
	}

	return nil
}
