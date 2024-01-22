// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"errors"
	"fmt"
	"io/fs"
	"k2s/addons/print"
	"k2s/utils"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/samber/lo"
	"github.com/santhosh-tekuri/jsonschema/v5"
	"gopkg.in/yaml.v3"
	"k8s.io/klog/v2"
)

type EnabledAddons struct {
	Addons []string `json:"addons"`
}

type Addons []Addon

type Addon struct {
	ApiVersion string        `yaml:"apiVersion"`
	Kind       string        `yaml:"kind"`
	Directory  string        // infered from manifest location
	Metadata   AddonMetadata `yaml:"metadata"`
	Spec       AddonSpec     `yaml:"spec"`
}

type AddonMetadata struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
}

type AddonSpec struct {
	Commands *map[string]AddonCmd `yaml:"commands"`
}

type AddonCmd struct {
	Cli    *CliConfig   `yaml:"cli"`
	Script ScriptConfig `yaml:"script"`
}

type CliConfig struct {
	Flags    []CliFlag   `yaml:"flags"`
	Examples CliExamples `yaml:"examples"`
}

type CliExamples []CliExample

type ScriptConfig struct {
	SubPath           string             `yaml:"subPath"`
	ParameterMappings []ParameterMapping `yaml:"parameterMappings"`
}

type CliFlag struct {
	Name        string       `yaml:"name"`
	Shorthand   *string      `yaml:"shorthand"`
	Default     any          `yaml:"default"`
	Description *string      `yaml:"description"`
	Constraints *Constraints `yaml:"constraints"`
}

type Constraints struct {
	Kind          ConstraintsType `yaml:"kind"`
	ValidationSet *ValidationSet  `yaml:"validationSet"`
	NumberRange   *Range          `yaml:"range"`
}

type ConstraintsType string

type ParameterMapping struct {
	CliFlagName         string `yaml:"cliFlagName"`
	ScriptParameterName string `yaml:"scriptParameterName"`
}

type CliExample struct {
	Cmd     string  `yaml:"cmd"`
	Comment *string `yaml:"comment"`
}

type ValidationSet []string

type Range struct {
	Min float64 `yaml:"min"`
	Max float64 `yaml:"max"`
}

type loadParams struct {
	directory             string
	manifestFileName      string
	walkDir               func(root string, fn fs.WalkDirFunc) error
	readFile              func(p string) ([]byte, error)
	unmarshal             func(data []byte, v any) error
	validateAgainstSchema func(v any) error
	validateContent       func(addon Addon) error
}

const (
	ValidationSetConstraintsType ConstraintsType = "validation-set"
	RangeConstraintsType         ConstraintsType = "range"

	addonsDirName          = "addons"
	manifestFileName       = "addon.manifest.yaml"
	manifestSchemaFileName = "addon.manifest.schema.json"
)

var (
	lock                      sync.Mutex
	allAddons                 Addons
	supportedManifestVersions = []string{"v1"}
)

func AllAddons() Addons {
	lock.Lock()
	defer lock.Unlock()

	if allAddons != nil {
		return allAddons
	}

	var err error
	allAddons, err = loadAddons()
	if err != nil {
		klog.Fatal(err)
	}

	return allAddons
}

func LoadEnabledAddons() (*EnabledAddons, error) {
	scriptPath := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + fmt.Sprintf("\\%s\\Get-EnabledAddons.ps1", addonsDirName))

	enabledAddons, err := utils.LoadStructure[*EnabledAddons](scriptPath, "EnabledAddons", utils.ExecOptions{IgnoreNotInstalledErr: true})
	if err != nil {
		return nil, fmt.Errorf("could not load enabled addons: %s", err)
	}

	return enabledAddons, nil
}

func (addons Addons) ToPrintInfo() []print.AddonPrintInfo {
	return lo.Map(addons, func(addon Addon, _ int) print.AddonPrintInfo {
		return print.AddonPrintInfo{
			Name:        addon.Metadata.Name,
			Description: addon.Metadata.Description}
	})
}

func (flag CliFlag) FullDescription() (string, error) {
	description := ""
	if flag.Description != nil {
		description = *flag.Description
	}

	constraints, err := flag.Constraints.String()
	if err != nil {
		return "", err
	}

	if description != "" && constraints != "" {
		description += " "
	}

	return description + constraints, nil
}

