// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Package fluxcdgitopssync tests the GitOps addon delivery infrastructure
// deployed by the rollout/fluxcd addon.
//
// The suite verifies two layers:
//
//  1. Infrastructure layer — the Kubernetes resources in k2s-addon-sync that
//     the rollout/fluxcd Enable.ps1 creates: Namespace, ConfigMaps
//     (addon-sync-config, addon-sync-script), and ServiceAccount.
//     Also verifies that per-addon FluxCD template files are present on disk.
//
//  2. End-to-end sync layer (label "registry") — exports the metrics addon,
//     pushes the OCI artifact to the local registry, applies the per-addon
//     OCIRepository and Kustomization resources rendered from the bundled
//     templates, waits for Flux to reconcile and spawn the sync Job, then
//     verifies the Job log output confirms successful processing.
package fluxcdgitopssync

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/e2e/addons/exportimport"
	gitopssync "github.com/siemens-healthineers/k2s/test/e2e/addons/gitopssync"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	// testClusterTimeout is 30m (vs 20m in rollout-fluxcd_test.go) to accommodate
	// the extra OCI export → registry push → FluxCD reconciliation pipeline under load.
	testClusterTimeout     = time.Minute * 30
	addonSyncNamespace     = "k2s-addon-sync"
	addonSyncConfig        = "addon-sync-config"
	addonSyncScript        = "addon-sync-script"
	addonSyncSA            = "addon-sync-processor"
	testAddonName          = "metrics"
	registryHost           = "k2s.registry.local:30500"
	ociRepoName            = "addon-sync-" + testAddonName
	kustomizationName      = "addon-sync-" + testAddonName
	syncCronJobName        = "addon-sync-" + testAddonName
	testExportSubDir       = "gitops-sync-fluxcd-e2e"
	perAddonTemplateSubDir = "addons/common/manifests/addon-sync/fluxcd/per-addon"
)

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestRolloutFluxCDAddonSync(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout fluxcd GitOps Addon Sync Tests",
		Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive",
			"rollout-fluxcd", "gitops-sync", "fluxcd", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		gitopssync.DumpFluxControllerLogs(ctx, suite, "rollout", 120)
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'rollout fluxcd' GitOps addon sync", Ordered, func() {

	BeforeAll(func(ctx context.Context) {
		GinkgoWriter.Println("[Setup] Enabling rollout fluxcd addon")
		suite.K2sCli().MustExec(ctx, "addons", "enable", "rollout", "fluxcd", "-o")
		k2s.VerifyAddonIsEnabled("rollout", "fluxcd")
		GinkgoWriter.Println("[Setup] rollout fluxcd addon enabled")

		DeferCleanup(func(ctx context.Context) {
			GinkgoWriter.Println("[Teardown] Disabling rollout fluxcd addon")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			k2s.VerifyAddonIsDisabled("rollout", "fluxcd")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
		})
	})

	// -----------------------------------------------------------------------
	// Infrastructure tests — always run when rollout/fluxcd is enabled.
	// -----------------------------------------------------------------------
	Describe("addon-sync infrastructure", Ordered, func() {
		It("creates the k2s-addon-sync namespace", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "namespace", addonSyncNamespace,
				"-o", "jsonpath={.metadata.name}")

			Expect(output).To(Equal(addonSyncNamespace),
				"Namespace %s should exist after enabling rollout/fluxcd", addonSyncNamespace)
		})

		It("creates the addon-sync-config ConfigMap with all required keys", func(ctx context.Context) {
			// Query each key individually so the assertion proves exact key existence,
			// not just that the string appears somewhere in the serialised .data blob.
			for _, key := range []string{"REGISTRY_URL", "K2S_INSTALL_DIR", "INSECURE"} {
				value := suite.Kubectl().MustExec(ctx,
					"get", "configmap", addonSyncConfig,
					"-n", addonSyncNamespace,
					"-o", fmt.Sprintf("jsonpath={.data.%s}", key))
				Expect(value).NotTo(BeEmpty(),
					"addon-sync-config must have a non-empty %s key", key)
			}
		})

		It("creates the addon-sync-script ConfigMap containing Sync-Addons.ps1", func(ctx context.Context) {
			// Query the key directly to prove key existence, not just a substring hit
			// anywhere in the serialised .data blob (e.g. inside the script body itself).
			value := suite.Kubectl().MustExec(ctx,
				"get", "configmap", addonSyncScript,
				"-n", addonSyncNamespace,
				"-o", `jsonpath={.data['Sync-Addons\.ps1']}`)

			Expect(value).NotTo(BeEmpty(),
				"addon-sync-script ConfigMap must have a non-empty Sync-Addons.ps1 key")
		})

		It("creates the addon-sync-processor ServiceAccount", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "serviceaccount", addonSyncSA,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.metadata.name}")

			Expect(output).To(Equal(addonSyncSA),
				"ServiceAccount %s should exist in %s", addonSyncSA, addonSyncNamespace)
		})

		It("does NOT deploy an addon-sync-poller CronJob (FluxCD path uses OCIRepository instead)", func(ctx context.Context) {
			_, exitCode := suite.Kubectl().Exec(ctx,
				"get", "cronjob", "addon-sync-poller",
				"-n", addonSyncNamespace)

			Expect(exitCode).NotTo(Equal(0),
				"FluxCD path should not deploy the ArgoCD-specific addon-sync-poller CronJob")
		})

		It("Flux source-controller Deployment is available for OCIRepository polling", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
		})

		It("Flux kustomize-controller Deployment is available for Kustomization reconciliation", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
		})

		It("cluster-reconciler ClusterRoleBinding references rollout namespace in all subjects", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx,
				"get", "clusterrolebinding", "cluster-reconciler",
				"-o", "jsonpath={range .subjects[*]}{.namespace}{' '}{end}")

			GinkgoWriter.Printf("[Test] cluster-reconciler CRB subject namespaces: %q\n", output)

			Expect(output).NotTo(ContainSubstring("flux-system"),
				"cluster-reconciler CRB must not reference flux-system; subjects should be in rollout namespace")

			for _, ns := range strings.Fields(strings.TrimSpace(output)) {
				Expect(ns).To(Equal("rollout"),
					"All subjects in cluster-reconciler CRB must reference rollout namespace, got: %q", ns)
			}
		})

		It("per-addon OCIRepository template file is present on the host filesystem", func(ctx context.Context) {
			templatePath := filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "ocirepository-template.yaml")

			Expect(templatePath).To(BeAnExistingFile(),
				"OCIRepository template should exist at %s", templatePath)

			GinkgoWriter.Printf("[Test] OCIRepository template found: %s\n", templatePath)
		})

		It("per-addon Kustomization template file is present on the host filesystem", func(ctx context.Context) {
			templatePath := filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "kustomization-template.yaml")

			Expect(templatePath).To(BeAnExistingFile(),
				"Kustomization template should exist at %s", templatePath)

			GinkgoWriter.Printf("[Test] Kustomization template found: %s\n", templatePath)
		})

		It("OCIRepository template contains the semver placeholder token used for runtime constraint injection", func(ctx context.Context) {
			templatePath := filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "ocirepository-template.yaml")

			content, err := os.ReadFile(templatePath)
			Expect(err).ToNot(HaveOccurred())

			Expect(string(content)).To(ContainSubstring(`semver: "ADDON_SEMVER_CONSTRAINT_PLACEHOLDER"`),
				"OCIRepository template must expose ADDON_SEMVER_CONSTRAINT_PLACEHOLDER for runtime semver injection")
		})

		It("OCIRepository template uses the manifests layer selector for gitops-sync extraction", func(ctx context.Context) {
			templatePath := filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "ocirepository-template.yaml")

			content, err := os.ReadFile(templatePath)
			Expect(err).ToNot(HaveOccurred())

			Expect(string(content)).To(SatisfyAll(
				ContainSubstring("application/vnd.k2s.addon.manifests.v1.tar+gzip"),
				ContainSubstring("operation: extract"),
			), "OCIRepository layerSelector must target the manifests layer for gitops-sync/ extraction")
		})

		It("Kustomization template targets ./gitops-sync path with force:true and wait:true", func(ctx context.Context) {
			templatePath := filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "kustomization-template.yaml")

			content, err := os.ReadFile(templatePath)
			Expect(err).ToNot(HaveOccurred())

			Expect(string(content)).To(SatisfyAll(
				ContainSubstring("path: ./gitops-sync"),
				ContainSubstring("force: true"),
				ContainSubstring("wait: true"),
			), "Kustomization template must use ./gitops-sync path with force:true and wait:true")
		})
	})

	// -----------------------------------------------------------------------
	// End-to-end sync test — requires the registry addon and internet access
	// for registry push and FluxCD reconciliation on first run.
	// Labels: registry, internet-required
	// -----------------------------------------------------------------------
	When("registry addon is enabled", Label("registry", "internet-required"), Ordered, func() {
		var exportDir string
		var exportedOciFile string
		var ociRepoYAMLFile string
		var kustomizationYAMLFile string

		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("[Setup] Enabling registry addon for GitOps sync E2E test")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")
			k2s.VerifyAddonIsEnabled("registry")

			exportDir = filepath.Join(suite.RootDir(), "tmp", testExportSubDir)
			GinkgoWriter.Printf("[Setup] Export directory: %s\n", exportDir)

			DeferCleanup(func(ctx context.Context) {
				cleanupFluxCDResources(ctx)
				exportimport.CleanupExportedFiles(exportDir, exportedOciFile)
				cleanupTempYAMLFiles(ociRepoYAMLFile, kustomizationYAMLFile)

				GinkgoWriter.Println("[Teardown] Disabling registry addon")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")
				k2s.VerifyAddonIsDisabled("registry")
			})
		})

		It("exports the metrics addon manifests to an OCI tar (images and packages omitted)", func(ctx context.Context) {
			GinkgoWriter.Println("[Test] Exporting metrics addon (manifests only, --omit-images --omit-packages)")
			// Only the manifests+scripts layer is needed for the GitOps sync Job.
			// --omit-images and --omit-packages avoid pulling Windows images that
			// may not be cached in the containerd store on the test node.
			Expect(os.MkdirAll(exportDir, 0755)).To(Succeed())
			suite.K2sCli().MustExec(ctx, "addons", "export", testAddonName,
				"--omit-images", "--omit-packages",
				"-d", exportDir, "-o")

			pattern := filepath.Join(exportDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", testAddonName))
			files, err := filepath.Glob(pattern)
			Expect(err).ToNot(HaveOccurred())
			Expect(files).To(HaveLen(1),
				"export should produce exactly one OCI tar matching %s", pattern)

			exportedOciFile = files[0]
			info, err := os.Stat(exportedOciFile)
			Expect(err).ToNot(HaveOccurred(), "exported OCI tar should exist at %s", exportedOciFile)
			GinkgoWriter.Printf("[Test] Exported OCI tar (manifests only): %s (%d bytes)\n", exportedOciFile, info.Size())
		})

		It("exported OCI tar has a valid OCI Image Layout structure", func(ctx context.Context) {
			Expect(exportedOciFile).NotTo(BeEmpty())

			// Verify the top-level OCI Image Layout structure within the outer tar.
			tarOutput, exitCode := suite.Cli(gitopssync.TarExe()).Exec(ctx,
				"-tf", exportedOciFile)

			Expect(exitCode).To(Equal(0),
				"tar listing of exported OCI tar should succeed")

			Expect(tarOutput).To(SatisfyAll(
				ContainSubstring("index.json"),
				ContainSubstring("oci-layout"),
				ContainSubstring("blobs/"),
			), "exported OCI tar should contain a valid OCI Image Layout structure")
		})

		It("manifests layer contains gitops-sync directory with substituted sync-job.yaml", func(ctx context.Context) {
			Expect(exportedOciFile).NotTo(BeEmpty())

			verifyLayoutDir, err := os.MkdirTemp("", "k2s-verify-layer-fluxcd-*")
			Expect(err).ToNot(HaveOccurred())
			defer os.RemoveAll(verifyLayoutDir)

			suite.Cli(gitopssync.TarExe()).MustExec(ctx, "-xf", exportedOciFile, "-C", verifyLayoutDir)

			manifestsMediaType := "application/vnd.k2s.addon.manifests.v1.tar+gzip"
			filePaths, err := gitopssync.VerifyManifestsLayerContent(verifyLayoutDir, manifestsMediaType, testAddonName)
			Expect(err).ToNot(HaveOccurred(),
				"manifests layer should contain valid gitops-sync content for addon %q", testAddonName)

			GinkgoWriter.Printf("[Test] Manifests layer verified: %d files, incl. gitops-sync/sync-job.yaml with name addon-sync-%s\n",
				len(filePaths), testAddonName)
			GinkgoWriter.Printf("[Test] Manifests layer paths: %v\n", filePaths)
		})

		It("pushes the exported OCI artifact to the local registry", func(ctx context.Context) {
			Expect(exportedOciFile).NotTo(BeEmpty(), "OCI tar must have been exported")

			// Extract the OCI Image Layout tar to a temp directory.
			// oras copy --from-oci-layout requires a directory, not a tar file.
			orasLayoutDir, err := os.MkdirTemp("", "k2s-oras-layout-fluxcd-*")
			Expect(err).ToNot(HaveOccurred())
			defer os.RemoveAll(orasLayoutDir)

			GinkgoWriter.Printf("[Test] Extracting %s → %s\n", exportedOciFile, orasLayoutDir)
			suite.Cli(gitopssync.TarExe()).MustExec(ctx, "-xf", exportedOciFile, "-C", orasLayoutDir)

			// Read the tag dynamically from the extracted OCI layout to avoid
			// hardcoding the addon version in test code.
			addonTag, err := gitopssync.ReadTagFromOCILayout(orasLayoutDir)
			Expect(err).ToNot(HaveOccurred(), "should read tag from exported OCI layout index.json")
			GinkgoWriter.Printf("[Test] Detected addon tag from OCI layout: %s\n", addonTag)

			srcRef := fmt.Sprintf("%s:%s", orasLayoutDir, addonTag)
			destRef := fmt.Sprintf("%s/addons/%s:%s", registryHost, testAddonName, addonTag)

			GinkgoWriter.Printf("[Test] Pushing %s → %s\n", srcRef, destRef)

			orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
			suite.Cli(orasExe).MustExec(ctx,
				"copy",
				"--from-oci-layout", srcRef,
				destRef,
				"--to-plain-http")

			GinkgoWriter.Printf("[Test] Push succeeded: %s\n", destRef)
		})

		It("applies per-addon OCIRepository and Kustomization resources from bundled templates", func(ctx context.Context) {
			var err error

			ociRepoYAMLFile, err = renderTemplate(
				filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "ocirepository-template.yaml"),
				map[string]string{
					"ADDON_NAME_PLACEHOLDER":              testAddonName,
					"REGISTRY_HOST_PLACEHOLDER":           registryHost,
					"INSECURE_PLACEHOLDER":                "true",
					"ADDON_SEMVER_CONSTRAINT_PLACEHOLDER": ">=0.0.0-0",
				})
			Expect(err).ToNot(HaveOccurred(), "failed to render OCIRepository template")

			kustomizationYAMLFile, err = renderTemplate(
				filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "kustomization-template.yaml"),
				map[string]string{
					"ADDON_NAME_PLACEHOLDER": testAddonName,
				})
			Expect(err).ToNot(HaveOccurred(), "failed to render Kustomization template")

			GinkgoWriter.Printf("[Test] Applying OCIRepository from %s\n", ociRepoYAMLFile)
			suite.Kubectl().MustExec(ctx, "apply", "-f", ociRepoYAMLFile)

			GinkgoWriter.Printf("[Test] Applying Kustomization from %s\n", kustomizationYAMLFile)
			suite.Kubectl().MustExec(ctx, "apply", "-f", kustomizationYAMLFile)

			GinkgoWriter.Printf("[Test] OCIRepository %q and Kustomization %q applied\n",
				ociRepoName, kustomizationName)
		})

		It("OCIRepository detects the new artifact version within 5 minutes", func(ctx context.Context) {
			// Poll until BOTH Ready=True AND artifact.revision is populated.
			// The two status fields are written in the same reconciliation loop but can
			// be observed in separate API responses due to Kubernetes status subresource
			// eventual consistency — asserting both inside Eventually avoids the race
			// where Ready becomes True a moment before artifact is populated.
			var detectedRevision string
			Eventually(func(g Gomega) {
				status, _ := suite.Kubectl().Exec(ctx,
					"get", "ocirepository", ociRepoName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
				revision, _ := suite.Kubectl().Exec(ctx,
					"get", "ocirepository", ociRepoName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.artifact.revision}")
				if status != "True" || revision == "" {
					msg, _ := suite.Kubectl().Exec(ctx,
						"get", "ocirepository", ociRepoName,
						"-n", addonSyncNamespace,
						"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].message}")
					GinkgoWriter.Printf("[Wait] OCIRepository %s Ready=%q revision=%q message=%q\n",
						ociRepoName, status, revision, msg)
				}
				g.Expect(status).To(Equal("True"),
					"OCIRepository %s should become Ready within 5 minutes", ociRepoName)
				g.Expect(revision).NotTo(BeEmpty(),
					"OCIRepository %s should report a non-empty artifact revision", ociRepoName)
				detectedRevision = revision
			}, 5*time.Minute, 15*time.Second, ctx)

			GinkgoWriter.Printf("[Test] OCIRepository selected revision: %s\n", detectedRevision)
		})

		It("Kustomization reconciles and creates the per-addon sync CronJob within 10 minutes", func(ctx context.Context) {
			ociReadyPre, _ := suite.Kubectl().Exec(ctx,
				"get", "ocirepository", ociRepoName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
			if ociReadyPre != "True" {
				GinkgoWriter.Printf("[Pre-flight] OCIRepository %s Ready=%s — triggering reconciliation\n", ociRepoName, ociReadyPre)
				gitopssync.DumpFluxControllerLogs(ctx, suite, "rollout", 60)
				gitopssync.DumpSourceControllerDiagnostics(ctx, suite, "rollout", addonSyncNamespace, ociRepoName)

				// Force an immediate retry to break FluxCD exponential backoff.
				suite.Kubectl().Exec(ctx,
					"annotate", "ocirepository", ociRepoName,
					"-n", addonSyncNamespace,
					"reconcile.fluxcd.io/requestedAt="+time.Now().UTC().Format(time.RFC3339Nano),
					"--overwrite")
				GinkgoWriter.Printf("[Pre-flight] Triggered OCIRepository %q reconciliation\n", ociRepoName)

				Eventually(func() string {
					s, _ := suite.Kubectl().Exec(ctx,
						"get", "ocirepository", ociRepoName,
						"-n", addonSyncNamespace,
						"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
					if s != "True" {
						msg, _ := suite.Kubectl().Exec(ctx,
							"get", "ocirepository", ociRepoName,
							"-n", addonSyncNamespace,
							"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].message}")
						GinkgoWriter.Printf("[Pre-flight] OCIRepository Ready=%s message=%q\n", s, msg)
					}
					return s
				}, 3*time.Minute, 15*time.Second, ctx).Should(Equal("True"),
					"OCIRepository %s must recover to Ready=True", ociRepoName)
				GinkgoWriter.Println("[Pre-flight] OCIRepository recovered to Ready=True")
			}

			suite.Kubectl().MustExec(ctx,
				"annotate", "kustomization", kustomizationName,
				"-n", addonSyncNamespace,
				"reconcile.fluxcd.io/requestedAt="+time.Now().UTC().Format(time.RFC3339Nano),
				"--overwrite")
			GinkgoWriter.Printf("[Test] Immediate reconciliation requested for Kustomization %q\n", kustomizationName)

			pollIteration := 0
			Eventually(func(g Gomega) string {
				pollIteration++

				output, _ := suite.Kubectl().Exec(ctx,
					"get", "cronjob", syncCronJobName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.metadata.name}")
				if output == syncCronJobName {
					return output
				}

				kReadyStatus, _ := suite.Kubectl().Exec(ctx,
					"get", "kustomization", kustomizationName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
				kReadyMessage, _ := suite.Kubectl().Exec(ctx,
					"get", "kustomization", kustomizationName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].message}")
				ociArtifact, _ := suite.Kubectl().Exec(ctx,
					"get", "ocirepository", ociRepoName,
					"-n", addonSyncNamespace,
					"-o", `jsonpath=Ready={.status.conditions[?(@.type=='Ready')].status} url={.status.artifact.url} rev={.status.artifact.revision}`)

				GinkgoWriter.Printf("[Wait] iter=%d CronJob %s not yet created; Kustomization Ready=%q message=%q | OCIRepo: %s\n",
					pollIteration, syncCronJobName, kReadyStatus, kReadyMessage, ociArtifact)

				kEvents, _ := suite.Kubectl().Exec(ctx,
					"get", "events", "-n", addonSyncNamespace,
					"--field-selector=involvedObject.name="+ociRepoName,
					"--sort-by=.lastTimestamp",
					"-o", `jsonpath={range .items[*]}{.type}: {.reason} -- {.message}{"\n"}{end}`)

				if pollIteration == 8 {
					GinkgoWriter.Println("[Diag] 2 minutes elapsed without Job creation — dumping diagnostics")
					gitopssync.DumpFluxControllerLogs(ctx, suite, "rollout", 60)
					gitopssync.DumpSourceControllerDiagnostics(ctx, suite, "rollout", addonSyncNamespace, ociRepoName)

					suite.Kubectl().Exec(ctx,
						"annotate", "ocirepository", ociRepoName,
						"-n", addonSyncNamespace,
						"reconcile.fluxcd.io/requestedAt="+time.Now().UTC().Format(time.RFC3339Nano),
						"--overwrite")
					GinkgoWriter.Printf("[Diag] Re-triggered OCIRepository %q reconciliation\n", ociRepoName)
				}

				if kReadyStatus == "False" && !strings.Contains(kReadyMessage, "retrying") {
					GinkgoWriter.Printf("[FAIL-FAST] Kustomization %s Ready=False: %s\n",
						kustomizationName, kReadyMessage)

					gitopssync.DumpFluxControllerLogs(ctx, suite, "rollout", 80)
					gitopssync.DumpSourceControllerDiagnostics(ctx, suite, "rollout", addonSyncNamespace, ociRepoName)

					fullStatus, _ := suite.Kubectl().Exec(ctx,
						"get", "kustomization", kustomizationName,
						"-n", addonSyncNamespace,
						"-o", "yaml")
					GinkgoWriter.Printf("[Diag] Full Kustomization YAML:\n%s\n",
						gitopssync.SafeTrim(fullStatus, 3000))

					g.Expect(kReadyStatus).To(Equal("True"),
						"Kustomization %s failed reconciliation: %s", kustomizationName, kReadyMessage)
				}

				if kEvents != "" {
					GinkgoWriter.Printf("[Wait] OCIRepository events:\n%s", kEvents)
				}

				return output
			}, 10*time.Minute, 15*time.Second, ctx).Should(Equal(syncCronJobName),
				"Kustomization should create sync CronJob %s within 10 minutes", syncCronJobName)

			GinkgoWriter.Printf("[Test] Sync CronJob %q created by Kustomization\n", syncCronJobName)
		})

		It("sync CronJob spawns a Job that completes without errors and reports successful processing in logs", func(ctx context.Context) {
			waitForFluxSyncCronJobCreated(ctx, 5*time.Minute)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 10*time.Minute)
			GinkgoWriter.Printf("[Test] Waiting for spawned Job %s to complete (timeout: 10m)\n", syncJobName)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			// Explicit failure check visible in this spec body — not hidden in a helper.
			failedStatus, _ := suite.Kubectl().Exec(ctx,
				"get", "job", syncJobName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Failed')].status}")
			failureReason, _ := suite.Kubectl().Exec(ctx,
				"get", "job", syncJobName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[?(@.type=='Failed')].reason}")
			if failedStatus == "True" {
				GinkgoWriter.Printf("[Test] Job %s FAILED — reason: %q\n", syncJobName, failureReason)
			}
			Expect(failedStatus).NotTo(Equal("True"),
				"Job %s must not be in Failed state (reason: %s)", syncJobName, failureReason)

			GinkgoWriter.Println("[Test] Retrieving Job pod logs")
			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)

			GinkgoWriter.Printf("[Test] Job logs (trimmed):\n%s\n", gitopssync.SafeTrim(logs, 2000))

			Expect(logs).To(ContainSubstring("Addon sync completed"),
				"Job log should contain the sync summary line")
			// Assert explicitly zero failures (not just "Failed: 1") to catch N>1 failures.
			Expect(logs).To(ContainSubstring("Failed: 0"),
				"Job log should report Failed: 0 in the sync summary")
			// Assert the per-addon run actually synced the addon (not skipped as unchanged).
			Expect(logs).To(ContainSubstring("Synced: 1"),
				"Job log should report Synced: 1 confirming the addon was processed, not skipped")
			Expect(logs).NotTo(ContainSubstring("[AddonSync][ERROR]"),
				"Job log should contain no ERROR-level messages")
		})

		It("restores addon content when host addon directory is deleted but repo artifact still exists", func(ctx context.Context) {
			hostAddonDir := filepath.Join(suite.RootDir(), "addons", testAddonName)
			hostManifestPath := filepath.Join(hostAddonDir, "addon.manifest.yaml")
			previousJobName := getLatestFluxSyncJobName(ctx)

			Expect(hostManifestPath).To(BeAnExistingFile(),
				"metrics addon should exist on host after initial sync")

			GinkgoWriter.Printf("[Test] Deleting host addon directory to validate restore: %s\n", hostAddonDir)
			Expect(os.RemoveAll(hostAddonDir)).To(Succeed(),
				"host addon directory deletion should succeed")
			Expect(hostAddonDir).NotTo(BeADirectory(),
				"host addon directory should be removed before reconciliation")

			GinkgoWriter.Printf("[Test] Waiting for next CronJob run after host delete; previous Job=%q\n", previousJobName)
			syncJobName := waitForNextFluxSyncJobCreated(ctx, previousJobName, 3*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			GinkgoWriter.Printf("[Test] Restore run logs (trimmed):\n%s\n", gitopssync.SafeTrim(logs, 2000))

			Eventually(func() bool {
				_, err := os.Stat(hostManifestPath)
				return err == nil
			}, 3*time.Minute, 10*time.Second).Should(BeTrue(),
				"addon manifest should be restored on host from repository artifact")

			Expect(logs).To(ContainSubstring("digest unchanged but expected host addon content missing -- forcing re-sync"),
				"sync log should explicitly report restore path when host content is missing")
			Expect(logs).To(ContainSubstring("Synced: 1"),
				"restore run should report one synced addon")
			Expect(logs).To(ContainSubstring("Failed: 0"),
				"restore run should complete without failures")
		})

		It("lifecycle failure during ApplyIfEnabled is reported as Failed and not as Synced", func(ctx context.Context) {
			originalSyncScript := getAddonSyncScriptFromConfigMap(ctx)
			forcedFailureScript := strings.Replace(originalSyncScript,
				"& $updateScript",
				"throw 'E2E forced ApplyIfEnabled lifecycle failure'",
				1)
			Expect(forcedFailureScript).NotTo(Equal(originalSyncScript),
				"Sync-Addons.ps1 should contain '& $updateScript' so lifecycle failure can be forced deterministically")

			applyAddonSyncScriptToConfigMap(ctx, forcedFailureScript)
			DeferCleanup(func(ctx context.Context) {
				applyAddonSyncScriptToConfigMap(ctx, originalSyncScript)
			})

			digestFile := filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", testAddonName)
			const fakeDigest = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
			Expect(os.WriteFile(digestFile, []byte(fakeDigest), 0644)).To(Succeed())
			cleanupFluxSyncJobs(ctx)

			suite.Kubectl().MustExec(ctx,
				"annotate", "kustomization", kustomizationName,
				"-n", addonSyncNamespace,
				"reconcile.fluxcd.io/requestedAt="+time.Now().UTC().Format(time.RFC3339Nano),
				"--overwrite")

			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)

			gitopssync.WaitForJobToFinish(ctx, suite, addonSyncNamespace, syncJobName)

			condition, _ := suite.Kubectl().Exec(ctx,
				"get", "job", syncJobName,
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.status.conditions[*].type}")
			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)

			Expect(condition+logs).To(ContainSubstring("Failed"),
				"Lifecycle failure must be surfaced as failed job/log status")
			Expect(logs).To(ContainSubstring("[ApplyIfEnabled] Update failed for 'metrics'"),
				"Sync log should include ApplyIfEnabled update failure for metrics")
			Expect(logs).To(ContainSubstring("ApplyIfEnabled lifecycle failed for 'metrics' - marking sync as failed"),
				"Sync log should mark metrics sync as failed after lifecycle failure")
			Expect(logs).To(ContainSubstring("Failed: 1"),
				"Sync summary should report one failed addon")
			Expect(logs).To(ContainSubstring("Synced: 0"),
				"Sync summary must report Synced: 0 when lifecycle fails")
			Expect(logs).NotTo(ContainSubstring("[ApplyIfEnabled] 'metrics' updated to v"),
				"Sync log must not emit success update message for metrics when lifecycle fails")

			addonPhase := suite.Kubectl().MustExec(ctx,
				"get", "configmap", "addon-sync-status",
				"-n", addonSyncNamespace,
				"-o", "jsonpath={.data.metrics}")
			Expect(addonPhase).To(Equal("Failed"),
				"addon-sync-status for metrics must be Failed when ApplyIfEnabled lifecycle fails")
		})

	})

	// -----------------------------------------------------------------------
	// Negative test — OCIRepository with wrong layer media type reports NotReady.
	// Run with: --label-filter="registry && negative"
	// -----------------------------------------------------------------------
	When("an OCIRepository is applied for an artifact with wrong layer media type",
		Label("registry", "internet-required", "negative"), Ordered, func() {

			const (
				badAddonName         = "bad-sync-test"
				badAddonTag          = "v1.0.0"
				badOciRepoName       = "addon-sync-bad-sync-test"
				badKustomizationName = "addon-sync-bad-sync-test"
				badSyncJobName       = "addon-sync-bad-sync-test"
			)
			var badLayoutDir, badOciRepoYAMLFile, badKustomizationYAMLFile string

			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")
				k2s.VerifyAddonIsEnabled("registry")

				// Best-effort delete the tag from a prior run so re-runs don't get AlreadyExists
				// when oras pushes the dummy artifact again.
				orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
				suite.Cli(orasExe).Exec(ctx,
					"manifest", "delete",
					fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag),
					"--plain-http", "--force")

				DeferCleanup(func(ctx context.Context) {
					suite.Kubectl().Exec(ctx, "delete", "kustomization", badKustomizationName,
						"-n", addonSyncNamespace, "--ignore-not-found=true")
					suite.Kubectl().Exec(ctx, "delete", "ocirepository", badOciRepoName,
						"-n", addonSyncNamespace, "--ignore-not-found=true")
					suite.Kubectl().Exec(ctx, "delete", "job", badSyncJobName,
						"-n", addonSyncNamespace, "--ignore-not-found=true")
					cleanupTempYAMLFiles(badOciRepoYAMLFile, badKustomizationYAMLFile)
					if badLayoutDir != "" {
						os.RemoveAll(badLayoutDir)
					}
					suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")
					k2s.VerifyAddonIsDisabled("registry")
				})
			})

			It("pushes an OCI artifact with the wrong layer media type to the registry", func(ctx context.Context) {
				var err error
				badLayoutDir, err = gitopssync.CreateDummyOCILayout(badAddonTag)
				Expect(err).ToNot(HaveOccurred(), "should create dummy OCI Image Layout with wrong media type")

				ref := fmt.Sprintf("%s/addons/%s:%s", registryHost, badAddonName, badAddonTag)
				srcRef := fmt.Sprintf("%s:%s", badLayoutDir, badAddonTag)
				GinkgoWriter.Printf("[Test] Pushing malformed artifact from OCI layout %s → %s\n", srcRef, ref)

				orasExe := filepath.Join(suite.RootDir(), "bin", "oras.exe")
				suite.Cli(orasExe).MustExec(ctx, "copy", "--from-oci-layout", srcRef, ref, "--to-plain-http")
				GinkgoWriter.Println("[Test] Malformed artifact accepted by registry (wrong layer media type is valid OCI)")
			})

			It("Kustomization for the mismatched artifact fails reconciliation and no sync Job is spawned", func(ctx context.Context) {
				var err error
				badOciRepoYAMLFile, err = renderTemplate(
					filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "ocirepository-template.yaml"),
					map[string]string{
						"ADDON_NAME_PLACEHOLDER":              badAddonName,
						"REGISTRY_HOST_PLACEHOLDER":           registryHost,
						"INSECURE_PLACEHOLDER":                "true",
						"ADDON_SEMVER_CONSTRAINT_PLACEHOLDER": ">=0.0.0-0",
					})
				Expect(err).ToNot(HaveOccurred(), "failed to render OCIRepository template for bad addon")

				badKustomizationYAMLFile, err = renderTemplate(
					filepath.Join(suite.RootDir(), perAddonTemplateSubDir, "kustomization-template.yaml"),
					map[string]string{
						"ADDON_NAME_PLACEHOLDER": badAddonName,
					})
				Expect(err).ToNot(HaveOccurred(), "failed to render Kustomization template for bad addon")

				GinkgoWriter.Printf("[Test] Applying OCIRepository from %s\n", badOciRepoYAMLFile)
				suite.Kubectl().MustExec(ctx, "apply", "-f", badOciRepoYAMLFile)

				// FluxCD source-controller reports Ready=True even when the layerSelector media
				// type doesn't match — it successfully fetched a valid OCI artifact. The failure
				// signal surfaces one level down at the Kustomization, which can't find the
				// expected ./gitops-sync path in the extracted content.
				GinkgoWriter.Printf("[Test] Waiting for OCIRepository %s to become Ready (max 3m)\n", badOciRepoName)
				Eventually(func() string {
					output, _ := suite.Kubectl().Exec(ctx,
						"get", "ocirepository", badOciRepoName,
						"-n", addonSyncNamespace,
						"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
					return output
				}, 3*time.Minute, 15*time.Second, ctx).ShouldNot(BeEmpty(),
					"OCIRepository %s should resolve its Ready condition within 3 minutes", badOciRepoName)

				ociRepoReady, _ := suite.Kubectl().Exec(ctx,
					"get", "ocirepository", badOciRepoName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
				GinkgoWriter.Printf("[Test] OCIRepository Ready=%s (source-controller does not fail at OCIRepository level for wrong layer media type)\n", ociRepoReady)

				GinkgoWriter.Printf("[Test] Applying Kustomization from %s\n", badKustomizationYAMLFile)
				suite.Kubectl().MustExec(ctx, "apply", "-f", badKustomizationYAMLFile)

				// Wait for Kustomization to attempt reconciliation and set a Ready condition.
				// kustomize-controller will try path ./gitops-sync inside the extracted content
				// which is absent — it should report Ready=False.
				GinkgoWriter.Printf("[Test] Waiting for Kustomization %s to resolve its condition (max 5m)\n", badKustomizationName)
				Eventually(func() string {
					output, _ := suite.Kubectl().Exec(ctx,
						"get", "kustomization", badKustomizationName,
						"-n", addonSyncNamespace,
						"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
					return output
				}, 5*time.Minute, 15*time.Second, ctx).ShouldNot(BeEmpty(),
					"Kustomization %s should resolve its Ready condition within 5 minutes", badKustomizationName)

				kustomizationReady, _ := suite.Kubectl().Exec(ctx,
					"get", "kustomization", badKustomizationName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
				kustomizationMsg, _ := suite.Kubectl().Exec(ctx,
					"get", "kustomization", badKustomizationName,
					"-n", addonSyncNamespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].message}")
				GinkgoWriter.Printf("[Test] Kustomization Ready=%s, message=%q\n", kustomizationReady, kustomizationMsg)

				Expect(kustomizationReady).To(Equal("False"),
					"Kustomization should fail reconciliation: ./gitops-sync path is absent in the wrong-layer artifact")
				Expect(kustomizationMsg).NotTo(BeEmpty(),
					"Kustomization should provide an error message describing the reconciliation failure")

				// No sync Job must be spawned — this is the ultimate signal that the system
				// correctly rejected the malformed artifact end-to-end.
				_, jobExitCode := suite.Kubectl().Exec(ctx,
					"get", "job", badSyncJobName,
					"-n", addonSyncNamespace)
				Expect(jobExitCode).NotTo(Equal(0),
					"No sync Job %s should be spawned for an artifact with wrong layer media type", badSyncJobName)
			})
		})
})

