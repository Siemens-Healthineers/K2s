// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	registryName        = "k2s-registry.local"
	clusterIp           = "172.19.1.100"
	weatherLinuxSrcPath = "weather"
	weatherWinSrcPath   = "weather-win"

	weatherLinuxDeploymentName = "weather-linux"
	weatherWinDeploymentName   = "weather-win"

	weatherLinuxUrl = "http://" + clusterIp + "/weather-linux"
	weatherWinUrl   = "http://" + clusterIp + "/weather-win"
)

var (
	randomImageTag string
	suite          *framework.K2sTestSuite
)

func TestImageBuild(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "build ContainerImage Functional Tests", Label("functional", "acceptance", "internet-required", "setup-required", "build-image", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepPollInterval(time.Millisecond*200))

	randomImageTag = strconv.FormatInt(GinkgoRandomSeed(), 10)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("build container image", Ordered, func() {

	When("Default Ingress", func() {
		Context("addon is enabled {nginx}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-d", "-o")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o", "-d")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.GetEnabledAddons()).To(BeEmpty())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s-registry.local"), "Local Registry was not enabled")
			})

			Context("build linux based container image", func() {
				When("weather app with DockerFile in input folder", func() {
					var weatherImageName = registryName + "/weather"
					BeforeAll(func(ctx context.Context) {
						GinkgoWriter.Println("Create weather linux image with Input folder as", weatherLinuxSrcPath, "and using Dockerfile in input folder and push to registry")

						suite.K2sCli().Run(ctx, "image", "build",
							"--input-folder", weatherLinuxSrcPath,
							"--dockerfile", weatherLinuxSrcPath+"\\Dockerfile",
							"--image-name", weatherImageName,
							"--image-tag", randomImageTag, "-o", "--push")
					})

					AfterAll(func(ctx context.Context) {
						cleanupBuiltImage(ctx, weatherImageName, randomImageTag, weatherLinuxSrcPath, weatherLinuxDeploymentName)
					})

					It("Built image is available in registry", func(ctx context.Context) {
						images := suite.K2sCli().GetImages(ctx)
						Expect(images.IsImageAvailable(weatherImageName, randomImageTag)).To(BeTrue(), fmt.Sprintf("Image Not found in Registry Name:%v, Tag:%v", weatherImageName, randomImageTag))
					})

					It("Should be deployed in the cluster", func(ctx context.Context) {
						suite.K2sCli().Run(ctx, "image", "rm", "--name", getImageNameWithTag(weatherImageName, randomImageTag))
						deployApp(ctx, weatherLinuxSrcPath, weatherImageName, randomImageTag, weatherLinuxDeploymentName)
					})

					It("Built App Deployment should be accessible from the host", func(ctx context.Context) {
						checkAppAccessibility(ctx, weatherLinuxUrl)
					})
				})

				When("weather app with PreCompile DockerFile in input folder", func() {
					var weatherImageName = registryName + "/weather-precompile"
					BeforeAll(func(ctx context.Context) {
						GinkgoWriter.Println("Create weather linux image with Input folder as", weatherLinuxSrcPath, "and using Pre Compile Dockerfile in input folder and push to registry")

						suite.K2sCli().Run(ctx, "image", "build",
							"--input-folder", weatherLinuxSrcPath,
							"--image-name", weatherImageName,
							"--image-tag", randomImageTag, "-o", "--push")
					})

					AfterAll(func(ctx context.Context) {
						cleanupBuiltImage(ctx, weatherImageName, randomImageTag, weatherLinuxSrcPath, weatherLinuxDeploymentName)
					})

					It("Built image is available in registry", func(ctx context.Context) {
						images := suite.K2sCli().GetImages(ctx)

						Expect(images.IsImageAvailable(weatherImageName, randomImageTag)).To(BeTrue(), fmt.Sprintf("Image Not found in Registry Name:%v, Tag:%v", weatherImageName, randomImageTag))
					})

					It("Should be deployed in the cluster", func(ctx context.Context) {
						suite.K2sCli().Run(ctx, "image", "rm", "--name", getImageNameWithTag(weatherImageName, randomImageTag))
						deployApp(ctx, weatherLinuxSrcPath, weatherImageName, randomImageTag, weatherLinuxDeploymentName)
					})

					It("Built App Deployment should be accessible from the host", func(ctx context.Context) {
						checkAppAccessibility(ctx, weatherLinuxUrl)
					})
				})

				When("weather app with Custom DockerFile and build args", func() {
					var weatherImageName = registryName + "/weather-buildargs"
					BeforeAll(func(ctx context.Context) {
						GinkgoWriter.Println("Create weather linux image with custom docker file Input folder as", weatherLinuxSrcPath, "and using Pre Compile Dockerfile in input folder and push to registry")
						customDockerFileLocation := filepath.Join(weatherLinuxSrcPath, "custom", "Dockerfile.CustomWeatherLinux")

						goBuilderSdkImageArg := "--build-arg=" + "\"GOSDKBASEIMAGE=" + "public.ecr.aws/docker/library/golang:alpine\""
						finalImageArg := "--build-arg=" + "\"FINALBASEIMAGE=" + "public.ecr.aws/docker/library/alpine:edge\""

						suite.K2sCli().Run(ctx, "image", "build",
							"--input-folder", weatherLinuxSrcPath,
							"--dockerfile", customDockerFileLocation,
							"--image-name", weatherImageName,
							"--image-tag", randomImageTag, "-o", "--push",
							goBuilderSdkImageArg, finalImageArg,
						)
					})

					AfterAll(func(ctx context.Context) {
						cleanupBuiltImage(ctx, weatherImageName, randomImageTag, weatherLinuxSrcPath, weatherLinuxDeploymentName)
					})

					It("Built image is available in registry", func(ctx context.Context) {
						images := suite.K2sCli().GetImages(ctx)

						Expect(images.IsImageAvailable(weatherImageName, randomImageTag)).To(BeTrue(), fmt.Sprintf("Image Not found in Registry Name:%v, Tag:%v", weatherImageName, randomImageTag))
					})

					It("Should be deployed in the cluster", func(ctx context.Context) {
						suite.K2sCli().Run(ctx, "image", "rm", "--name", getImageNameWithTag(weatherImageName, randomImageTag))
						deployApp(ctx, weatherLinuxSrcPath, weatherImageName, randomImageTag, weatherLinuxDeploymentName)
					})

					It("Built App Deployment should be accessible from the host", func(ctx context.Context) {
						checkAppAccessibility(ctx, weatherLinuxUrl)
					})
				})
			})

			Context("build windows based container image", func() {
				When("win weather app with PreCompile DockerFile in input folder", func() {
					var weatherImageName = registryName + "/weather-win"

					BeforeAll(func(ctx context.Context) {
						GinkgoWriter.Println("Create weather windows based image with Input folder as", weatherWinSrcPath, "and using Dockerfile in input folder and push to registry")
						suite.Cli().ExecPathWithProxyOrFail(ctx, "go.exe", weatherWinSrcPath, "build")

						suite.K2sCli().Run(ctx, "image", "build",
							"--input-folder", weatherWinSrcPath,
							"--dockerfile", weatherWinSrcPath+"\\Dockerfile.PreCompile",
							"--image-name", weatherImageName,
							"--image-tag", randomImageTag, "-o", "--push", "--windows")
					})

					AfterAll(func(ctx context.Context) {
						cleanupBuiltImage(ctx, weatherImageName, randomImageTag, weatherWinSrcPath, weatherWinDeploymentName)
					})

					It("Built image is available in registry", func(ctx context.Context) {
						images := suite.K2sCli().GetImages(ctx)

						Expect(images.IsImageAvailable(weatherImageName, randomImageTag)).To(BeTrue(), fmt.Sprintf("Image Not found in Registry Name:%v, Tag:%v", weatherImageName, randomImageTag))
					})

					It("Should be deployed in the cluster", func(ctx context.Context) {
						suite.K2sCli().Run(ctx, "image", "rm", "--name", getImageNameWithTag(weatherImageName, randomImageTag))
						deployApp(ctx, weatherWinSrcPath, weatherImageName, randomImageTag, weatherWinDeploymentName)
					})

					It("Built App Deployment should be accessible from the host", func(ctx context.Context) {
						checkAppAccessibility(ctx, weatherWinUrl)
					})
				})
			})
		})
	})

})