func (examples CliExamples) String() string {
	formattedExamples := lo.Map(examples, func(e CliExample, _ int) string {
		return e.String()
	})

	return strings.Join(formattedExamples, "\n")
}

func (example CliExample) String() string {
	comment := ""
	if example.Comment != nil {
		comment = fmt.Sprintf("  // %s\n", *example.Comment)
	}

	return comment + fmt.Sprintf("  %s\n", example.Cmd)
}

func (c *Constraints) String() (string, error) {
	if c == nil {
		return "", nil
	}

	switch c.Kind {
	case ValidationSetConstraintsType:
		return c.ValidationSet.String()
	case RangeConstraintsType:
		return c.NumberRange.String()
	default:
		return "", fmt.Errorf("unknown constraint type '%s'", c.Kind)
	}
}

func (v *ValidationSet) String() (string, error) {
	if v == nil {
		return "", errors.New("validation set must not be nil")
	}

	return fmt.Sprintf("[%s]", strings.Join(*v, "|")), nil
}

func (r *Range) String() (string, error) {
	if r == nil {
		return "", errors.New("range must not be nil")
	}

	return fmt.Sprintf("[%v,%v]", r.Min, r.Max), nil
}

func (c *Constraints) Validate(value any) error {
	if c == nil {
		return nil
	}

	switch c.Kind {
	case ValidationSetConstraintsType:
		return c.ValidationSet.Validate(value)
	case RangeConstraintsType:
		return c.NumberRange.Validate(value)
	default:
		return fmt.Errorf("unknown constraint type '%s'", c.Kind)
	}
}

func (v *ValidationSet) Validate(value any) error {
	if v == nil {
		return errors.New("validation set must not be nil")
	}

	stringValue := fmt.Sprint(value)

	if !lo.Contains(*v, stringValue) {
		formattedSet, err := v.String()
		if err != nil {
			return err
		}

		return fmt.Errorf("invalid value '%s', valid values are %s", stringValue, formattedSet)
	}

	return nil
}

func (r *Range) Validate(value any) error {
	if r == nil {
		return errors.New("range must not be nil")
	}

	number, err := strconv.ParseFloat(fmt.Sprint(value), 64)
	if err != nil {
		return fmt.Errorf("'%v' is not a number", value)
	}

	if number < r.Min || number > r.Max {
		formattedRange, err := r.String()
		if err != nil {
			return err
		}
		return fmt.Errorf("'%v' is out of range %s", value, formattedRange)
	}

	return nil
}

func loadAddons() (Addons, error) {
	addonsDir := filepath.Join(utils.GetInstallationDirectory(), addonsDirName)
	schemaPath := filepath.Join(addonsDir, manifestSchemaFileName)

	schema, err := jsonschema.Compile(schemaPath)
	if err != nil {
		return nil, err
	}

	params := loadParams{
		directory:             addonsDir,
		manifestFileName:      manifestFileName,
		walkDir:               filepath.WalkDir,
		readFile:              os.ReadFile,
		unmarshal:             yaml.Unmarshal,
		validateAgainstSchema: schema.Validate,
		validateContent:       validateManifest}

	return loadAndValidate(params)
}

func validateManifest(addon Addon) error {
	if !slices.Contains(supportedManifestVersions, addon.ApiVersion) {
		return fmt.Errorf("apiVersion '%s' invalid; supported versions are (%s)", addon.ApiVersion, strings.Join(supportedManifestVersions, "|"))
	}

	return nil
}

func loadAndValidate(params loadParams) (addons []Addon, err error) {
	err = params.walkDir(params.directory, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		if entry.IsDir() || entry.Name() != params.manifestFileName {
			return nil
		}

		data, err := params.readFile(path)
		if err != nil {
			return err
		}

		var genericContent any
		if err = params.unmarshal(data, &genericContent); err != nil {
			return err
		}

		if err = params.validateAgainstSchema(genericContent); err != nil {
			return fmt.Errorf("validation failed for manifest '%s':\n%v", path, err)
		}

		var addon Addon
		if err = params.unmarshal(data, &addon); err != nil {
			return err
		}

		if err = params.validateContent(addon); err != nil {
			return err
		}

		addon.Directory = filepath.Dir(path)

		addons = append(addons, addon)
		return nil
	})

	return
}
