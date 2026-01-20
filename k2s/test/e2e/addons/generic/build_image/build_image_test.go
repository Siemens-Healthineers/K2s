// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"context"
	"fmt"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	registryName    = "k2s.registry.local"
	clusterIp       = "172.19.1.100"
	linuxSrcDirName = "weather"
	winSrcDirName   = "weather-win"
	namespace       = "default"
	labelName       = "app"

	weatherLinuxDeploymentName = "weather-linux"
	weatherWinDeploymentName   = "weather-win"

	weatherLinuxUrl = "http://" + clusterIp + "/weather-linux"
	weatherWinUrl   = "http://" + clusterIp + "/weather-win"

	buildAttempts = 3
)

var (
	randomImageTag string
	suite          *framework.K2sTestSuite
	k2s            *dsl.K2s
)

func TestBuildImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Build Container Image Acceptance Tests", Label("functional", "acceptance", "internet-required", "setup-required", "build-image", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepPollInterval(time.Millisecond*200),
		framework.ClusterTestStepTimeout(time.Minute*10))
	k2s = dsl.NewK2s(suite)

	randomImageTag = strconv.FormatInt(GinkgoRandomSeed(), 10)

	suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "--ingress", "nginx", "-o")

	output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")
	Expect(output).Should(ContainSubstring("k2s.registry.local"), "Local registry was not enabled")
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)

	suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o", "-d")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
})

