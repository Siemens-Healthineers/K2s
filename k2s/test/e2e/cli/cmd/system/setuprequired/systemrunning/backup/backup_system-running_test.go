// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package systemrunning

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	backupFileName  = "k2s-backup.zip"
	backupJsonFile  = "backup.json"
	testDataContent = "test-data-for-integrity-check-12345"
)

var (
	suite          *framework.K2sTestSuite
	randomSeed     string
	testBackupDir  string
	testBackupFile string
)

func TestBackupSystemRunning(t *testing.T) {
 RegisterFailHandler(Fail)
 RunSpecs(t, "System Backup Acceptance Tests", Label("e2e", "system", "backup", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
 suite = framework.Setup(ctx,
  framework.SystemMustBeRunning,
  framework.ClusterTestStepPollInterval(time.Millisecond*200))
 randomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)
 testBackupDir = GinkgoT().TempDir()
})

var _ = AfterSuite(func(ctx context.Context) {
 suite.TearDown(ctx)
})

var _ = Describe("k2s system backup - basic functionality", Ordered, func() {
	BeforeAll(func() {
		testBackupFile = filepath.Join(testBackupDir, backupFileName)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, testBackupFile)
		})
	})

	It("creates backup successfully", func(ctx context.Context) {
		GinkgoWriter.Println("Creating system backup at:", testBackupFile)

		// Skip images to speed up test - image backup is tested separately
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", testBackupFile, "--skip-images")

		Expect(testBackupFile).To(BeAnExistingFile(), "Backup file should exist")
	})

	It("verifies backup contains backup.json", func(ctx context.Context) {
		zipReader, err := zip.OpenReader(testBackupFile)
		Expect(err).NotTo(HaveOccurred(), "Should open backup archive")
		defer zipReader.Close()

		foundBackupJson := false
		for _, file := range zipReader.File {
			if file.Name == backupJsonFile {
				foundBackupJson = true
				break
			}
		}

		Expect(foundBackupJson).To(BeTrue(), "backup.json should exist in archive")
	})
})

var _ = Describe("k2s system backup - persistent volumes", Ordered, Label("pv"), func() {
	var (
		testNamespace string
		pvBackupFile  string
		pvcName       string
		podName       string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-pv-backup-%s", randomSeed)
		pvBackupFile = filepath.Join(testBackupDir, fmt.Sprintf("backup-pv-%s.zip", randomSeed))

		// Create test namespace
		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, pvBackupFile)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true", "--timeout=60s")
		})
	})

	It("backs up user workload PVC with data and verifies PV directory exists", func(ctx context.Context) {
		pvcName = "test-user-pvc"
		podName = "test-writer-pod"
		pvName := fmt.Sprintf("test-backup-pv-%s", randomSeed)

		// Create PV first
		pvYaml := fmt.Sprintf(`
apiVersion: v1
kind: PersistentVolume
metadata:
  name: %s
spec:
  capacity:
    storage: 100Mi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /tmp/test-pv-data-%s
  claimRef:
    namespace: %s
    name: %s
`, pvName, randomSeed, testNamespace, pvcName)

		applyYaml(ctx, suite, pvYaml)

		// Cleanup PV at end
		DeferCleanup(func(ctx context.Context) {
			suite.Kubectl().Exec(ctx, "delete", "pv", pvName, "--ignore-not-found=true", "--wait=false")
		})

		// Create PVC that binds to the PV
		pvcYaml := fmt.Sprintf(`
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: %s
  namespace: %s
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: ""
  volumeName: %s
`, pvcName, testNamespace, pvName)

		applyYaml(ctx, suite, pvcYaml)

		// Wait for PVC to be bound with timeout
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pvc", pvcName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(60 * time.Second).WithPolling(2 * time.Second).Should(Equal("Bound"), "PVC should bind to PV")

		// Create pod that writes data
		podYaml := fmt.Sprintf(`
apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: %s
spec:
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sh", "-c", "echo '%s' > /data/testfile.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: %s
  restartPolicy: Never
`, podName, testNamespace, testDataContent, pvcName)

		applyYaml(ctx, suite, podYaml)

		// Wait for pod to be running with timeout
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "pod", podName, "-n", testNamespace, "-o", "jsonpath={.status.phase}")
			return output
		}).WithContext(ctx).WithTimeout(120 * time.Second).WithPolling(2 * time.Second).Should(Equal("Running"))

		// Wait for data to be written
		time.Sleep(5 * time.Second)

		// Create backup (skip images for speed - testing PV backup, not images)
		GinkgoWriter.Println("Creating backup with PVC data at:", pvBackupFile)
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", pvBackupFile, "--skip-images")
		Expect(pvBackupFile).To(BeAnExistingFile())

		// Verify backup contains PV data
		zipReader, err := zip.OpenReader(pvBackupFile)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundPVDir := false
		for _, file := range zipReader.File {
			// Normalize path separators - zip uses forward slashes but Windows may use backslashes
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.HasPrefix(normalizedName, "pv/") {
				foundPVDir = true
				GinkgoWriter.Printf("Found PV file in backup: %s\n", file.Name)
				break
			}
		}

		Expect(foundPVDir).To(BeTrue(), "Backup should contain pv/ directory")
	})
})