// -----------------------------------------------------------------------
// FluxCD apply-if-enabled parity and backoff tests.
// Run with: --label-filter="registry && apply-if-enabled"
// -----------------------------------------------------------------------
var _ = Describe("FluxCD apply-if-enabled parity + backoff", Ordered,
	Label("registry", "apply-if-enabled", "gitops-sync", "fluxcd"), func() {

		It("initial sync: manual reconcile applies addon and logs [ApplyIfEnabled] with Synced: 1", func(ctx context.Context) {
			ensureDigestFileReset(testAddonName)
			cleanupFluxSyncJobs(ctx)

			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			Expect(logs).To(ContainSubstring("Synced: 1"), "initial sync should process the addon")
			Expect(logs).To(ContainSubstring("[ApplyIfEnabled]"), "initial sync should run apply-if-enabled lifecycle")
		})

		It("no-op unchanged: stable digest skips lifecycle", func(ctx context.Context) {
			if _, statErr := os.Stat(digestFilePath(testAddonName)); statErr != nil {
				Skip("digest file missing; run initial apply-if-enabled parity spec first")
			}
			cleanupFluxSyncJobs(ctx)

			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			Expect(logs).To(Or(
				ContainSubstring("unchanged"),
				ContainSubstring("skipping"),
				ContainSubstring("skip"),
				ContainSubstring("no change"),
			), "no-op sync should report unchanged/skipping behavior")
			Expect(logs).NotTo(ContainSubstring("[ApplyIfEnabled]"),
				"no-op sync must not run apply-if-enabled lifecycle")
		})

		It("forced re-sync: overwritten digest + manual reconcile re-runs lifecycle", func(ctx context.Context) {
			const fakeDigest = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
			Expect(os.WriteFile(digestFilePath(testAddonName), []byte(fakeDigest), 0644)).To(Succeed())
			cleanupFluxSyncJobs(ctx)

			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			Expect(logs).To(Or(ContainSubstring("digest changed"), ContainSubstring("first sync run")),
				"forced re-sync should report changed digest semantics")
			Expect(logs).To(ContainSubstring("Synced: 1"), "forced re-sync should process the addon")
			Expect(logs).To(ContainSubstring("[ApplyIfEnabled]"),
				"forced re-sync should run apply-if-enabled lifecycle")
		})

		It("backoff: failure state is written with attemptCount and lastAttemptUtc", func(ctx context.Context) {
			failureFile := failureStateFilePath()
			_ = os.Remove(failureFile)

			originalSyncScript := getAddonSyncScriptFromConfigMap(ctx)
			forcedFailureScript := strings.Replace(originalSyncScript,
				"& $updateScript",
				"throw 'E2E forced ApplyIfEnabled lifecycle failure for backoff state test'",
				1)
			Expect(forcedFailureScript).NotTo(Equal(originalSyncScript))
			applyAddonSyncScriptToConfigMap(ctx, forcedFailureScript)
			DeferCleanup(func(ctx context.Context) {
				applyAddonSyncScriptToConfigMap(ctx, originalSyncScript)
			})

			const fakeDigest = "sha256:4444444444444444444444444444444444444444444444444444444444444444"
			Expect(os.WriteFile(digestFilePath(testAddonName), []byte(fakeDigest), 0644)).To(Succeed())
			cleanupFluxSyncJobs(ctx)

			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobToFinish(ctx, suite, addonSyncNamespace, syncJobName)

			state := readFailureStateFromFile(failureFile)
			Expect(state.AttemptCount).To(BeNumerically(">=", 1), "failure state should track attemptCount")
			Expect(state.LastAttemptUtc).NotTo(BeEmpty(), "failure state should track lastAttemptUtc")
			Expect(state.CurrentDigest).To(HavePrefix("sha256:"), "failure state should track current digest")
		})

		It("backoff: second poll within window is skipped for same digest", func(ctx context.Context) {
			failureFile := failureStateFilePath()
			if _, statErr := os.Stat(failureFile); statErr != nil {
				Skip("failure state file missing; run prior backoff failure-state spec first")
			}

			cleanupFluxSyncJobs(ctx)
			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			Expect(logs).To(ContainSubstring("Skipping "+testAddonName+" (backoff until"),
				"same digest should be skipped within backoff window")
			Expect(logs).To(ContainSubstring("Synced: 0"), "no addon should be synced during backoff skip")
		})

		It("backoff: new digest bypasses backoff and auto-recovers", func(ctx context.Context) {
			failureFile := failureStateFilePath()
			if _, statErr := os.Stat(failureFile); statErr != nil {
				Skip("failure state file missing; cannot validate digest-bypass recovery")
			}

			const fakeDigest = "sha256:5555555555555555555555555555555555555555555555555555555555555555"
			Expect(os.WriteFile(digestFilePath(testAddonName), []byte(fakeDigest), 0644)).To(Succeed())
			cleanupFluxSyncJobs(ctx)

			triggerFluxReconcile(ctx)
			syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
			gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

			logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
			Expect(logs).To(ContainSubstring("digest changed"), "new digest should bypass backoff")
			Expect(logs).To(ContainSubstring("Synced: 1"), "new digest should trigger successful sync")

			_, statErr := os.Stat(failureFile)
			Expect(os.IsNotExist(statErr)).To(BeTrue(), "failure state should be cleared after recovery")
		})

		It("backoff formula: min(2^attemptCount * 1 minute, 60 minutes)", func(ctx context.Context) {
			failureFile := failureStateFilePath()
			_ = os.Remove(failureFile)

			now := time.Now().UTC()
			cases := []struct {
				name                string
				attemptCount        int
				minutesSinceAttempt float64
				shouldSkip          bool
			}{
				{name: "attempt1-within-window", attemptCount: 1, minutesSinceAttempt: 1.0, shouldSkip: true},
				{name: "attempt2-within-window", attemptCount: 2, minutesSinceAttempt: 1.0, shouldSkip: true},
				{name: "attempt6-capped-at-60", attemptCount: 6, minutesSinceAttempt: 59.0, shouldSkip: true},
				{name: "attempt6-outside-60", attemptCount: 6, minutesSinceAttempt: 61.0, shouldSkip: false},
			}

			for _, tc := range cases {
				lastAttemptUtc := now.Add(-time.Duration(tc.minutesSinceAttempt * float64(time.Minute))).Format(time.RFC3339Nano)
				writeFailureStateToFile(failureFile, addonFailureState{
					CurrentDigest:  "sha256:6666666666666666666666666666666666666666666666666666666666666666",
					AttemptCount:   tc.attemptCount,
					LastAttemptUtc: lastAttemptUtc,
				})

				cleanupFluxSyncJobs(ctx)
				triggerFluxReconcile(ctx)
				syncJobName := waitForLatestFluxSyncJobCreated(ctx, 5*time.Minute)
				gitopssync.WaitForJobCompletion(ctx, suite, addonSyncNamespace, syncJobName)

				logs := gitopssync.GetJobLogs(ctx, suite, addonSyncNamespace, syncJobName)
				computedMinutes := math.Min(math.Pow(2, float64(tc.attemptCount)), 60)
				if tc.shouldSkip {
					Expect(logs).To(ContainSubstring("Skipping "+testAddonName+" (backoff until"),
						"%s should skip inside computed backoff window %.0f minutes", tc.name, computedMinutes)
				} else {
					Expect(logs).NotTo(ContainSubstring("Skipping "+testAddonName+" (backoff until"),
						"%s should not skip outside computed backoff window %.0f minutes", tc.name, computedMinutes)
				}
			}

			_ = os.Remove(failureFile)
		})
	}) // -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