var _ = Describe("build container image", Ordered, func() {
	Context("Linux-based container image", func() {
		When("weather app with DockerFile in input folder", func() {
			const imageName = registryName + "/weather"
			var fullName string

			BeforeAll(func() {
				fullName = imageName + ":" + randomImageTag

				DeferCleanup(func(ctx context.Context) {
					deleteDeployment(ctx, linuxSrcDirName, weatherLinuxDeploymentName)
					cleanupImage(ctx, fullName)
				})
			})

			It("builds the image", FlakeAttempts(buildAttempts), func(ctx context.Context) {
				GinkgoWriter.Println("Create weather Linux image with input folder '", linuxSrcDirName, "' and using Dockerfile in input folder with push to registry")

				suite.K2sCli().MustExec(ctx, "image", "build",
					"--input-folder", linuxSrcDirName,
					"--dockerfile", linuxSrcDirName+"\\Dockerfile",
					"--image-name", imageName,
					"--image-tag", randomImageTag, "-o", "--push")
			})

			It("verifies image is available in local registry", func(ctx context.Context) {
				k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
			})

			It("removes image from node", func(ctx context.Context) {
				removeImageFromNode(ctx, fullName)
			})

			It("pulls image from registry to node", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "image", "pull", fullName)

				k2s.VerifyImageIsAvailableOnAnyNode(ctx, fullName)
			})

			It("removes image from local registry", func(ctx context.Context) {
				removeImageFromLocalRegistry(ctx, fullName)
			})

			It("pushes image to local registry", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "image", "push", "-n", fullName)

				k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
			})

			It("can tag the new image", func(ctx context.Context) {
				newTag := "vNext"
				newFullName := imageFullName(imageName, newTag)

				suite.K2sCli().MustExec(ctx, "image", "tag", "-n", fullName, "-t", newFullName)

				k2s.VerifyImageIsAvailableOnAnyNode(ctx, newFullName)
			})

			It("removes image from node", func(ctx context.Context) {
				removeImageFromNode(ctx, fullName)
			})

			It("deploys the new image in the cluster", func(ctx context.Context) {
				deployWithImage(ctx, linuxSrcDirName, fullName, weatherLinuxDeploymentName)
			})

			It("can access the deployment from host", func(ctx context.Context) {
				verifyDeploymentAccessibility(ctx, weatherLinuxUrl)
			})
		})

		When("weather app with PreCompile DockerFile in input folder", func() {
			const imageName = registryName + "/weather-precompile"
			var fullName string

			BeforeAll(func() {
				fullName = imageName + ":" + randomImageTag

				DeferCleanup(func(ctx context.Context) {
					deleteDeployment(ctx, linuxSrcDirName, weatherLinuxDeploymentName)
					cleanupImage(ctx, fullName)
				})
			})

			It("builds the image", FlakeAttempts(buildAttempts), func(ctx context.Context) {
				GinkgoWriter.Println("Create weather Linux image with input folder '", linuxSrcDirName, "' and using Pre Compile Dockerfile in input folder with push to registry")

				suite.K2sCli().MustExec(ctx, "image", "build",
					"--input-folder", linuxSrcDirName,
					"--image-name", imageName,
					"--image-tag", randomImageTag, "-o", "--push")
			})

			It("verifies image is available in local registry", func(ctx context.Context) {
				k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
			})

			It("removes image from node", func(ctx context.Context) {
				removeImageFromNode(ctx, fullName)
			})

			It("deploys the new image in the cluster", func(ctx context.Context) {
				deployWithImage(ctx, linuxSrcDirName, fullName, weatherLinuxDeploymentName)
			})

			It("can access the deployment from host", func(ctx context.Context) {
				verifyDeploymentAccessibility(ctx, weatherLinuxUrl)
			})
		})

		When("weather app with custom DockerFile and build args", func() {
			const imageName = registryName + "/weather-buildargs"
			const goBuilderSdkImageArg = "--build-arg=" + "\"GOSDKBASEIMAGE=" + "public.ecr.aws/docker/library/golang:alpine\""
			const finalImageArg = "--build-arg=" + "\"FINALBASEIMAGE=" + "public.ecr.aws/docker/library/alpine:edge\""

			var fullName string
			var customDockerFileLocation string

			BeforeAll(func() {
				fullName = imageName + ":" + randomImageTag
				customDockerFileLocation = filepath.Join(linuxSrcDirName, "custom", "Dockerfile.CustomWeatherLinux")

				DeferCleanup(func(ctx context.Context) {
					deleteDeployment(ctx, linuxSrcDirName, weatherLinuxDeploymentName)
					cleanupImage(ctx, fullName)
				})
			})

			It("builds the image", FlakeAttempts(buildAttempts), func(ctx context.Context) {
				GinkgoWriter.Println("Create weather Linux image with custom Dockerfile input folder '", linuxSrcDirName, "' and using Pre Compile Dockerfile in input folder with push to registry")

				suite.K2sCli().MustExec(ctx, "image", "build",
					"--input-folder", linuxSrcDirName,
					"--dockerfile", customDockerFileLocation,
					"--image-name", imageName,
					"--image-tag", randomImageTag, "-o", "--push",
					goBuilderSdkImageArg, finalImageArg,
				)
			})

			It("verifies image is available in local registry", func(ctx context.Context) {
				k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
			})

			It("removes image from node", func(ctx context.Context) {
				removeImageFromNode(ctx, fullName)
			})

			It("deploys the new image in the cluster", func(ctx context.Context) {
				deployWithImage(ctx, linuxSrcDirName, fullName, weatherLinuxDeploymentName)
			})

			It("can access the deployment from host", func(ctx context.Context) {
				verifyDeploymentAccessibility(ctx, weatherLinuxUrl)
			})
		})
	})

	Context("Windows-based container image", func() {
		const imageName = registryName + "/weather-win"
		var fullName string

		BeforeAll(func() {
			fullName = imageName + ":" + randomImageTag

			DeferCleanup(func(ctx context.Context) {
				deleteDeployment(ctx, winSrcDirName, weatherWinDeploymentName)
				cleanupImage(ctx, fullName)
			})
		})

		It("builds the image", FlakeAttempts(buildAttempts), func(ctx context.Context) {
			GinkgoWriter.Println("Create weather Windows image with input folder '", winSrcDirName, "' and using Dockerfile in input folder with push to registry")

			suite.Cli("go.exe").WorkingDir(winSrcDirName).UseProxy().MustExec(ctx, "build")

			suite.K2sCli().MustExec(ctx, "image", "build",
				"--input-folder", winSrcDirName,
				"--dockerfile", winSrcDirName+"\\Dockerfile.PreCompile",
				"--image-name", imageName,
				"--image-tag", randomImageTag, "-o", "--push", "--windows")
		})

		It("verifies image is available in local registry", func(ctx context.Context) {
			k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
		})

		It("removes image from node", func(ctx context.Context) {
			removeImageFromNode(ctx, fullName)
		})

		It("pulls image from registry to node", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "image", "pull", fullName)

			k2s.VerifyImageIsAvailableOnAnyNode(ctx, fullName)
		})

		It("removes image from local registry", func(ctx context.Context) {
			removeImageFromLocalRegistry(ctx, fullName)
		})

		It("pushes image to local registry", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "image", "push", "-n", fullName)

			k2s.VerifyImageIsAvailableInLocalRegistry(ctx, fullName)
		})

		It("can tag the new image", func(ctx context.Context) {
			newTag := "vNext"
			newFullName := imageFullName(imageName, newTag)

			suite.K2sCli().MustExec(ctx, "image", "tag", "-n", fullName, "-t", newFullName)

			k2s.VerifyImageIsAvailableOnAnyNode(ctx, newFullName)
		})

		It("removes image from node", func(ctx context.Context) {
			removeImageFromNode(ctx, fullName)
		})

		It("deploys the new image in the cluster", func(ctx context.Context) {
			deployWithImage(ctx, winSrcDirName, fullName, weatherWinDeploymentName)
		})

		It("can access the deployment from host", func(ctx context.Context) {
			verifyDeploymentAccessibility(ctx, weatherWinUrl)
		})
	})
})

