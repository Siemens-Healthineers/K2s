// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/samber/lo"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

type Addon struct {
	Name            string           `json:"name"`
	Description     string           `json:"description"`
	Implementations []Implementation `json:"implementations"`
}

type Implementation struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

type AddonsStatus struct {
	EnabledAddons  []Addon `json:"enabledAddons"`
	DisabledAddons []Addon `json:"disabledAddons"`
}

type AddonsAdditionalInfo struct {
}

const manifestFileName = "addon.manifest.yaml"

func (addonsStatus *AddonsStatus) IsAddonEnabled(addonName string, implementationName string) bool {
	isAddonEnabled := lo.SomeBy(addonsStatus.EnabledAddons, func(addon Addon) bool {
		return addon.Name == addonName
	})

	if isAddonEnabled && implementationName != "" {
		addon := lo.Filter(addonsStatus.EnabledAddons, func(enabledAddon Addon, index int) bool {
			return enabledAddon.Name == addonName
		})[0]

		return lo.SomeBy(addon.Implementations, func(implementation Implementation) bool {
			return implementation.Name == implementationName
		})
	}

	return isAddonEnabled
}

func (addonsStatus *AddonsStatus) GetEnabledAddons() []string {
	return lo.Map(addonsStatus.EnabledAddons, func(addon Addon, _ int) string {
		return addon.Name
	})
}

func NewAddonsAdditionalInfo() *AddonsAdditionalInfo {
	return &AddonsAdditionalInfo{}
}

func (info *AddonsAdditionalInfo) AllAddons() addons.Addons {
	rootDir, err := sos.RootDir()
	Expect(err).To(BeNil())

	allAddons, err := addons.LoadAddons(rootDir)
	Expect(err).To(BeNil())

	return allAddons
}

func (info *AddonsAdditionalInfo) GetImagesForAddonImplementation(implementation addons.Implementation) ([]string, error) {
	yamlFiles, err := sos.GetFilesMatch(implementation.Directory, "*.yaml")
	if err != nil {
		return nil, err
	}

	yamlFiles = lo.Filter(yamlFiles, func(path string, index int) bool {
		if filepath.Base(path) == manifestFileName {
			return false
		}

		content, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}

		yamlContent := string(content)

		return !strings.Contains(yamlContent, "## exclude-from-export")
	})

	images := lo.FlatMap(yamlFiles, func(path string, index int) []string {
		content, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}

		yamlContent := string(content)

		r, _ := regexp.Compile(".*image: .+")
		findings := r.FindAllString(yamlContent, -1)

		var trimedFindings []string
		for _, f := range findings {
			trimed := strings.TrimSpace(f)
			splitted := strings.Split(strings.Split(trimed, "image: ")[1], "#")[0]
			trimed = strings.Trim(splitted, "\"")
			trimed = strings.TrimSpace(trimed)
			GinkgoWriter.Println("After trim and split: ", trimed)
			trimedFindings = append(trimedFindings, trimed)
		}

		return trimedFindings
	})

	if len(implementation.OfflineUsage.LinuxResources.AdditionalImages) > 0 {
		images = append(images, implementation.OfflineUsage.LinuxResources.AdditionalImages...)
	}

	return lo.Union(images), nil
}

func Foreach(addons addons.Addons, iteratee func(addonName, implementationName, cmdName string)) {
	for _, addon := range addons {
		for _, implementation := range addon.Spec.Implementations {
			implementationName := ""
			if addon.Metadata.Name != implementation.Name {
				implementationName = implementation.Name
			}

			GinkgoWriter.Println("Looping at", implementation.AddonsCmdName)

			iteratee(addon.Metadata.Name, implementationName, implementation.AddonsCmdName)
		}
	}
}
