// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package exthttpaccess

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const validPort = "54321"

var suite *framework.K2sTestSuite

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "exthttpaccess Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "exthttpaccess", "system-running"))
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
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "exthttpaccess", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		if *status.Enabled {
			GinkgoWriter.Println("exthttpaccess seems not to be disabled, disabling now..")

			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "exthttpaccess")

			expectNoNginxProcessesAreRunning()
		}
	})

	When("addon is disabled", func() {
		Describe("disable", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "exthttpaccess")

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
				output = suite.K2sCli().RunOrFail(ctx, args...)
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
				listeningPidsOnStandardHttpPorts, err := findListeningProcesses("80", "443")
				Expect(err).To(BeNil())
				listeningPidsOnAlternativeHttpPorts, err := findListeningProcesses("8080", "8443")
				Expect(err).To(BeNil())
				listeningPids := append(listeningPidsOnStandardHttpPorts, listeningPidsOnAlternativeHttpPorts...)
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
		Describe("status", func() {
			It("displays status correctly", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "exthttpaccess")

				Expect(output).To(SatisfyAll(
					MatchRegexp("ADDON STATUS"),
					MatchRegexp(`Addon .+exthttpaccess.+ is .+enabled.+`),
					MatchRegexp("The nginx reverse proxy is working"),
				))

				output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "exthttpaccess", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("exthttpaccess"))
				Expect(status.Error).To(BeNil())
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeTrue())
				Expect(status.Props).NotTo(BeNil())
				Expect(status.Props).To(ContainElement(
					SatisfyAll(
						HaveField("Name", "IsNginxRunning"),
						HaveField("Value", true),
						HaveField("Okay", gstruct.PointTo(BeTrue())),
						HaveField("Message", gstruct.PointTo(ContainSubstring("The nginx reverse proxy is working")))),
				))
			})
		})

		Describe("enable", func() {
			It("prints already-enabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "exthttpaccess")

				Expect(output).To(ContainSubstring("already enabled"))
			})
		})

		Describe("disable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().RunOrFail(ctx, "addons", "disable", "exthttpaccess")
			})

			It("disables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess disabled"))
			})
		})
	})

	When("addon is disabled", func() {
		Describe("enable with custom http/https ports", func() {
			DescribeTable("does validation on the port values:",
				func(ctx context.Context, httpPort string, httpsPort string, expectedOutput string) {
					args := []string{"addons", "enable", "exthttpaccess"}
					if httpPort != "" {
						args = append(args, "--http-port", httpPort)
					}
					if httpsPort != "" {
						args = append(args, "--https-port", httpsPort)
					}
					if suite.Proxy() != "" {
						args = append(args, "-p", suite.Proxy())
					}
					output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, args...)

					Expect(output).To(ContainSubstring(expectedOutput))
					expectNoNginxProcessesAreRunning()
				},
				Entry("with empty http port value", "", validPort, "The user configured port number '' cannot be used."),
				Entry("with empty https port value", validPort, "", "The user configured port number '' cannot be used."),

				Entry("with http port value not being a number", "not_a_number", validPort, "The user configured port value must be a number."),
				Entry("with https port value not being a number", validPort, "not_a_number", "The user configured port value must be a number."),

				Entry("with http port value not in range", "40000", validPort, "The user configured port number '40000' cannot be used. Please choose a number between 49152 and 65535."),
				Entry("with https port value not in range", validPort, "30000", "The user configured port number '30000' cannot be used. Please choose a number between 49152 and 65535."),

				Entry("with same http and https port values", validPort, validPort, "The user configured port values for HTTP and HTTPS are the same."),
			)
		})

		Describe("enable with custom http/https ports", func() {
			var output string
			httpPort := "49152"
			httpsPort := "49153"
			BeforeAll(func(ctx context.Context) {
				args := []string{"addons", "enable", "exthttpaccess", "--http-port", httpPort, "--https-port", httpsPort}
				if suite.Proxy() != "" {
					args = append(args, "-p", suite.Proxy())
				}
				output = suite.K2sCli().RunOrFail(ctx, args...)
			})

			It("enables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess enabled"))
			})

			It("checks 'nginx.exe' is running", func() {
				pids, err := findNginxProcesses()

				Expect(err).To(BeNil())
				Expect(len(pids)).To(BeNumerically(">", 0))
			})

			It("checks 'nginx.exe' is listening on custom ports", func() {
				var err error
				pids, _ := findNginxProcesses()
				listeningPids, err := findListeningProcesses(httpPort, httpsPort)
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

func findListeningProcesses(httpPort string, httpsPort string) ([]string, error) {

	type ports struct {
		HTTP  string
		HTTPS string
	}
	p := ports{HTTP: httpPort, HTTPS: httpsPort}
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
			(strings.Contains(text, format(p.HTTP)) || strings.Contains(text, format(p.HTTPS)))
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
