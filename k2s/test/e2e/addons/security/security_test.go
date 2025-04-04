// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package security

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const addonName = "security"
const (
	namespace = "k2s"
)

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2"}
var winDeploymentNames = []string{"albums-win1", "albums-win2"}


var manifestDir string
var k2s *dsl.K2s

var proxy string
var testFailed = false
var workloadCreated = false
var suite *framework.K2sTestSuite

func TestSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "security", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)	
	manifestDir = "workload/windows"
    proxy = "http://172.19.1.1:8181"
   
    k2s = dsl.NewK2s(suite)	

	if suite.SetupInfo().SetupConfig.LinuxOnly {
		GinkgoWriter.Println("Found Linux-only setup, skipping Windows-based workloads")
		manifestDir = "workload/base"
	}

    if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNameMultiVMK8s {
        if !suite.SetupInfo().SetupConfig.LinuxOnly {
            proxy = "http://172.19.1.101:8181"
        }
    }

    GinkgoWriter.Println("Using proxy <", proxy, "> for internet access")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Status of cluster after test runs...")
    status := suite.K2sCli().GetStatus(ctx)
    isRunning := status.IsClusterRunning()
    GinkgoWriter.Println("Cluster is running:", isRunning)

    GinkgoWriter.Println("Deleting workloads if necessasry..")
	DeleteWorkloads(ctx)

    if testFailed {
        suite.K2sCli().RunOrFail(ctx, "system", "dump", "-S", "-o")
    }
  
	GinkgoWriter.Println("Checking if addon is disabled..")

	addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
	enabled := addonsStatus.IsAddonEnabled(addonName, "")

	if enabled {
		GinkgoWriter.Println("Addon is still enabled, disabling it..")

		output := suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, "-o")

		GinkgoWriter.Println(output)
	} else {
		GinkgoWriter.Printf("Addon %s is disabled.\n", addonName)
	}

	suite.TearDown(ctx)
})

func DeployWorkloads(ctx context.Context) {
	GinkgoWriter.Println("Deploying workloads to cluster..")	
	
	if manifestDir == "" {
		Fail("Manifest directory is not set, cannot deploy workloads")
	}
	suite.Kubectl().Run(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	suite.Kubectl().Run(ctx, "rollout", "status", "deployment", "-n", namespace, "--timeout="+suite.TestStepTimeout().String())

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
	}

	if !suite.SetupInfo().SetupConfig.LinuxOnly {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
		}
	}
	workloadCreated = true
	GinkgoWriter.Println("Deployments ready for testing")
}

func DeleteWorkloads(ctx context.Context) {
	  // for finding out the sporadically failed test runs
	  if !testFailed && manifestDir != "" && workloadCreated {
        suite.Kubectl().Run(ctx, "delete", "-k", manifestDir)
		workloadCreated = false
        GinkgoWriter.Println("Workloads deleted")
    }
}

