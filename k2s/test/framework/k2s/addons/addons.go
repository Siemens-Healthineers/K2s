// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/samber/lo"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
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
			// kubernetes-dashboard-x.x.x.tgz -> kubernetes-dashboard
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

		var imagesInFile []string
		decoder := yaml.NewDecoder(strings.NewReader(string(content)))

		for {
			var doc interface{}
			if err := decoder.Decode(&doc); err != nil {
				if err == io.EOF {
					break
				}
				GinkgoWriter.Printf("Warning: Failed to parse YAML document in file %s: %v\n", path, err)
				break
			}
			imagesInFile = append(imagesInFile, extractImagesFromYAMLContent(doc)...)
		}

		return imagesInFile
	})

	// add images from additionalImagesFiles
	var yamlFileImages []string
	if len(implementation.OfflineUsage.LinuxResources.AdditionalImagesFiles) > 0 {
		extractedImages, err := implementation.ExtractImagesFromFiles()
		if err != nil {
			GinkgoWriter.Printf("Warning: Failed to extract images from files for %s: %v\n", implementation.Name, err)
		} else {
			yamlFileImages = extractedImages
			images = append(images, extractedImages...)
		}
	}

	// add additional images, but skip versionless ones if versioned equivalent exists in YAML files
	if len(implementation.OfflineUsage.LinuxResources.AdditionalImages) > 0 {
		for _, additionalImage := range implementation.OfflineUsage.LinuxResources.AdditionalImages {
			// Check if this is a versionless image (no :tag)
			hasTag := strings.Contains(additionalImage, ":")
			if !hasTag {
				// Check if a versioned variant exists in YAML file images
				hasVersionedVariant := false
				for _, yamlImage := range yamlFileImages {
					// Extract base image name from YAML image (before the :tag)
					parts := strings.Split(yamlImage, ":")
					if len(parts) > 1 {
						yamlBaseName := parts[0]
						if additionalImage == yamlBaseName {
							hasVersionedVariant = true
							GinkgoWriter.Printf("Skipping versionless image '%s' from additionalImages because versioned variant '%s' exists in additionalImagesFiles\n", additionalImage, yamlImage)
							break
						}
					}
				}
				// Only add if no versioned variant found
				if !hasVersionedVariant {
					images = append(images, additionalImage)
				}
			} else {
				// Already versioned, add it
				images = append(images, additionalImage)
			}
		}
	}

	// add Windows images
	windowsImageCount := 0
	if len(implementation.OfflineUsage.WindowsResources.AdditionalImages) > 0 {
		for _, windowsImage := range implementation.OfflineUsage.WindowsResources.AdditionalImages {
			windowsImageCount++
			GinkgoWriter.Printf("  Windows platform image: %s (will be exported as separate _win.tar)\n", windowsImage)
		}
	}

	// delete folder if it was created
	if tmpChartDir != "" {
		GinkgoWriter.Println("Deleting temp directory", tmpChartDir)
		err := os.RemoveAll(tmpChartDir)
		if err != nil {
			log.Fatal(err)
		}
	}

	// add count of Windows platform images
	uniqueLinuxImages := lo.Union(images)
	totalImageCount := len(uniqueLinuxImages) + windowsImageCount

	GinkgoWriter.Printf("  Unique Linux images: %d, Windows platform images: %d, Total: %d\n",
		len(uniqueLinuxImages), windowsImageCount, totalImageCount)

	result := make([]string, 0, totalImageCount)
	result = append(result, uniqueLinuxImages...)
	for i := 0; i < windowsImageCount; i++ {
		result = append(result, implementation.OfflineUsage.WindowsResources.AdditionalImages[i])
	}

	return result, nil
}