func getImageNameWithTag(name string, tag string) string {
	return name + ":" + tag
}

func cleanupBuiltImage(ctx context.Context, imageName, tag, srcPath, deploymentName string) {
	suite.Kubectl().Run(ctx, "delete", "-f", filepath.Join(srcPath, "ing-nginx.yaml"))
	suite.Kubectl().Run(ctx, "delete", "-f", filepath.Join(srcPath, "weather.yaml"))

	suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", deploymentName, "default")

	suite.K2sCli().Run(ctx, "image", "rm", "--name", getImageNameWithTag(imageName, tag))
	suite.K2sCli().Run(ctx, "image", "rm", "--from-registry", "--name", getImageNameWithTag(imageName, tag))

	images := suite.K2sCli().GetImages(ctx)

	Expect(images.IsImageAvailable(imageName, tag)).To(BeFalse(), fmt.Sprintf("Image should be cleaned up after test but found Registry Name:%v, Tag:%v", imageName, tag))
}

func deployApp(ctx context.Context, srcPath, imageName, tag, deploymentName string) {
	deploymentLabel := fmt.Sprintf("deployment/%s", deploymentName)
	newImageName := fmt.Sprintf("%s=%s", deploymentName, getImageNameWithTag(imageName, tag))

	suite.Kubectl().Run(ctx, "apply", "-f", filepath.Join(srcPath, "weather.yaml"))
	suite.Kubectl().Run(ctx, "apply", "-f", filepath.Join(srcPath, "ing-nginx.yaml"))

	suite.Kubectl().Run(ctx, "set", "image", deploymentLabel, newImageName)
	suite.Kubectl().Run(ctx, "rollout", "restart", deploymentLabel)

	suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, "default")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, "default")
}

func checkAppAccessibility(ctx context.Context, url string) {
	suite.Cli().ExecOrFail(ctx, "curl.exe", url, "--fail", "-v", "-ipv4", "--retry", "3", "--retry-all-errors", "--retry-connrefused", "--retry-delay", "30")
}