func VerifyDeploymentReachableFromHostWithStatusCode(ctx context.Context, name string, namespace string, expectedStatusCode int, url string, headers ...map[string]string) {    
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

var _ = Describe("'security' addon", Ordered, func() {
	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", addonName)

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("enables the addon", func(ctx context.Context) {
		args := []string{"addons", "enable", addonName, "-o"}
		if suite.Proxy() != "" {
			args = append(args, "-p", suite.Proxy())
		}
		suite.K2sCli().RunOrFail(ctx, args...)
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", addonName)

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("prints the status user-friendly", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName)

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
		))
	})

	It("prints the status as JSON", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal(addonName))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available"))),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
			)))
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})
		
	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})
	It("Deploy the workloads after enabling the security addon", func(ctx context.Context) {
		DeployWorkloads(ctx)
	})
	headers := make(map[string]string)
	It("gets bearer token from keycloak", func(ctx context.Context) {
		keycloakServer := "https://k2s.cluster.local"
		realm := "demo-app"
		clientId := "demo-client"
		clientSecret := "1f3QCCQoDQXEwU7ngw9X8kaSe1uX8EIl"
		username := "demo-user"
		password := "password"

		// Function to get access token from Keycloak
		getKeycloakToken := func() (string, error) {
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
			json.NewDecoder(resp.Body).Decode(&result)
			accessToken, ok := result["access_token"].(string)
			if !ok {
				return "", fmt.Errorf("failed to parse access token")
			}
			return accessToken, nil
		}

		// Get the access token
		accessToken, err := getKeycloakToken()
		Expect(err).NotTo(HaveOccurred())

		// Make the request with the access token
		headers = map[string]string{
			"Authorization": fmt.Sprintf("Bearer %s", accessToken),
		}
	})

	DescribeTable("Deployment is reachable from host using bearer token ", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
		if skipOnLinuxOnly && suite.SetupInfo().SetupConfig.LinuxOnly {
			Skip("Linux-only")
		}

		if (len(headers) == 0) {
			Fail("Headers for authentication are not set")
		}
		{	
			url := fmt.Sprintf("https://k2s.cluster.local/%s", name)
			VerifyDeploymentReachableFromHostWithStatusCode(ctx, name, namespace, http.StatusOK, url, headers)
		}},
		Entry("albums-linux1 is reachable from host", "albums-linux1", false),
		Entry("albums-win1 is reachable from host", "albums-win1", true),
		Entry("albums-linux2 is reachable from host", "albums-linux2", false),
		Entry("albums-win2 is reachable from host", "albums-win2", true))

	It("Delete the workloads", func(ctx context.Context) {
		DeleteWorkloads(ctx)
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables default ingress addon", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})

	It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())
	})
	
	It("removed the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
		Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
	})
})

var _ = Describe("'security' addon with enhanced mode", Ordered, func() {
	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", addonName)

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("enables the addon", func(ctx context.Context) {
		args := []string{"addons", "enable", addonName, "-t", "enhanced", "-o"}
		if suite.Proxy() != "" {
			args = append(args, "-p", suite.Proxy())
		}
		suite.K2sCli().RunOrFail(ctx, args...)
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", addonName)

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("prints the status user-friendly", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName)

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
		))
	})

	It("prints the status as JSON", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal(addonName))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available"))),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
			)))
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})
	
	It("installs linkerd", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "linkerd.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})
	
	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})

	It("Deploy the workloads after enabling the security addon", func(ctx context.Context) {
		DeployWorkloads(ctx)
	})

	Describe("Communication", func() {
        DescribeTable("Deployments Availability", func(name string, skipOnLinuxOnly bool) {
            if skipOnLinuxOnly && suite.SetupInfo().SetupConfig.LinuxOnly {
                Skip("Linux-only")
            }

            suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
        },
            Entry("albums-linux1 is available", "albums-linux1", false),
            Entry("albums-win1 is available", "albums-win1", true),
            Entry("albums-linux2 is available", "albums-linux2", false),
            Entry("albums-win2 is available", "albums-win2", true),
            Entry("curl is available", "curl", false))

        DescribeTable("Deployment is not reachable from Host due to StatusForbidden", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
            if skipOnLinuxOnly && suite.SetupInfo().SetupConfig.LinuxOnly {
                Skip("Linux-only")
            }
			url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", name, namespace, name)
            VerifyDeploymentReachableFromHostWithStatusCode(ctx, name, namespace, http.StatusForbidden, url)
        },
            Entry("albums-linux1 is NOT reachable from host", "albums-linux1", false),
            Entry("albums-win1 is NOT reachable from host", "albums-win1", true),
            Entry("albums-linux2 is NOT reachable from host", "albums-linux2", false),
            Entry("albums-win2 is NOT reachable from host", "albums-win2", true))

        Describe("Linux/Windows Deployments Are Reachable from Linux Pods", func() {
            It("Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
                suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
            })

            It("Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
                if suite.SetupInfo().SetupConfig.LinuxOnly {
                    Skip("Linux-only")
                }

                suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
            })

            It("Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
                suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
            })

            It("Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
                if suite.SetupInfo().SetupConfig.LinuxOnly {
                    Skip("Linux-only")
                }

                suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
            })
        })
	})

	It("Delete the workloads", func(ctx context.Context) {
		DeleteWorkloads(ctx)
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables default ingress addon", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})

	It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())
	})
	
	It("uninstalls linkerd", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "linkerd.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())
	})

	It("removed the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
		Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
	})
})
