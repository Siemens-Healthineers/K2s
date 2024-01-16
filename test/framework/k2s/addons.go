// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package k2s

import (
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	sos "k2sTest/framework/os"
	"strings"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/samber/lo"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
)

type Addon struct {
	Metadata  AddonMetadata `yaml:"metadata"`
	Spec      AddonSpec     `yaml:"spec"`
	Directory AddonDirectory
}

type AddonMetadata struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
}

type AddonSpec struct {
	OfflineUsage OfflineUsage `yaml:"offline_usage"`
}

type AddonDirectory struct {
	Name string
	Path string
}

type OfflineUsage struct {
	LinuxResources   LinuxResources   `yaml:"linux"`
	WindowsResources WindowsResources `yaml:"windows"`
}

type LinuxResources struct {
	DebPackages      []string       `yaml:"deb"`
	CurlPackages     []CurlPackages `yaml:"curl"`
	AdditionalImages []string       `yaml:"additionalImages"`
}

type WindowsResources struct {
	CurlPackages []CurlPackages `yaml:"curl"`
}

type CurlPackages struct {
	Url         string `yaml:"url"`
	Destination string `yaml:"destination"`
}

const manifestFileName = "addon.manifest.yaml"

func (setup *SetupInfo) AllAddons() []Addon {
	addonsDir := filepath.Join(setup.RootDir, "addons")
	addons := []Addon{}

	GinkgoWriter.Println("Scanning for addons in <", addonsDir, ">..")

	Expect(filepath.WalkDir(addonsDir, func(path string, entry fs.DirEntry, _ error) error {
		if entry.IsDir() {
			return nil
		}

		if entry.Name() != manifestFileName {
			return nil
		}

		GinkgoWriter.Println("Reading file <", path, ">..")

		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}

		var addon Addon

		GinkgoWriter.Println("Parsing file <", path, ">..")

		err = yaml.Unmarshal(content, &addon)
		if err != nil {
			return err
		}

		addon.Directory.Path = filepath.Dir(path)
		addon.Directory.Name = filepath.Base(addon.Directory.Path)

		addons = append(addons, addon)

		return nil
	})).To(Succeed())

	GinkgoWriter.Println("Found <", len(addons), "> addons")

	return addons
}

func (setup *SetupInfo) GetImagesForAddon(addon Addon) ([]string, error) {
	yamlFiles, err := sos.GetFilesMatch(addon.Directory.Path, "*.yaml")
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

	if len(addon.Spec.OfflineUsage.LinuxResources.AdditionalImages) > 0 {
		images = append(images, addon.Spec.OfflineUsage.LinuxResources.AdditionalImages...)
	}

	return lo.Union(images), nil
}
