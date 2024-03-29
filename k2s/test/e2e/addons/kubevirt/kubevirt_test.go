// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package kubevirt

import (
	"context"
	"fmt"

	"encoding/json"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite
var isManualExecution = false

const manualExecutionFilterTag = "manual"

var automatedExecutionSkipMessage = fmt.Sprintf("can only be run using the filter value '%s'", manualExecutionFilterTag)

func TestAddon(t *testing.T) {
	executionLabels := []string{"addon", "acceptance", "setup-required", "invasive", "kubevirt", "system-running"}
	userAppliedLabels := GinkgoLabelFilter()
	if strings.Compare(userAppliedLabels, "") != 0 {
		if Label(manualExecutionFilterTag).MatchesLabelFilter(userAppliedLabels) {
			isManualExecution = true
			executionLabels = append(executionLabels, manualExecutionFilterTag)
		}
	}

	RegisterFailHandler(Fail)
	RunSpecs(t, "kubevirt Addon Acceptance Tests", Label(executionLabels...))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
	expectVirtctlNotInstalled()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'kubevirt' addon", Ordered, func() {
	When("addon is disabled", func() {
		Describe("disable", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "kubevirt")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})

		Describe("enable", func() {
			BeforeAll(func(ctx context.Context) {
				if !isManualExecution {
					Skip(automatedExecutionSkipMessage)
				}
				args := []string{"addons", "enable", "kubevirt"}
				if suite.Proxy() != "" {
					args = append(args, "-p", suite.Proxy())
				}
				suite.K2sCli().Run(ctx, args...)
			})

			It("enables the addon", func(ctx context.Context) {
				podNames := suite.Kubectl().Run(ctx, "get", "pods", "-n", "kubevirt", "-o", "jsonpath='{.items[*].metadata.name}'")

				Expect(podNames).To(ContainSubstring("virt-controller"))
			})

			It("installs 'virtctl.exe'", func() {
				_, err := runVirtctlCommand(make([]string, 0))

				Expect(err).To(BeNil())
			})
		})
	})
	When("addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			if !isManualExecution {
				Skip(automatedExecutionSkipMessage)
			}

			output := suite.K2sCli().Run(ctx, "addons", "status", "kubevirt", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
			Expect(*status.Enabled).To(BeTrue())
		})

		Describe("resource 'VirtualMachine'", func() {
			AfterAll(func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-f", "test.yaml")
			})

			It("creates a VM", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-f", "test.yaml")
				vmStatusOutput := suite.Kubectl().Run(ctx, "get", "vms", "testvm")
				Expect(vmStatusOutput).To(ContainSubstring("Stopped"))

				output, err := runVirtctlCommand([]string{"start", "testvm"})

				Expect(err).To(BeNil())
				Expect(output).To(ContainSubstring("VM testvm was scheduled to start"))

				suite.Kubectl().Run(ctx, "wait", "--timeout=180s", "--for=condition=ContainersReady", "pod", "-l", "kubevirt.io/size=small,kubevirt.io/domain=testvm")

				Eventually(suite.Kubectl().Run).
					WithArguments("get", "vms", "testvm").
					WithTimeout(3 * time.Minute).
					WithPolling(30 * time.Second).
					WithContext(ctx).
					Should(ContainSubstring("Running"))

				podName := suite.Kubectl().Run(ctx, "get", "pod", "-l", "kubevirt.io/size=small,kubevirt.io/domain=testvm", "-o", "jsonpath={.items[0].metadata.name}")
				Expect(podName).To(ContainSubstring("testvm"))

				runningVMsOutput := suite.Kubectl().Run(ctx, "exec", podName, "--", "virsh", "list", "--all")
				Expect(runningVMsOutput).To(ContainSubstring("default_testvm   running"))
			})
		})

		Describe("disable", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "kubevirt")

				Eventually(isKubectlAvailable).WithTimeout(3 * time.Minute).WithPolling(30 * time.Second).Should(BeTrue())
			})

			It("disables the addon", func(ctx context.Context) {
				podNames := suite.Kubectl().Run(ctx, "get", "pods", "-n", "kubevirt", "-o", "jsonpath='{.items[*].metadata.name}'")

				Expect(podNames).To(BeComparableTo("''"))
			})

			It("uninstalls 'virtctl.exe'", func() {
				_, err := runVirtctlCommand(make([]string, 0))

				Expect(err).ShouldNot(BeNil())
			})
		})
	})
})

func runVirtctlCommand(args []string) (string, error) {
	cmd, b := exec.Command("virtctl.exe", args...), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err := cmd.Run()

	if err != nil {
		return "", err
	}

	output := b.String()
	return output, nil
}

func isKubectlAvailable() bool {
	var err error
	cmd, b := exec.Command("kubectl.exe", "get", "pods"), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err = cmd.Run()
	if err != nil || strings.Contains(b.String(), "Unable to connect to the server") {
		return false
	} else {
		return true
	}
}

func expectVirtctlNotInstalled() {
	_, err := runVirtctlCommand(make([]string, 0))

	Expect(err).ShouldNot(BeNil())
}
