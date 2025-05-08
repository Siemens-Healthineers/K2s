// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

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
	GinkgoWriter.Println("Collecting images for addon implementation", implementation.Name)
	// collect all yaml files
	yamlFiles, err := sos.GetFilesMatch(implementation.Directory, "*.yaml")
	if err != nil {
		log.Fatal(err)
		return nil, err
	}
	GinkgoWriter.Println("Collected", len(yamlFiles), "yaml files from directory", implementation.Directory)

	// Helm charts part
	tmpChartDir := ""
	// check if directory implementation.Directory/manifests/chart exists
	chartDir := filepath.Join(implementation.Directory, "manifests", "chart")
	if _, err := os.Stat(chartDir); os.IsNotExist(err) {
		GinkgoWriter.Println("Directory %s does not exist, will continue without a helm chart", chartDir)
	} else if err == nil {
		// convert chart to yaml
		GinkgoWriter.Println("Converting chart to yaml")
		chartFiles, err := sos.GetFilesMatch(chartDir, "*.tgz")
		if err != nil {
			// go through all chart files
			log.Fatal(err)
			return nil, err
		}
		// ensure we have only one chart file
		if len(chartFiles) != 1 {
			log.Fatal("Expected only one chart file in the folder", chartDir)
			return nil, fmt.Errorf("Expected only one chart file in the folder %s", chartDir)
		}
		// get a temp directory
		tmpChartDir, err = os.MkdirTemp("", implementation.Name)
		GinkgoWriter.Println("Created temp directory", tmpChartDir)
		if err != nil {
			log.Fatal(err)
			return nil, err
		}
		// convert chart to yaml
		for _, chartFile := range chartFiles {
			// print chart name
			chartName := filepath.Base(chartFile)
			GinkgoWriter.Println("Converting chart", chartName)
			// get the release name from the chart file name
			// kubernetes-dashboard-7.12.0.tgz -> kubernetes-dashboard
			chartNameParts := strings.Split(chartName, "-")
			chartNameParts = chartNameParts[:len(chartNameParts)-1]
			release := strings.Join(chartNameParts, "-")
			// get the path relative to the directory where this file is located
			executable := implementation.Directory + "\\..\\..\\bin\\" + "helm.exe"
			// call helm to template chart
			cmd := []string{executable, "template", release}
			cmd = append(cmd, chartFile)
			cmd = append(cmd, "-f", filepath.Join(chartDir, "values.yaml"))
			cmd = append(cmd, "--output-dir", tmpChartDir)
			// run cmd in order to create yaml files from the helm chart
			GinkgoWriter.Println("Running command", cmd)
			out, err := exec.Command(cmd[0], cmd[1:]...).CombinedOutput()
			if err != nil {
				GinkgoWriter.Println("Command failed with error", err)
				GinkgoWriter.Println("Command output", string(out))
				return nil, err
			}
			// collect all yaml files
			yFiles, err := sos.GetFilesMatch(tmpChartDir, "*.yaml")
			if err != nil {
				return nil, err
			}
			// add yaml files to files
			yamlFiles = append(yamlFiles, yFiles...)
		}
	}

	// exclude files with ## exclude-from-export and manifest
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

	// get images from yaml
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

	// add additional images
	if len(implementation.OfflineUsage.LinuxResources.AdditionalImages) > 0 {
		images = append(images, implementation.OfflineUsage.LinuxResources.AdditionalImages...)
	}

	// delete folder if it was created
	if tmpChartDir != "" {
		GinkgoWriter.Println("Deleting temp directory", tmpChartDir)
		err := os.RemoveAll(tmpChartDir)
		if err != nil {
			log.Fatal(err)
		}
	}

	// return unique images
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

func GetKeycloakToken() (string, error) {

	keycloakServer := "https://k2s.cluster.local"
	realm := "demo-app"
	clientId := "demo-client"
	clientSecret := "1f3QCCQoDQXEwU7ngw9X8kaSe1uX8EIl"
	username := "demo-user"
	password := "password"
	tokenUrl := fmt.Sprintf("%s/keycloak/realms/%s/protocol/openid-connect/token", keycloakServer, realm)
	data := url.Values{}
	data.Set("client_id", clientId)
	data.Set("client_secret", clientSecret)
	data.Set("username", username)
	data.Set("password", password)
	data.Set("grant_type", "password")

	resp, err := http.PostForm(tokenUrl, data)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("failed to get token: %s", resp.Status)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	accessToken, ok := result["access_token"].(string)
	if !ok {
		return "", fmt.Errorf("failed to parse access token")
	}
	return accessToken, nil
}

func VerifyDeploymentReachableFromHostWithStatusCode(ctx context.Context, expectedStatusCode int, url string, headers ...map[string]string) {
	// Create a standard HTTP client
	client := &http.Client{}

	// Retry mechanism
	maxRetries := 5
	for attempt := 1; attempt <= maxRetries; attempt++ {
		// Create a new HTTP request
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		Expect(err).ToNot(HaveOccurred(), "Failed to create HTTP request")

		// Add headers if provided
		if len(headers) > 0 {
			for key, value := range headers[0] {
				req.Header.Add(key, value)
			}
		}

		// Perform the HTTP request
		resp, err := client.Do(req)
		if err != nil {
			GinkgoWriter.Printf("Attempt %d/%d: Failed to perform HTTP request: %v\n", attempt, maxRetries, err)
		} else {
			defer resp.Body.Close()

			// Check the status code
			if resp.StatusCode == expectedStatusCode {
				GinkgoWriter.Printf("Attempt %d/%d: Received expected status code %d\n", attempt, maxRetries, expectedStatusCode)
				return
			}

			GinkgoWriter.Printf("Attempt %d/%d: Unexpected status code %d (expected %d)\n", attempt, maxRetries, resp.StatusCode, expectedStatusCode)
		}

		// Pause before the next attempt
		if attempt < maxRetries {
			time.Sleep(10 * time.Second)
		}
	}

	// Fail the test if all retries are exhausted
	Fail(fmt.Sprintf("Failed to receive expected status code %d after %d attempts", expectedStatusCode, maxRetries))
}