// recursively extracts container image references from parsed YAML content
func extractImagesFromYAMLContent(content interface{}) []string {
	var images []string

	switch v := content.(type) {
	case map[string]interface{}:
		for key, value := range v {
			if key == "image" {
				// Only extract if the value is a string (actual image reference)
				if imageStr, ok := value.(string); ok && imageStr != "" {
					images = append(images, imageStr)
				}
			}
			// Recursively process nested structures
			images = append(images, extractImagesFromYAMLContent(value)...)
		}
	case []interface{}:
		// Process arrays
		for _, item := range v {
			images = append(images, extractImagesFromYAMLContent(item)...)
		}
	}

	return images
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

// loadWindowsRootCAs loads certificates from the Windows certificate store and returns a cert pool
func loadWindowsRootCAs() (*x509.CertPool, error) {
	// Start with system cert pool
	pool, err := x509.SystemCertPool()
	if err != nil {
		GinkgoWriter.Printf("Warning: Failed to load system cert pool: %v\n", err)
		pool = x509.NewCertPool()
	}

	// Load certificates from Windows Root CA store
	storeNames := []string{"ROOT", "CA"}

	for _, storeName := range storeNames {
		store, err := openWindowsCertStore(storeName)
		if err != nil {
			GinkgoWriter.Printf("Warning: Failed to open Windows cert store %s: %v\n", storeName, err)
			continue
		}
		defer closeCertStore(store)

		// Enumerate all certificates in the store
		var cert *syscall.CertContext
		for {
			cert, err = enumCertificates(store, cert)
			if err != nil {
				break
			}
			if cert == nil {
				break
			}

			// Convert Windows cert to x509 certificate
			certBytes := (*[1 << 20]byte)(unsafe.Pointer(cert.EncodedCert))[:cert.Length:cert.Length]
			x509Cert, err := x509.ParseCertificate(certBytes)
			if err != nil {
				GinkgoWriter.Printf("Warning: Failed to parse certificate: %v\n", err)
				continue
			}

			// Add to pool
			pool.AddCert(x509Cert)
		}
	}

	return pool, nil
}

// Windows API functions for certificate store access
var (
	crypt32                     = syscall.NewLazyDLL("crypt32.dll")
	certOpenSystemStoreW        = crypt32.NewProc("CertOpenSystemStoreW")
	certCloseStore              = crypt32.NewProc("CertCloseStore")
	certEnumCertificatesInStore = crypt32.NewProc("CertEnumCertificatesInStore")
)

func openWindowsCertStore(storeName string) (syscall.Handle, error) {
	storeNamePtr, err := syscall.UTF16PtrFromString(storeName)
	if err != nil {
		return 0, err
	}

	store, _, err := certOpenSystemStoreW.Call(0, uintptr(unsafe.Pointer(storeNamePtr)))
	if store == 0 {
		return 0, fmt.Errorf("failed to open cert store: %v", err)
	}

	return syscall.Handle(store), nil
}

func closeCertStore(store syscall.Handle) error {
	ret, _, err := certCloseStore.Call(uintptr(store), 0)
	if ret == 0 {
		return err
	}
	return nil
}

func enumCertificates(store syscall.Handle, prevContext *syscall.CertContext) (*syscall.CertContext, error) {
	var prevContextPtr uintptr
	if prevContext != nil {
		prevContextPtr = uintptr(unsafe.Pointer(prevContext))
	}

	context, _, err := certEnumCertificatesInStore.Call(uintptr(store), prevContextPtr)
	if context == 0 {
		return nil, err
	}

	// Safe conversion: context is a pointer returned from Windows API
	certContext := *(**syscall.CertContext)(unsafe.Pointer(&context))
	return certContext, nil
}

// createHTTPClientWithWindowsCerts creates an HTTP client that trusts Windows certificate store
func createHTTPClientWithWindowsCerts(timeout time.Duration) *http.Client {
	rootCAs, err := loadWindowsRootCAs()
	if err != nil {
		GinkgoWriter.Printf("Warning: Failed to load Windows root CAs: %v. Using system defaults.\n", err)
		return &http.Client{Timeout: timeout}
	}

	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs: rootCAs,
			},
		},
	}
}