// renderTemplate reads the YAML template at templatePath, substitutes all
// placeholder key→value pairs, and writes the result to a temp file.
// The caller is responsible for removing the temp file.
func renderTemplate(templatePath string, placeholders map[string]string) (string, error) {
	content, err := os.ReadFile(templatePath)
	if err != nil {
		return "", fmt.Errorf("read template %s: %w", templatePath, err)
	}

	rendered := string(content)
	for placeholder, value := range placeholders {
		rendered = strings.ReplaceAll(rendered, placeholder, value)
	}

	tmpFile, err := os.CreateTemp("", "k2s-gitops-*.yaml")
	if err != nil {
		return "", fmt.Errorf("create temp file: %w", err)
	}
	defer tmpFile.Close()

	if _, err = tmpFile.WriteString(rendered); err != nil {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("write temp file: %w", err)
	}

	GinkgoWriter.Printf("[Template] Rendered %s → %s\n", filepath.Base(templatePath), tmpFile.Name())
	return tmpFile.Name(), nil
}

// cleanupFluxCDResources removes per-addon OCIRepository, Kustomization, the
// per-addon sync CronJob, and any spawned sync Jobs created during the E2E test.
func cleanupFluxCDResources(ctx context.Context) {
	GinkgoWriter.Printf("[Cleanup] Deleting per-addon FluxCD resources for %s\n", testAddonName)

	suite.Kubectl().Exec(ctx,
		"delete", "kustomization", kustomizationName,
		"-n", addonSyncNamespace,
		"--ignore-not-found=true")

	suite.Kubectl().Exec(ctx,
		"delete", "ocirepository", ociRepoName,
		"-n", addonSyncNamespace,
		"--ignore-not-found=true")

	suite.Kubectl().Exec(ctx,
		"delete", "cronjob", syncCronJobName,
		"-n", addonSyncNamespace,
		"--ignore-not-found=true")

	cleanupFluxSyncJobs(ctx)

	GinkgoWriter.Printf("[Cleanup] FluxCD resources for %s removed\n", testAddonName)
}

