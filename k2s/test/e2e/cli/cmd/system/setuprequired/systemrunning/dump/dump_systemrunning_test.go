// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dump

import (
	"archive/zip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestDump(t *testing.T) {
	os.Setenv("SYSTEM_TEST_TIMEOUT", "10m")
	RegisterFailHandler(Fail)
	RunSpecs(t, "system dump CLI Commands Acceptance Tests", Label("cli", "system", "dump", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system dump", func() {
	It("creates and verifies the system dump zip file with expected contents", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "system", "dump", "--skip-open")
		Expect(output).NotTo(BeEmpty(), "system dump output should not be empty")

		logsDir := suite.LogsDir()
		files, err := os.ReadDir(logsDir)
		Expect(err).NotTo(HaveOccurred(), "failed to read logs directory")
		var dumpZip string
		for _, f := range files {
			if strings.HasPrefix(f.Name(), "k2s-dump-") && strings.HasSuffix(f.Name(), ".zip") {
				dumpZip = filepath.Join(logsDir, f.Name())
				break
			}
		}
		Expect(dumpZip).NotTo(BeEmpty(), "dump zip file not found")
		_, err = os.Stat(dumpZip)
		Expect(err).NotTo(HaveOccurred(), "dump zip file does not exist")
		// Inspect contents using archive/zip
		r, err := zip.OpenReader(dumpZip)
		Expect(err).NotTo(HaveOccurred(), "failed to open dump zip")
		defer r.Close()

		var foundSetupJson, foundClusterDir, foundHostDir bool
		for _, f := range r.File {
			GinkgoWriter.Printf("Found file in zip: %s\n", f.Name)
			if strings.HasSuffix(f.Name, "/config/setup.json") || strings.HasSuffix(f.Name, "\\config\\setup.json") {
				foundSetupJson = true
			}
			if strings.HasSuffix(f.Name, "/cluster/pods-wide.txt") || strings.HasSuffix(f.Name, "\\cluster\\pods-wide.txt") {
				foundClusterDir = true
			}
			if strings.HasSuffix(f.Name, "/host/ipconfig-allcompartments.txt") || strings.HasSuffix(f.Name, "\\host\\ipconfig-allcompartments.txt") {
				foundHostDir = true
			}
		}
		Expect(foundSetupJson).To(BeTrue(), "setup.json not found in config folder of dump zip")
		Expect(foundClusterDir).To(BeTrue(), "cluster folder not found in dump zip")
		Expect(foundHostDir).To(BeTrue(), "host folder not found in dump zip")
	})
})
