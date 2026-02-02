// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"bytes"
	"context"
	"crypto/tls"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	k2s_json "github.com/siemens-healthineers/k2s/internal/json"
	"github.com/siemens-healthineers/k2s/internal/providers/ssh"
	"github.com/siemens-healthineers/k2s/test/framework/http"

	"encoding/json"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

type buildahImage struct {
	Names []string `json:"names"`
}

type crictlImagesResult struct {
	Images []crictlImage `json:"images"`
}

type crictlImage struct {
	RepoTags []string `json:"repoTags"`
}

type k8sImageConfig struct {
	Repository string `json:"Repository"`
	Tag        string `json:"Tag"`
}

const (
	localRegistryUrlPart    = "k2s.registry.local"
	k8sImagesConfigFileName = "kubernetes_images.json"
)

func (k2s *K2s) VerifyImageIsAvailableOnAnyNode(ctx context.Context, name string) {
	if k2s.isImageAvailableOnLinuxNode(name) {
		return
	}
	if k2s.isImageAvailableOnWindowsNode(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' not available on any node", name))
}

func (k2s *K2s) VerifyImageIsNotAvailableOnAnyNode(ctx context.Context, name string) {
	if !k2s.isImageAvailableOnLinuxNode(name) && !k2s.isImageAvailableOnWindowsNode(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' must not be available on any node", name))
}

func (k2s *K2s) IsImageNotAvailableOnAnyNode(ctx context.Context, name string) bool {
	return !k2s.isImageAvailableOnLinuxNode(name) && !k2s.isImageAvailableOnWindowsNode(ctx, name)
}

func (k2s *K2s) VerifyImageIsNotAvailableInLocalRegistry(ctx context.Context, name string) {
	if !k2s.isImageAvailableInLocalRegistry(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' must not be available in local registry", name))
}

func (k2s *K2s) VerifyImageIsAvailableInLocalRegistry(ctx context.Context, name string) {
	if k2s.isImageAvailableInLocalRegistry(ctx, name) {
		return
	}
	Fail(fmt.Sprintf("Image '%s' not available in local registry", name))
}

func (k2s *K2s) GetNonK8sImagesFromNodes(ctx context.Context) (images []string) {
	imagesFromLinuxNode := k2s.getImagesFromLinuxNode()
	imagesFromWindowsNode := k2s.getImagesFromWindowsNode(ctx)
	k8sImages := k2s.getK8sImages()

	// Build set of K8s image repositories for efficient lookup
	k8sRepos := make(map[string]bool)
	for _, k8sImage := range k8sImages {
		// Extract repository from "repository:tag" format
		repo := strings.Split(k8sImage, ":")[0]
		k8sRepos[repo] = true
	}

	for _, image := range append(imagesFromLinuxNode, imagesFromWindowsNode...) {
		// Extract repository from various formats:
		// - "repository:tag"
		// - "repository@sha256:digest"
		var repo string
		if strings.Contains(image, "@") {
			repo = strings.Split(image, "@")[0]
		} else if strings.Contains(image, ":") {
			repo = strings.Split(image, ":")[0]
		} else {
			repo = image
		}

		// Only include if not a K8s system image
		if !k8sRepos[repo] {
			images = append(images, image)
		}
	}
	return
}

func (k2s *K2s) getK8sImages() (images []string) {
	configFilePath := filepath.Join(k2s.suite.SetupInfo().Config.Host().K2sSetupConfigDir(), k8sImagesConfigFileName)

	config, err := k2s_json.FromFile[[]k8sImageConfig](configFilePath)
	Expect(err).ToNot(HaveOccurred())

	for _, imageConfig := range *config {
		images = append(images, fmt.Sprintf("%s:%s", imageConfig.Repository, imageConfig.Tag))
	}
	return
}

func (k2s *K2s) getImagesFromWindowsNode(ctx context.Context) (images []string) {
	crictl := k2s.suite.Cli(filepath.Join(k2s.suite.RootDir(), "bin", "crictl.exe"))
	crictlConfig := filepath.Join(k2s.suite.RootDir(), "bin", "crictl.yaml")
	output := crictl.NoStdOut().MustExec(ctx, "--config", crictlConfig, "images", "-o", "json")

	var imageResult crictlImagesResult
	err := json.Unmarshal([]byte(output), &imageResult)
	Expect(err).ToNot(HaveOccurred())

	for _, imageEntry := range imageResult.Images {
		images = append(images, imageEntry.RepoTags...)
	}
	return
}

func (k2s *K2s) getImagesFromLinuxNode() (images []string) {
	output := new(bytes.Buffer)

	connectionOptions := contracts.ConnectionOptions{
		IpAddress:         k2s.suite.SetupInfo().Config.ControlPlane().IpAddress(),
		Port:              definitions.SSHDefaultPort,
		RemoteUser:        definitions.SSHRemoteUser,
		SshPrivateKeyPath: k2s.suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
		Timeout:           time.Minute * 2,
		StdOutWriter:      output,
	}

	err := ssh.Exec("sudo buildah images --json", connectionOptions)
	Expect(err).ToNot(HaveOccurred())

	var imageList []buildahImage
	err = json.Unmarshal(output.Bytes(), &imageList)
	Expect(err).ToNot(HaveOccurred())

	for _, imageEntry := range imageList {
		images = append(images, imageEntry.Names...)
	}
	return
}

func (k2s *K2s) isImageAvailableOnWindowsNode(ctx context.Context, fullName string) bool {
	return slices.Contains(k2s.getImagesFromWindowsNode(ctx), fullName)
}

func (k2s *K2s) isImageAvailableOnLinuxNode(fullName string) bool {
	return slices.Contains(k2s.getImagesFromLinuxNode(), fullName)
}

func (k2s *K2s) isImageAvailableInLocalRegistry(ctx context.Context, name string) bool {
	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	var registry string
	for _, r := range k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().Registries() {
		if strings.Contains(string(r), localRegistryUrlPart) {
			registry = string(r)
			break
		}
	}
	if registry == "" {
		Fail("Local registry not found in runtime config")
	}

	var protocol string
	var client *http.ResilientHttpClient

	if strings.Contains(registry, ":") {
		protocol = "http"
		client = k2s.suite.HttpClient()
	} else {
		protocol = "https"
		client = k2s.suite.HttpClient(&tls.Config{InsecureSkipVerify: true})
	}

	responseJson, err := client.GetJson(ctx, protocol+"://"+registry+"/v2/_catalog")
	Expect(err).ToNot(HaveOccurred())

	var catalog struct {
		Repositories []string `json:"repositories"`
	}
	err = json.Unmarshal(responseJson, &catalog)
	Expect(err).ToNot(HaveOccurred())

	for _, repository := range catalog.Repositories {
		responseJson, err = client.GetJson(ctx, protocol+"://"+registry+"/v2/"+repository+"/tags/list")
		Expect(err).ToNot(HaveOccurred())

		var image struct {
			Name string   `json:"name"`
			Tags []string `json:"tags"`
		}
		err = json.Unmarshal(responseJson, &image)
		Expect(err).ToNot(HaveOccurred())

		for _, tag := range image.Tags {
			if registry+"/"+image.Name+":"+tag == name {
				return true
			}
		}
	}
	return false
}