// cleanupTempYAMLFiles removes temporary rendered YAML files.
func cleanupTempYAMLFiles(files ...string) {
	for _, f := range files {
		if f != "" {
			os.Remove(f)
		}
	}
}

func getAddonSyncScriptFromConfigMap(ctx context.Context) string {
	return suite.Kubectl().MustExec(ctx,
		"get", "configmap", addonSyncScript,
		"-n", addonSyncNamespace,
		"-o", "jsonpath={.data['Sync-Addons\\.ps1']}")
}

func applyAddonSyncScriptToConfigMap(ctx context.Context, scriptContent string) {
	scriptFile, err := os.CreateTemp("", "k2s-addon-sync-script-*.ps1")
	Expect(err).ToNot(HaveOccurred())
	defer os.Remove(scriptFile.Name())
	defer scriptFile.Close()

	_, err = scriptFile.WriteString(scriptContent)
	Expect(err).ToNot(HaveOccurred())

	cmYAML := suite.Kubectl().MustExec(ctx,
		"create", "configmap", addonSyncScript,
		"-n", addonSyncNamespace,
		"--from-file=Sync-Addons.ps1="+scriptFile.Name(),
		"--dry-run=client",
		"-o", "yaml")

	cmFile, err := os.CreateTemp("", "k2s-addon-sync-cm-*.yaml")
	Expect(err).ToNot(HaveOccurred())
	defer os.Remove(cmFile.Name())
	defer cmFile.Close()

	_, err = cmFile.WriteString(cmYAML)
	Expect(err).ToNot(HaveOccurred())

	suite.Kubectl().MustExec(ctx, "apply", "-f", cmFile.Name())
}