var _ = Describe("k2s system backup - container images", Ordered, Label("images"), func() {
	var (
		testNamespace  string
		imgBackupFile  string
		testDeployment string
	)

	BeforeAll(func(ctx context.Context) {
		testNamespace = fmt.Sprintf("test-img-backup-%s", randomSeed)
		imgBackupFile = filepath.Join(testBackupDir, fmt.Sprintf("backup-img-%s.zip", randomSeed))

		suite.Kubectl().MustExec(ctx, "create", "namespace", testNamespace)

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, imgBackupFile)
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found=true")
		})
	})

	It("backs up user workload images and verifies images directory exists", func(ctx context.Context) {
		testDeployment = "test-image-deployment"

		deployYaml := fmt.Sprintf(`
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-img
  template:
    metadata:
      labels:
        app: test-img
    spec:
      containers:
      - name: test
        image: busybox:1.36
        command: ["sleep", "3600"]
`, testDeployment, testNamespace)

		// Apply the deployment
		applyYaml(ctx, suite, deployYaml)

		// Wait for deployment to be available
		Eventually(func(ctx context.Context) string {
			output, _ := suite.Kubectl().Exec(ctx, "get", "deployment", testDeployment, "-n", testNamespace, "-o", "jsonpath={.status.conditions[?(@.type=='Available')].status}")
			return output
		}).WithContext(ctx).WithTimeout(2 * time.Minute).WithPolling(2 * time.Second).Should(Equal("True"))

		// Create backup with images
		GinkgoWriter.Println("Creating backup with user images at:", imgBackupFile)
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", imgBackupFile)
		Expect(imgBackupFile).To(BeAnExistingFile())

		// Verify backup contains image metadata
		zipReader, err := zip.OpenReader(imgBackupFile)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundImagesDir := false
		for _, file := range zipReader.File {
			// Normalize path separators
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.HasPrefix(normalizedName, "images/") {
				foundImagesDir = true
				GinkgoWriter.Printf("Found image file in backup: %s\n", file.Name)
				break
			}
		}

		Expect(foundImagesDir).To(BeTrue(), "Backup should contain images/ directory")
	})
})

var _ = Describe("k2s system backup - negative scenarios", Ordered, Label("negative"), func() {
	It("fails gracefully when backup file path is invalid", func(ctx context.Context) {
		invalidPath := "/nonexistent/deeply/nested/invalid/path/backup.zip"

		output, exitCode := suite.K2sCli().Exec(ctx, "system", "backup", "-f", invalidPath)

		Expect(exitCode).NotTo(Equal(0), "Should fail with invalid path")
		Expect(output).To(Or(
			ContainSubstring("error"),
			ContainSubstring("failed"),
			ContainSubstring("cannot"),
		))
	})

	It("handles backup when cluster has no user workloads", func(ctx context.Context) {
		emptyBackupFile := filepath.Join(testBackupDir, fmt.Sprintf("backup-empty-%s.zip", randomSeed))

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, emptyBackupFile)
		})

		// Skip images/PVs for speed - testing empty cluster handling
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", emptyBackupFile, "--skip-images", "--skip-pvs")
		Expect(emptyBackupFile).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(emptyBackupFile)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		foundBackupJson := false
		for _, file := range zipReader.File {
			if file.Name == backupJsonFile {
				foundBackupJson = true
				break
			}
		}
		Expect(foundBackupJson).To(BeTrue())
	})
})

var _ = Describe("k2s system backup - selective content", Ordered, Label("flags"), func() {
	It("skips images when --skip-images flag is used", func(ctx context.Context) {
		skipImgBackup := filepath.Join(testBackupDir, fmt.Sprintf("backup-skip-img-%s.zip", randomSeed))

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, skipImgBackup)
		})

		// Also skip PVs to speed up test - we're only testing image skip functionality
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", skipImgBackup, "--skip-images=true", "--skip-pvs=true")
		Expect(skipImgBackup).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(skipImgBackup)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		hasImageManifest := false
		for _, file := range zipReader.File {
			// Normalize path separators
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if normalizedName == "images/manifest.json" {
				hasImageManifest = true
				break
			}
		}

		Expect(hasImageManifest).To(BeFalse(), "Image manifest should not be present when --skip-images is used")
	})

	It("skips PVs when --skip-pvs flag is used", func(ctx context.Context) {
		skipPvBackup := filepath.Join(testBackupDir, fmt.Sprintf("backup-skip-pv-%s.zip", randomSeed))

		DeferCleanup(func(ctx context.Context) {
			cleanupBackupFile(ctx, skipPvBackup)
		})

		// Also skip images to speed up test - we're only testing PV skip functionality
		suite.K2sCli().MustExec(ctx, "system", "backup", "-f", skipPvBackup, "--skip-pvs=true", "--skip-images=true")
		Expect(skipPvBackup).To(BeAnExistingFile())

		zipReader, err := zip.OpenReader(skipPvBackup)
		Expect(err).NotTo(HaveOccurred())
		defer zipReader.Close()

		hasPvDir := false
		for _, file := range zipReader.File {
			// Normalize path separators
			normalizedName := strings.ReplaceAll(file.Name, "\\", "/")
			if strings.HasPrefix(normalizedName, "pv/") {
				hasPvDir = true
				break
			}
		}

		Expect(hasPvDir).To(BeFalse(), "PV directory should not be present when --skip-pvs is used")
	})
})

func cleanupBackupFile(ctx context.Context, backupFile string) {
	if _, err := os.Stat(backupFile); err == nil {
		os.Remove(backupFile)
		GinkgoWriter.Println("Cleaned up backup file:", backupFile)
	}
}

func applyYaml(ctx context.Context, suite *framework.K2sTestSuite, yaml string) {
	tmpFile, err := os.CreateTemp("", "k2s-test-*.yaml")
	Expect(err).NotTo(HaveOccurred())
	defer os.Remove(tmpFile.Name())

	_, err = tmpFile.WriteString(yaml)
	Expect(err).NotTo(HaveOccurred())
	tmpFile.Close()

	suite.Kubectl().MustExec(ctx, "apply", "-f", tmpFile.Name())
}