func waitForKeycloakReady(keycloakServer, realm string) error {
	realmUrl := fmt.Sprintf("%s/keycloak/realms/%s", keycloakServer, realm)
	maxRetries := 30 // Wait up to 5 minutes (30 * 10s)

	GinkgoWriter.Printf("Checking Keycloak readiness at %s\n", realmUrl)

	// Create HTTP client with Windows certificate store trust
	client := createHTTPClientWithWindowsCerts(10 * time.Second)

	for attempt := 1; attempt <= maxRetries; attempt++ {
		resp, err := client.Get(realmUrl)
		if err != nil {
			GinkgoWriter.Printf("Readiness check %d/%d: Failed to connect to Keycloak: %v\n", attempt, maxRetries, err)
		} else {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				GinkgoWriter.Printf("Keycloak is ready (realm accessible) after %d attempts\n", attempt)

				// Additional check: verify the token endpoint is accessible
				tokenEndpointUrl := fmt.Sprintf("%s/protocol/openid-connect/token", realmUrl)
				tokenResp, tokenErr := client.Get(tokenEndpointUrl)
				if tokenErr != nil {
					GinkgoWriter.Printf("Token endpoint check failed: %v\n", tokenErr)
				} else {
					tokenResp.Body.Close()
					// Token endpoint should return 405 (Method Not Allowed) for GET, which means it's accessible
					if tokenResp.StatusCode == http.StatusMethodNotAllowed || tokenResp.StatusCode == http.StatusBadRequest {
						GinkgoWriter.Printf("Token endpoint is accessible (status: %d)\n", tokenResp.StatusCode)
						return nil
					}
					GinkgoWriter.Printf("Token endpoint returned unexpected status: %d\n", tokenResp.StatusCode)
				}
			} else {
				GinkgoWriter.Printf("Readiness check %d/%d: Realm not ready (status: %d)\n", attempt, maxRetries, resp.StatusCode)
			}
		}

		if attempt < maxRetries {
			backoffTime := 10 * time.Second
			GinkgoWriter.Printf("Waiting %v before next readiness check...\n", backoffTime)
			time.Sleep(backoffTime)
		}
	}

	return fmt.Errorf("keycloak did not become ready after %d attempts", maxRetries)
}