type addonFailureState struct {
	CurrentDigest  string `json:"CurrentDigest"`
	AttemptCount   int    `json:"AttemptCount"`
	LastAttemptUtc string `json:"LastAttemptUtc"`
}

func triggerFluxReconcile(ctx context.Context) {
	waitForFluxSyncCronJobCreated(ctx, 5*time.Minute)
	suite.Kubectl().MustExec(ctx,
		"annotate", "kustomization", kustomizationName,
		"-n", addonSyncNamespace,
		"reconcile.fluxcd.io/requestedAt="+time.Now().UTC().Format(time.RFC3339Nano),
		"--overwrite")
}

func waitForFluxSyncCronJobCreated(ctx context.Context, timeout time.Duration) {
	Eventually(func() string {
		output, _ := suite.Kubectl().Exec(ctx,
			"get", "cronjob", syncCronJobName,
			"-n", addonSyncNamespace,
			"-o", "jsonpath={.metadata.name}")
		return output
	}, timeout, 15*time.Second, ctx).Should(Equal(syncCronJobName),
		"kustomization should create sync CronJob %s", syncCronJobName)
}

func waitForLatestFluxSyncJobCreated(ctx context.Context, timeout time.Duration) string {
	return waitForNextFluxSyncJobCreated(ctx, "", timeout)
}

