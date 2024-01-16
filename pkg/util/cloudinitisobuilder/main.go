// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	ve "base/version"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"

	"github.com/kdomanski/iso9660"
)

type config struct {
	version         bool
	sourceDirectory string
	targetFilePath  string
}

const cliName = "cloudinitisobuilder"

func printCLIVersion() {
	version := ve.GetVersion()
	fmt.Printf("%s: %s\n", cliName, version)

	fmt.Printf("  BuildDate: %s\n", version.BuildDate)
	fmt.Printf("  GitCommit: %s\n", version.GitCommit)
	fmt.Printf("  GitTreeState: %s\n", version.GitTreeState)
	if version.GitTag != "" {
		fmt.Printf("  GitTag: %s\n", version.GitTag)
	}
	fmt.Printf("  GoVersion: %s\n", version.GoVersion)
	fmt.Printf("  Compiler: %s\n", version.Compiler)
	fmt.Printf("  Platform: %s\n", version.Platform)
}

func main() {
	c, err := parseArgs(os.Stderr, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stdout, err)
		os.Exit(1)
	}

	if c.version {
		printCLIVersion()
		os.Exit(0)
	}

	err = validateArgs(c)
	if err != nil {
		log.Fatalf("Arguments validation failed: %s", err)
	}

	files, err := ioutil.ReadDir(c.sourceDirectory)
	if err != nil {
		fmt.Fprintln(os.Stdout, err)
		os.Exit(1)
	}

	writer, err := iso9660.NewWriter()
	if err != nil {
		log.Fatalf("failed to create writer: %s", err)
	}
	defer writer.Cleanup()

	for _, fileInfo := range files {
		if fileInfo.IsDir() {
			fmt.Printf("Skipping directory '%s'\n", fileInfo.Name())
			continue
		}
		addFile(writer, c.sourceDirectory+"\\"+fileInfo.Name())
	}

	outputFile, err := os.OpenFile(c.targetFilePath, os.O_WRONLY|os.O_TRUNC|os.O_CREATE, 0644)
	if err != nil {
		log.Fatalf("failed to create file: %s", err)
	}

	err = writer.WriteTo(outputFile, "cidata")
	if err != nil {
		log.Fatalf("failed to write ISO image: %s", err)
	}

	err = outputFile.Close()
	if err != nil {
		log.Fatalf("failed to close output file: %s", err)
	}
}

func parseArgs(w io.Writer, args []string) (config, error) {
	c := config{}
	fs := flag.NewFlagSet("cloudinitisobuilder", flag.ContinueOnError)
	fs.SetOutput(w)
	fs.StringVar(&c.sourceDirectory, "sourceDir", "", "The directory where the cloud init files are located")
	fs.StringVar(&c.targetFilePath, "targetFilePath", "", "The full file target path")
	fs.BoolVar(&c.version, "version", false, "show the current version of the CLI")
	err := fs.Parse(args)
	if err != nil {
		return c, err
	}
	if fs.NArg() != 0 {
		return c, errors.New("positional arguments specified")
	}
	return c, nil
}

func validateArgs(c config) error {
	message := ""
	if c.sourceDirectory == "" {
		message = "The source directory was not specified"
	}
	if c.targetFilePath == "" {
		if message != "" {
			message += "\n"
		}
		message += "The full file target path was not specified"
	}

	if message != "" {
		return errors.New(message)
	}
	return nil
}

func addFile(writer *iso9660.ImageWriter, fileFullPath string) {
	file, err := os.Open(fileFullPath)
	if err != nil {
		log.Fatalf("failed to open file: %s", err)
	}
	defer file.Close()

	fileName := filepath.Base(fileFullPath)
	err = writer.AddFile(file, fileName)
	if err != nil {
		log.Fatalf("failed to add file: %s", err)
	}
}
