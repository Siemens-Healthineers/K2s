// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"flag"
	"io/fs"
	"log/slog"
	"os"

	"gopkg.in/yaml.v3"
)

func main() {
	inputFile := flag.String("input", "", "The YAML input file path")
	outputFile := flag.String("output", "", "The JSON output file path")
	indent := flag.Bool("indent", false, "JSON gets indented for readability if set to TRUE")
	logLevel := flag.Int("loglevel", int(slog.LevelInfo), "loglevel (Info=0, Debug=-4, Warn=4, Error=8; Default: 0)")

	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.Level(*logLevel)}))

	slog.SetDefault(logger)

	slog.Info("yaml2json started", "input", *inputFile, "output", *outputFile, "indent", *indent, "loglevel", *logLevel)

	exitOnInvalidFlags(*inputFile, *outputFile)

	yaml2json(*inputFile, *outputFile, *indent)

	slog.Info("yaml2json finished")
}

func yaml2json(inputFile string, outputFile string, indent bool) {
	rawData, err := os.ReadFile(inputFile)
	if err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}

	yamlData := make(map[string]interface{})

	err = yaml.Unmarshal(rawData, &yamlData)
	if err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}

	var jsonData []byte
	if indent {
		jsonData, err = json.MarshalIndent(yamlData, "", "	")
	} else {
		jsonData, err = json.Marshal(yamlData)
	}

	if err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}

	err = os.WriteFile(outputFile, jsonData, fs.ModePerm)
	if err != nil {
		slog.Error(err.Error())
		os.Exit(1)
	}
}

func exitOnInvalidFlags(inputFile string, outputFile string) {
	if inputFile == "" {
		slog.Error("Input file path must not be empty")
		os.Exit(1)
	}

	if outputFile == "" {
		slog.Error("Output file path must not be empty")
		os.Exit(1)
	}

	if _, err := os.Stat(inputFile); os.IsNotExist(err) {
		slog.Error("Input file does not exist")
		os.Exit(1)
	}
}