func GetKeycloakToken() (string, error) {
	keycloakServer := "https://k2s.cluster.local"
	realm := "demo-app"
	clientId := "demo-client"
	clientSecret := "1f3QCCQoDQXEwU7ngw9X8kaSe1uX8EIl"
	username := "demo-user"
	password := "password"
	tokenUrl := fmt.Sprintf("%s/keycloak/realms/%s/protocol/openid-connect/token", keycloakServer, realm)

	// First, wait for Keycloak to be fully operational
	if err := waitForKeycloakReady(keycloakServer, realm); err != nil {
		return "", fmt.Errorf("keycloak is not ready: %v", err)
	}

	data := url.Values{}
	data.Set("client_id", clientId)
	data.Set("client_secret", clientSecret)
	data.Set("username", username)
	data.Set("password", password)
	data.Set("grant_type", "password")

	GinkgoWriter.Printf("Getting Keycloak token from %s\n", tokenUrl)

	maxRetries := 15 // Increased from 10 to handle sporadic failures
	// Create HTTP client with Windows certificate store trust
	client := createHTTPClientWithWindowsCerts(30 * time.Second)

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequest("POST", tokenUrl, strings.NewReader(data.Encode()))
		if err != nil {
			return "", fmt.Errorf("failed to create request: %v", err)
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		resp, err := client.Do(req)
		if err != nil {
			if attempt == maxRetries {
				return "", fmt.Errorf("failed to get token after %d attempts: %v", maxRetries, err)
			}
			GinkgoWriter.Printf("Attempt %d/%d: Failed to get token: %v\n", attempt, maxRetries, err)
			// Add jitter to avoid thundering herd
			backoffTime := time.Duration(attempt*5) * time.Second
			jitter := time.Duration(attempt*500) * time.Millisecond
			totalWait := backoffTime + jitter
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", totalWait)
			time.Sleep(totalWait)
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			responseBody := new(strings.Builder)
			io.Copy(responseBody, resp.Body)

			if attempt == maxRetries {
				return "", fmt.Errorf("failed to get token after %d attempts: %s - Response: %s",
					maxRetries, resp.Status, responseBody.String())
			}
			GinkgoWriter.Printf("Attempt %d/%d: Unexpected status code: %s\n", attempt, maxRetries, resp.Status)
			GinkgoWriter.Printf("Response headers: %v\n", resp.Header)
			GinkgoWriter.Printf("Response body: %s\n", responseBody.String())

			// Use the same improved backoff with jitter for HTTP errors
			backoffTime := time.Duration(attempt*5) * time.Second
			jitter := time.Duration(attempt*500) * time.Millisecond
			totalWait := backoffTime + jitter
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", totalWait)
			time.Sleep(totalWait)
			continue
		}

		var result map[string]interface{}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			return "", fmt.Errorf("failed to parse token response: %v", err)
		}
		accessToken, ok := result["access_token"].(string)
		if !ok {
			return "", fmt.Errorf("failed to parse access token")
		}

		// Log token expiration if available
		if exp, ok := result["expires_in"].(float64); ok {
			GinkgoWriter.Printf("Token expires in %.0f seconds\n", exp)
		}

		tokenLength := len(accessToken)
		GinkgoWriter.Printf("Successfully got token (length: %d chars) on attempt %d/%d\n",
			tokenLength, attempt, maxRetries)
		if tokenLength > 20 {
			GinkgoWriter.Printf("Token preview: %s...\n", accessToken[:20])
		}

		return accessToken, nil
	}

	return "", fmt.Errorf("failed to get token after %d attempts", maxRetries)
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
				// For Authorization headers, log a truncated version for debugging
				if key == "Authorization" && strings.HasPrefix(value, "Bearer ") {
					tokenLength := len(value) - 7 // "Bearer " is 7 chars
					truncLength := 20
					if tokenLength > truncLength {
						GinkgoWriter.Printf("Using token: Bearer %s...\n", value[7:7+truncLength])
					} else {
						GinkgoWriter.Printf("Using token: %s\n", value)
					}
				}
			}
		}

		// Perform the HTTP request
		resp, err := client.Do(req)
		if err != nil {
			GinkgoWriter.Printf("Attempt %d/%d: Failed to perform HTTP request: %v\n", attempt, maxRetries, err)
		} else {
			defer resp.Body.Close()

			// Read response body for error reporting
			responseBody, readErr := strings.Builder{}, error(nil)
			if resp.StatusCode != expectedStatusCode {
				bodyBytes := make([]byte, 1024) // Read up to 1KB of response
				n, err := resp.Body.Read(bodyBytes)
				if err != nil && err.Error() != "EOF" {
					readErr = err
				}
				responseBody.Write(bodyBytes[:n])
			}

			// Check the status code
			if resp.StatusCode == expectedStatusCode {
				GinkgoWriter.Printf("Attempt %d/%d: Received expected status code %d\n", attempt, maxRetries, expectedStatusCode)
				return
			}

			GinkgoWriter.Printf("Attempt %d/%d: Unexpected status code: %d %s (expected %d)\n",
				attempt, maxRetries, resp.StatusCode, resp.Status, expectedStatusCode)
			GinkgoWriter.Printf("Response headers: %v\n", resp.Header)

			if readErr != nil {
				GinkgoWriter.Printf("Failed to read response body: %v\n", readErr)
			} else if responseBody.Len() > 0 {
				GinkgoWriter.Printf("Response body: %s\n", responseBody.String())
			}
		}

		// Pause before the next attempt with exponential backoff
		if attempt < maxRetries {
			backoffTime := time.Duration(attempt*5) * time.Second
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", backoffTime)
			time.Sleep(backoffTime)
		}
	}

	// Fail the test if all retries are exhausted
	Fail(fmt.Sprintf("Failed to receive expected status code %d after %d attempts", expectedStatusCode, maxRetries))
}
