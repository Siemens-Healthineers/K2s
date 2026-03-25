// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package gpunode

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const (
	namespace       = "gpu-node-test"
	workloadsPath   = "workloads/"
	podName         = "cuda-vector-add"
	cudaSampleImage = "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1" // must match workloads/cuda-sample.yaml
)

var suite *framework.K2sTestSuite
var testFailed = false

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)

	hiddenLabels := []string{"addon", "addon-diverse", "acceptance", "setup-required", "invasive", "gpu-node", "system-running", "nvidia"}

	RunSpecs(t, "gpu-node Addon Acceptance Tests", Label(hiddenLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	if !testFailed {
		GinkgoWriter.Println("Deleting workloads..")

		suite.Kubectl().MustExec(ctx, "delete", "-k", workloadsPath, "--ignore-not-found")

		_, exitCode := suite.K2sCli().Exec(ctx, "addons", "disable", "gpu-node", "-o")

		GinkgoWriter.Println("Disable addon result:", exitCode)
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'gpu-node' addon", Ordered, func() {
	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+gpu-node.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("gpu-node"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable", func() {
		It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "gpu-node")

			Expect(output).To(ContainSubstring("already disabled"))
		})
	})

	Describe("enable", func() {
		It("enables the addon", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "enable", "gpu-node", "-o")

			Expect(output).To(SatisfyAll(
				MatchRegexp("Running 'enable' for 'gpu-node' addon"),
				MatchRegexp("'k2s addons enable gpu-node' completed"),
			))
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "gpu-node")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node")

			Expect(output).To(SatisfyAll(
				MatchRegexp("ADDON STATUS"),
				MatchRegexp(`Addon .+gpu-node.+ is .+enabled.+`),
				MatchRegexp("The gpu node is working"),
			))

			output = suite.K2sCli().MustExec(ctx, "addons", "status", "gpu-node", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

			Expect(status.Name).To(Equal("gpu-node"))
			Expect(status.Error).To(BeNil())
			Expect(status.Enabled).NotTo(BeNil())
			Expect(*status.Enabled).To(BeTrue())
			Expect(status.Props).NotTo(BeNil())
			Expect(status.Props).To(ContainElements(
				SatisfyAll(
					HaveField("Name", "IsDevicePluginRunning"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("The gpu node is working")))),
				SatisfyAll(
					HaveField("Name", "IsDCGMExporterRunning"),
					HaveField("Okay", gstruct.PointTo(BeTrue()))),
				// DCGM is no longer deployed (NVML unavailable via dxcore/GPU-PV), but status is still reported as Okay
				SatisfyAll(
					HaveField("Name", "NodeGpuLabels"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(ContainSubstring("gpu=true and accelerator=nvidia")))),
				SatisfyAll(
					HaveField("Name", "GpuAllocatable"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp(`\d+ GPU slots? available`)))),
				SatisfyAll(
					HaveField("Name", "GpuInUse"),
					HaveField("Value", true),
					HaveField("Okay", gstruct.PointTo(BeTrue())),
					HaveField("Message", gstruct.PointTo(MatchRegexp(`\d+ of \d+ GPU slots? in use`)))),
			))
		})

		It("runs CUDA workloads", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "image", "pull", cudaSampleImage, "-o")

			suite.Kubectl().MustExec(ctx, "delete", "pod", podName, "-n", namespace, "--ignore-not-found")
			suite.Kubectl().MustExec(ctx, "apply", "-k", workloadsPath)

			suite.Cluster().ExpectPodToBeCompleted(podName, namespace)
		})

		It("checks CUDA results", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "logs", podName, "-n", namespace)

			Expect(output).To(ContainSubstring("Test PASSED"))
		})

		It("labels the GPU node", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "gpu=true,accelerator=nvidia", "-o", "jsonpath={.items[0].metadata.name}")

			Expect(output).NotTo(BeEmpty())
		})

		It("device plugin has liveness probe configured", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "pods", "-n", "gpu-node", "-l", "k8s-app=nvidia-device-plugin", "-o", "jsonpath={.items[0].spec.containers[0].livenessProbe.exec.command[0]}")

			Expect(output).To(Equal("/usr/lib/wsl/lib/nvidia-smi"))
		})

	})

	Describe("disables cleanly", func() {
		It("disables the addon", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "disable", "gpu-node", "-o")

			Expect(output).To(ContainSubstring("'k2s addons disable gpu-node' completed"))
		})

		It("removes the gpu-node namespace", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "namespace", "gpu-node", "--ignore-not-found")

			Expect(output).To(BeEmpty())
		})

		It("removes GPU node labels", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "nodes", "-l", "gpu=true", "-o", "jsonpath={.items[*].metadata.name}")

			Expect(output).To(BeEmpty())
		})
	})
})
