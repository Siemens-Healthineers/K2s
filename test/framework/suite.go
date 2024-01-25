// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package framework

import (
	"context"
	"fmt"
	"k2s/setupinfo"
	"k2sTest/framework/k2s"
	"k2sTest/framework/k8s"
	sos "k2sTest/framework/os"
	"path"
	"reflect"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

type K2sTestSuite struct {
	proxy                string
	rootDir              string
	setupInstalled       bool
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
	cli                  *sos.CliExecutor
	k2sCli               *k2s.K2sCliRunner
	setupInfo            *k2s.SetupInfo
	kubeProxyRestarter   *k2s.KubeProxyRestarter
	kubectl              *k8s.Kubectl
	cluster              *k8s.Cluster
}
type ClusterTestStepTimeout time.Duration
type ClusterTestStepPollInterval time.Duration

type restartKubeProxyType bool
type ensureAddonsAreDisabledType bool
type noSetupInstalledType bool
type skipClusterRunningCheckType bool

const (
	RestartKubeProxy        = restartKubeProxyType(true)
	EnsureAddonsAreDisabled = ensureAddonsAreDisabledType(true)
	NoSetupInstalled        = noSetupInstalledType(true)
	SkipClusterRunningCheck = skipClusterRunningCheckType(true)
)

func Setup(ctx context.Context, args ...any) *K2sTestSuite {
	proxy := determineProxy()
	testStepTimeout := determineTestStepTimeout()
	testStepPollInterval := determineTestStepPollInterval()

	ensureAddonsAreDisabled := false
	clusterTestStepTimeout := testStepTimeout
	clusterTestStepPollInterval := testStepPollInterval
	noSetupInstalled := false
	skipClusterRunningCheck := false

	for _, arg := range args {
		switch t := reflect.TypeOf(arg); {
		case t == reflect.TypeOf(EnsureAddonsAreDisabled):
			ensureAddonsAreDisabled = bool(arg.(ensureAddonsAreDisabledType))
		case t == reflect.TypeOf(ClusterTestStepTimeout(0)):
			clusterTestStepTimeout = time.Duration(arg.(ClusterTestStepTimeout))
		case t == reflect.TypeOf(ClusterTestStepPollInterval(0)):
			clusterTestStepPollInterval = time.Duration(arg.(ClusterTestStepPollInterval))
		case t == reflect.TypeOf(NoSetupInstalled):
			noSetupInstalled = bool(arg.(noSetupInstalledType))
		case t == reflect.TypeOf(SkipClusterRunningCheck):
			skipClusterRunningCheck = bool(arg.(skipClusterRunningCheckType))
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	rootDir := determineRootDir()
	cliPath := path.Join(rootDir, "k2s.exe")

	cli := sos.NewCli(proxy, clusterTestStepTimeout, clusterTestStepPollInterval)

	k2sCli := k2s.NewCli(cliPath, cli)

	testSuite := &K2sTestSuite{
		proxy:                proxy,
		rootDir:              rootDir,
		setupInstalled:       !noSetupInstalled,
		testStepTimeout:      clusterTestStepTimeout,
		testStepPollInterval: clusterTestStepPollInterval,
		cli:                  cli,
		k2sCli:               k2sCli,
	}

	if noSetupInstalled {
		GinkgoWriter.Println("Test Suite configured for runs without K2s being installed")

		return testSuite
	}

	if skipClusterRunningCheck {
		GinkgoWriter.Println("skipping cluster running check")
	} else {
		expectClusterToBeRunning(ctx, k2sCli, ensureAddonsAreDisabled)
	}

	setupInfo := loadSetupInfo(rootDir)

	testSuite.setupInfo = setupInfo
	testSuite.kubeProxyRestarter = k2s.NewKubeProxyRestarter(rootDir, *setupInfo, cli, *k2sCli)
	testSuite.kubectl = k8s.NewCli(cli, rootDir)
	testSuite.cluster = k8s.NewCluster(clusterTestStepTimeout, clusterTestStepPollInterval)

	return testSuite
}

func (s *K2sTestSuite) TearDown(ctx context.Context, args ...any) {
	restartKubeProxy := false

	for _, arg := range args {
		switch t := reflect.TypeOf(arg); {
		case t == reflect.TypeOf(RestartKubeProxy):
			restartKubeProxy = bool(arg.(restartKubeProxyType))
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	if restartKubeProxy && s.setupInstalled {
		s.kubeProxyRestarter.Restart(ctx)
	}

	GinkgoWriter.Println("Waiting for all started processes to die..")

	gexec.KillAndWait()

	GinkgoWriter.Println("All processes exited")
}

// how long to wait for the test step to complete
func (s *K2sTestSuite) TestStepTimeout() time.Duration {
	return s.testStepTimeout
}

// how long to wait before polling for the expected result check within the timeout period
func (s *K2sTestSuite) TestStepPollInterval() time.Duration {
	return s.testStepPollInterval
}

func (s *K2sTestSuite) Proxy() string {
	return s.proxy
}

func (s *K2sTestSuite) RootDir() string {
	return s.rootDir
}

// OS cli for arbitrary executions
func (s *K2sTestSuite) Cli() *sos.CliExecutor {
	return s.cli
}

// convenience wrapper around k2s.exe
func (s *K2sTestSuite) K2sCli() *k2s.K2sCliRunner {
	return s.k2sCli
}

func (s *K2sTestSuite) SetupInfo() *k2s.SetupInfo {
	return s.setupInfo
}

func (s *K2sTestSuite) Kubectl() *k8s.Kubectl {
	return s.kubectl
}

func (s *K2sTestSuite) Cluster() *k8s.Cluster {
	return s.cluster
}

func loadSetupInfo(rootDir string) *k2s.SetupInfo {
	info, err := k2s.GetSetupInfo(rootDir)

	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("Found setup type <", info.Name, "( Linux-only:", info.LinuxOnly, ") > in dir <", rootDir, ">")

	if info.Name != setupinfo.SetupNamek2s && info.Name != setupinfo.SetupNameMultiVMK8s {
		Fail(fmt.Sprintf("Unsupported setup type detected: '%s'", info.Name))
	}

	return info
}

func expectClusterToBeRunning(ctx context.Context, k2sCli *k2s.K2sCliRunner, ensureAddonsAreDisabled bool) {
	GinkgoWriter.Println("Checking cluster status..")

	status := k2sCli.GetStatus(ctx)

	Expect(status.IsClusterRunning()).To(BeTrue(), "Cluster should be in Running State to execute the tests")

	GinkgoWriter.Println("Cluster is running")

	if ensureAddonsAreDisabled {
		expectAddonsToBeDisabled(status)
	}
}

func expectAddonsToBeDisabled(status *k2s.K2sStatus) {
	Expect(status.GetEnabledAddons()).To(BeEmpty(), "All addons should be disabled to execute the tests")

	GinkgoWriter.Println("All addons are disabled")
}

func determineRootDir() string {
	rootDir, err := sos.RootDir()

	Expect(err).ToNot(HaveOccurred())

	return rootDir
}