func waitForNextFluxSyncJobCreated(ctx context.Context, previousJobName string, timeout time.Duration) string {
	waitForFluxSyncCronJobCreated(ctx, timeout)

	var latestJobName string
	Eventually(func(g Gomega) string {
		jobName, err := getLatestFluxSyncJobNameFromCluster(ctx)
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(jobName).NotTo(BeEmpty())
		g.Expect(jobName).NotTo(Equal(previousJobName))
		latestJobName = jobName
		return jobName
	}, timeout, 15*time.Second, ctx).ShouldNot(Equal(previousJobName),
		"CronJob %s should spawn a new Job distinct from %q", syncCronJobName, previousJobName)

	return latestJobName
}

func getLatestFluxSyncJobName(ctx context.Context) string {
	jobName, err := getLatestFluxSyncJobNameFromCluster(ctx)
	Expect(err).NotTo(HaveOccurred())
	return jobName
}

func getLatestFluxSyncJobNameFromCluster(ctx context.Context) (string, error) {
	output, exitCode := suite.Kubectl().Exec(ctx,
		"get", "jobs",
		"-n", addonSyncNamespace,
		"-o", "json")
	if exitCode != 0 {
		return "", fmt.Errorf("kubectl get jobs exited with %d", exitCode)
	}

	type jobInfo struct {
		Metadata struct {
			Name              string    `json:"name"`
			CreationTimestamp time.Time `json:"creationTimestamp"`
			OwnerReferences   []struct {
				Kind string `json:"kind"`
				Name string `json:"name"`
			} `json:"ownerReferences"`
		} `json:"metadata"`
	}
	type jobList struct {
		Items []jobInfo `json:"items"`
	}

	var jobs jobList
	if err := json.Unmarshal([]byte(output), &jobs); err != nil {
		return "", fmt.Errorf("parse jobs JSON: %w", err)
	}

	matchingJobs := make([]jobInfo, 0)
	for _, job := range jobs.Items {
		for _, owner := range job.Metadata.OwnerReferences {
			if owner.Kind == "CronJob" && owner.Name == syncCronJobName {
				matchingJobs = append(matchingJobs, job)
				break
			}
		}
	}

	if len(matchingJobs) == 0 {
		return "", nil
	}

	sort.Slice(matchingJobs, func(i, j int) bool {
		if matchingJobs[i].Metadata.CreationTimestamp.Equal(matchingJobs[j].Metadata.CreationTimestamp) {
			return matchingJobs[i].Metadata.Name < matchingJobs[j].Metadata.Name
		}
		return matchingJobs[i].Metadata.CreationTimestamp.Before(matchingJobs[j].Metadata.CreationTimestamp)
	})

	return matchingJobs[len(matchingJobs)-1].Metadata.Name, nil
}

