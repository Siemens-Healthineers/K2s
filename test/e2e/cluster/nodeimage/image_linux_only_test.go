// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package nodeimage

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
)

var _ = Describe("Linux-only Image Lifecycle", Label("core", "acceptance", "setup-required", "system-running", "linux-only", "image"), Ordered, func() {
	type linuxListedImage struct {
		ImageId    string `json:"imageid"`
		Repository string `json:"repository"`
		Tag        string `json:"tag"`
		Node       string `json:"node"`
	}

	type linuxListedImages struct {
		ContainerImages []linuxListedImage `json:"containerimages"`
		Error           *string            `json:"error"`
	}

	const (
		testImageRepo   = "k2s-test-linux"
		testImageTag1   = "v1"
		testImageTag2   = "v2"
		testImageNameV1 = testImageRepo + ":" + testImageTag1
		testImageNameV2 = testImageRepo + ":" + testImageTag2
		testRegistry    = "test.registry.local:5000"
	)

	var (
		tempDir       string
		dockerContext string
		exportTarPath string
	)

	hasImage := func(images linuxListedImages, imageName string) bool {
		for _, img := range images.ContainerImages {
			full := fmt.Sprintf("%s:%s", img.Repository, img.Tag)
			if full == imageName || strings.TrimPrefix(full, "localhost/") == imageName {
				return true
			}
		}
		return false
	}

	listImagesJSON := func(ctx context.Context) linuxListedImages {
		output := suite.K2sCli().MustExec(ctx, "image", "ls", "-o", "json")
		parsed := linuxListedImages{}
		Expect(json.Unmarshal([]byte(output), &parsed)).To(Succeed())
		Expect(parsed.Error).To(BeNil(), "image ls returned error: %s", output)
		return parsed
	}

	BeforeAll(func(ctx context.Context) {
		if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("setup type must be Linux-only")
		}

		var err error
		tempDir, err = os.MkdirTemp("", "k2s-linux-image-test-*")
		Expect(err).ToNot(HaveOccurred())

		dockerContext = filepath.Join(tempDir, "buildcontext")
		Expect(os.MkdirAll(dockerContext, 0o755)).To(Succeed())

		dockerfileContent := "FROM scratch\nLABEL app=\"k2s-linux-test\"\n"
		Expect(os.WriteFile(filepath.Join(dockerContext, "Dockerfile"), []byte(dockerfileContent), 0o644)).To(Succeed())

		exportTarPath = filepath.Join(tempDir, "k2s-test-linux-v2.tar")
	})

	AfterAll(func(ctx context.Context) {
		if tempDir != "" {
			_ = os.RemoveAll(tempDir)
		}
		// Clean up any lingering test images
		suite.K2sCli().Exec(ctx, "image", "rm", "-n", testImageNameV1, "--force")
		suite.K2sCli().Exec(ctx, "image", "rm", "-n", testImageNameV2, "--force")
		suite.K2sCli().Exec(ctx, "image", "rm", "-n", "localhost:5000/"+testImageRepo+":"+testImageTag1, "--force")
		suite.K2sCli().Exec(ctx, "image", "registry", "rm", testRegistry)
		suite.K2sCli().Exec(ctx, "image", "registry", "rm", "localhost:5000")
		suite.Kubectl().Exec(ctx, "delete", "pod", "test-registry", "--now", "--ignore-not-found=true")
	})

	It("1) builds a Linux image from minimal Dockerfile context", func(ctx context.Context) {
		GinkgoWriter.Println("Building test Linux image...")
		output := suite.K2sCli().MustExec(ctx, "image", "build", "-d", dockerContext, "-n", testImageRepo, "-t", testImageTag1)
		Expect(output).ToNot(BeEmpty())
	})

	It("2) lists images and asserts built image presence", func(ctx context.Context) {
		GinkgoWriter.Println("Verifying built image is present in image ls -o json...")
		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, testImageNameV1)).To(BeTrue(), "expected image %s to be present", testImageNameV1)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("3) tags image with a new name/tag", func(ctx context.Context) {
		GinkgoWriter.Printf("Tagging image %s as %s...\n", testImageNameV1, testImageNameV2)
		suite.K2sCli().MustExec(ctx, "image", "tag", "-n", testImageNameV1, "-t", testImageNameV2)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, testImageNameV2)).To(BeTrue(), "expected tagged image %s to be present", testImageNameV2)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("4) exports image to tar archive", func(ctx context.Context) {
		GinkgoWriter.Printf("Exporting image %s to %s...\n", testImageNameV2, exportTarPath)
		suite.K2sCli().MustExec(ctx, "image", "export", "-n", testImageNameV2, "-t", exportTarPath)

		fileInfo, err := os.Stat(exportTarPath)
		Expect(err).ToNot(HaveOccurred())
		Expect(fileInfo.Size()).To(BeNumerically(">", 0), "exported tar file should not be empty")
	})

	It("5) removes image via k2s image rm", func(ctx context.Context) {
		GinkgoWriter.Printf("Removing image %s...\n", testImageNameV2)
		suite.K2sCli().MustExec(ctx, "image", "rm", "-n", testImageNameV2)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, testImageNameV2)).To(BeFalse(), "expected image %s to be removed", testImageNameV2)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("6) re-imports image from the exported tar", func(ctx context.Context) {
		GinkgoWriter.Printf("Re-importing image from %s...\n", exportTarPath)
		suite.K2sCli().MustExec(ctx, "image", "import", "-t", exportTarPath)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, testImageNameV2)).To(BeTrue(), "expected re-imported image %s to be present", testImageNameV2)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("7) adds and removes a test registry", func(ctx context.Context) {
		GinkgoWriter.Printf("Adding test registry %s...\n", testRegistry)
		suite.K2sCli().MustExec(ctx, "image", "registry", "add", testRegistry, "--plain-http")

		Eventually(func(g Gomega) {
			output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")
			g.Expect(strings.ToLower(output)).To(ContainSubstring(strings.ToLower(testRegistry)))
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

		GinkgoWriter.Printf("Removing test registry %s...\n", testRegistry)
		suite.K2sCli().MustExec(ctx, "image", "registry", "rm", testRegistry)

		Eventually(func(g Gomega) {
			output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")
			g.Expect(strings.ToLower(output)).ToNot(ContainSubstring(strings.ToLower(testRegistry)))
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("8) performs round-trip registry test (tag, push, rm, pull)", func(ctx context.Context) {
		const (
			localRegistryHost = "localhost:5000"
			registryImageName = localRegistryHost + "/" + testImageRepo + ":" + testImageTag1
		)

		GinkgoWriter.Println("Deploying local test registry pod...")
		suite.Kubectl().MustExec(ctx, "run", "test-registry", "--image=registry:2", "--restart=Never", "--overrides={\"spec\":{\"hostNetwork\":true}}")

		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "image", "rm", "-n", registryImageName, "--force")
			suite.K2sCli().Exec(ctx, "image", "registry", "rm", localRegistryHost)
			suite.Kubectl().Exec(ctx, "delete", "pod", "test-registry", "--now", "--ignore-not-found=true")
		})

		Eventually(func(g Gomega) {
			status, _ := suite.Kubectl().Exec(ctx, "get", "pod", "test-registry", "-o", "jsonpath={.status.phase}")
			g.Expect(strings.TrimSpace(status)).To(Equal("Running"))
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

		GinkgoWriter.Println("Adding local registry with --plain-http...")
		suite.K2sCli().MustExec(ctx, "image", "registry", "add", localRegistryHost, "--plain-http")

		GinkgoWriter.Printf("Tagging %s to %s...\n", testImageNameV1, registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "tag", "-n", testImageNameV1, "-t", registryImageName)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, registryImageName)).To(BeTrue(), "expected tagged registry image %s to be present", registryImageName)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

		GinkgoWriter.Printf("Pushing %s to local registry...\n", registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "push", "-n", registryImageName)

		GinkgoWriter.Printf("Removing local copy of %s...\n", registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "rm", "-n", registryImageName)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, registryImageName)).To(BeFalse(), "expected %s to be removed before pull", registryImageName)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

		GinkgoWriter.Printf("Pulling %s from local registry...\n", registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "pull", registryImageName)

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, registryImageName)).To(BeTrue(), "expected pulled image %s to be present", registryImageName)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())

		GinkgoWriter.Printf("Cleaning up registry image %s...\n", registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "rm", "-n", registryImageName)
		suite.K2sCli().MustExec(ctx, "image", "registry", "rm", localRegistryHost)
		suite.Kubectl().MustExec(ctx, "delete", "pod", "test-registry", "--now", "--ignore-not-found=true")
	})

	It("9) cleans non-K8s images", func(ctx context.Context) {
		GinkgoWriter.Println("Cleaning non-K8s images...")
		suite.K2sCli().MustExec(ctx, "image", "clean")

		Eventually(func(g Gomega) {
			images := listImagesJSON(ctx)
			g.Expect(hasImage(images, testImageNameV1)).To(BeFalse(), "expected %s to be cleaned", testImageNameV1)
			g.Expect(hasImage(images, testImageNameV2)).To(BeFalse(), "expected %s to be cleaned", testImageNameV2)
		}, suite.TestStepTimeout(), suite.TestStepPollInterval()).Should(Succeed())
	})

	It("10) negative tests: rejects --windows and invalid multi-node selectors", func(ctx context.Context) {
		GinkgoWriter.Println("Verifying k2s image build --windows fails with actionable error...")
		buildOut, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "build", "--windows")
		Expect(buildOut).To(ContainSubstring("building Windows container images is not supported on a Linux-only installation"))

		GinkgoWriter.Println("Verifying k2s image clean --nodes n1,n2 fails with actionable error...")
		cleanOut, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "clean", "--nodes", "worker-1,worker-2")
		Expect(cleanOut).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))

		GinkgoWriter.Println("Verifying k2s image import --nodes n1,n2 fails with actionable error...")
		importOut, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "import", "-t", exportTarPath, "--nodes", "worker-1,worker-2")
		Expect(importOut).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
	})
})
