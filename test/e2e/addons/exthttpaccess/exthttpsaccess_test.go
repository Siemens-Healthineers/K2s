// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package exthttpaccess

import (
	"context"
	"encoding/json"
	"k2s/addons/status"
	"k2sTest/framework"
	"k2sTest/framework/k2s"
	"os/exec"
	"strings"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "exthttpaccess Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "exthttpaccess", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
	expectNoNginxProcessesAreRunning()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'exthttpaccess' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "status", "exthttpaccess", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		if *status.Enabled {
			GinkgoWriter.Println("exthttpaccess seems not to be disabled, disabling now..")

			suite.K2sCli().Run(ctx, "addons", "disable", "exthttpaccess")

			expectNoNginxProcessesAreRunning()
		}
	})

	When("addon is disabled", func() {
		Describe("disable", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "exthttpaccess")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})

		Describe("enable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				args := []string{"addons", "enable", "exthttpaccess", "-a"}
				if suite.Proxy() != "" {
					args = append(args, "-p", suite.Proxy())
				}
				output = suite.K2sCli().Run(ctx, args...)
			})

			It("enables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess enabled"))
			})

			It("checks 'nginx.exe' is running", func() {
				pids, err := findNginxProcesses()

				Expect(err).To(BeNil())
				Expect(len(pids)).To(BeNumerically(">", 0))
			})

			It("checks 'nginx.exe' is listening on ports", func() {
				var err error
				pids, _ := findNginxProcesses()
				listeningPids, err := findListeningProcesses()
				Expect(err).To(BeNil())
				Expect(len(listeningPids)).To(BeNumerically(">", 0))
				isNginxListeningOnPorts := func() bool {
					for _, listeningPid := range listeningPids {
						for _, pid := range pids {
							if pid == listeningPid {
								return true
							}
						}
					}
					return false
				}
				Expect(isNginxListeningOnPorts()).To(BeTrue())
			})
		})
	})

	When("addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "addons", "status", "exthttpaccess", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
			Expect(*status.Enabled).To(BeTrue())
		})

		Describe("enable", func() {
			It("prints already-enabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "exthttpaccess")

				Expect(output).To(ContainSubstring("already enabled"))
			})
		})

		Describe("disable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "addons", "disable", "exthttpaccess")
			})

			It("disables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess disabled"))
			})
		})
	})
})

func expectNoNginxProcessesAreRunning() {
	pids, err := findNginxProcesses()

	Expect(err).To(BeNil())
	Expect(pids).To(BeEmpty())
}

func findNginxProcesses() ([]string, error) {
	p := "nginx.exe"
	pids := make([]string, 0)

	cmd, b := exec.Command("tasklist.exe", "/fo", "csv", "/nh"), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err := cmd.Run()

	if err != nil {
		return nil, err
	}

	output := b.String()
	lines := strings.Split(output, "\n")

	for _, line := range lines {
		if strings.Contains(line, p) {
			fields := strings.Split(line, ",")
			pid := strings.Replace(fields[1], "\"", "", -1)
			pids = append(pids, pid)
		}
	}

	return pids, nil
}

func findListeningProcesses() ([]string, error) {

	type ports struct {
		HTTP             string
		HTTPS            string
		AlternativeHTTP  string
		AlternativeHTTPS string
	}
	p := ports{HTTP: "80", HTTPS: "443", AlternativeHTTP: "8080", AlternativeHTTPS: "8443"}
	pids := make([]string, 0)

	cmd, b := exec.Command("netstat", "-ano"), new(strings.Builder)
	cmd.Stdout = b
	cmd.Stderr = b
	err := cmd.Run()

	if err != nil {
		return nil, err
	}

	output := b.String()
	lines := strings.Split(output, "\n")

	added := make(map[string]bool)

	var arePortsUsed = func(text string, p ports) bool {
		var format = func(port string) string {
			return ":" + port
		}
		return strings.Contains(text, "LISTENING") &&
			(strings.Contains(text, format(p.HTTP)) ||
				strings.Contains(text, format(p.HTTPS)) ||
				strings.Contains(text, format(p.AlternativeHTTP)) ||
				strings.Contains(text, format(p.AlternativeHTTPS)))
	}

	for _, line := range lines {
		if arePortsUsed(line, p) {
			fields := strings.Split(line, " ")
			pid := strings.Replace(fields[len(fields)-1], "\r", "", -1)
			if !added[pid] {
				pids = append(pids, pid)
				added[pid] = true
			}
		}
	}

	return pids, nil
}