func imageFullName(name string, tag string) string {
	return name + ":" + tag
}

func cleanupImage(ctx context.Context, name string) {
	removeImageFromNode(ctx, name)
	removeImageFromLocalRegistry(ctx, name)
}

func deployWithImage(ctx context.Context, srcPath, name, deploymentName string) {
	deploymentLabel := fmt.Sprintf("deployment/%s", deploymentName)
	newImageName := fmt.Sprintf("%s=%s", deploymentName, name)

	suite.Kubectl().MustExec(ctx, "apply", "-f", filepath.Join(srcPath, "weather.yaml"))
	suite.Kubectl().MustExec(ctx, "apply", "-f", filepath.Join(srcPath, "ing-nginx.yaml"))

	suite.Kubectl().MustExec(ctx, "set", "image", deploymentLabel, newImageName)
	suite.Kubectl().MustExec(ctx, "rollout", "restart", deploymentLabel)

	suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, labelName, deploymentName, namespace)
}

func deleteDeployment(ctx context.Context, srcDirName, deploymentName string) {
	suite.Kubectl().Exec(ctx, "delete", "-f", filepath.Join(srcDirName, "ing-nginx.yaml"))
	suite.Kubectl().Exec(ctx, "delete", "-f", filepath.Join(srcDirName, "weather.yaml"))

	suite.Cluster().ExpectDeploymentToBeRemoved(ctx, labelName, deploymentName, namespace)
}

func removeImageFromNode(ctx context.Context, name string) {
	Eventually(func(g Gomega) {
		suite.K2sCli().Exec(ctx, "image", "rm", "--name", name, "-o")
		g.Expect(k2s.IsImageNotAvailableOnAnyNode(ctx, name)).To(BeTrue(), "Image '%s' should not be available on any node", name)
	}).WithContext(ctx).WithTimeout(30 * time.Second).WithPolling(2 * time.Second).Should(Succeed())
}

func removeImageFromLocalRegistry(ctx context.Context, name string) {
	suite.K2sCli().Exec(ctx, "image", "rm", "--from-registry", "--name", name, "-o")

	k2s.VerifyImageIsNotAvailableInLocalRegistry(ctx, name)
}

func verifyDeploymentAccessibility(ctx context.Context, url string) {
	suite.Cli("curl.exe").MustExec(ctx, url, "--fail", "-v", "-ipv4", "--retry", "10", "--retry-all-errors", "--retry-connrefused", "--retry-delay", "30")
}