func cleanupFluxSyncJobs(ctx context.Context) {
	output, exitCode := suite.Kubectl().Exec(ctx,
		"get", "jobs",
		"-n", addonSyncNamespace,
		"-o", "json")
	if exitCode != 0 {
		return
	}

	type jobMetadata struct {
		Name            string `json:"name"`
		OwnerReferences []struct {
			Kind string `json:"kind"`
			Name string `json:"name"`
		} `json:"ownerReferences"`
	}
	type cleanupJobList struct {
		Items []struct {
			Metadata jobMetadata `json:"metadata"`
		} `json:"items"`
	}

	var jobs cleanupJobList
	if err := json.Unmarshal([]byte(output), &jobs); err != nil {
		return
	}

	for _, job := range jobs.Items {
		for _, owner := range job.Metadata.OwnerReferences {
			if owner.Kind == "CronJob" && owner.Name == syncCronJobName {
				suite.Kubectl().Exec(ctx,
					"delete", "job", job.Metadata.Name,
					"-n", addonSyncNamespace,
					"--ignore-not-found=true")
				break
			}
		}
	}
}

func digestFilePath(addonName string) string {
	return filepath.Join(suite.RootDir(), "addons", ".addon-sync-digests", addonName)
}

func failureStateFilePath() string {
	// Evidence: Sync-Addons.ps1 line 947 — $stateDir = Join-Path $addonsDir '.addon-sync-state'
	// Failure state files are <addonName>.failure under .addon-sync-state/, not .addon-sync-digests/.
	return filepath.Join(suite.RootDir(), "addons", ".addon-sync-state", testAddonName+".failure")
}

func ensureDigestFileReset(addonName string) {
	_ = os.Remove(digestFilePath(addonName))
}

func readFailureStateFromFile(path string) addonFailureState {
	content, err := os.ReadFile(path)
	Expect(err).ToNot(HaveOccurred(), "should read failure state file %s", path)

	var state addonFailureState
	Expect(json.Unmarshal(content, &state)).To(Succeed(), "should parse failure state JSON from %s", path)
	return state
}

func writeFailureStateToFile(path string, state addonFailureState) {
	payload, err := json.Marshal(state)
	Expect(err).ToNot(HaveOccurred())
	Expect(os.WriteFile(path, payload, 0644)).To(Succeed())
}
