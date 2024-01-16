// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package framework

import (
	"context"
	"fmt"
	"reflect"
	"k2sTest/framework/k8s"
	sos "k2sTest/framework/os"
	"k2sTest/framework/k2s"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

type k2sTestSuite struct {
	proxy                string
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
	cli                  *sos.CliExecutor
	k2sCli          *k2s.k2sCliRunner
	setupInfo            *k2s.SetupInfo
	kubeProxyRestarter   *k2s.KubeProxyRestarter
	kubectl              *k8s.Kubectl
	cluster              *k8s.Cluster
}
type ClusterTestStepTimeout time.Duration
type ClusterTestStepPollInterval time.Duration

type restartKubeProxyType bool
type ensureAddonsAreDisabledType bool

const (
	RestartKubeProxy        = restartKubeProxyType(true)
	EnsureAddonsAreDisabled = ensureAddonsAreDisabledType(true)
)

func Setup(ctx context.Context, args ...any) *k2sTestSuite {
	proxy := determineProxy()
	testStepTimeout := determineTestStepTimeout()
	testStepPollInterval := determineTestStepPollInterval()

	ensureAddonsAreDisabled := false
	clusterTestStepTimeout := testStepTimeout
	clusterTestStepPollInterval := testStepPollInterval

	for _, arg := range args {
		switch t := reflect.TypeOf(arg); {
		case t == reflect.TypeOf(EnsureAddonsAreDisabled):
			ensureAddonsAreDisabled = bool(arg.(ensureAddonsAreDisabledType))
		case t == reflect.TypeOf(ClusterTestStepTimeout(0)):
			clusterTestStepTimeout = time.Duration(arg.(ClusterTestStepTimeout))
		case t == reflect.TypeOf(ClusterTestStepPollInterval(0)):
			clusterTestStepPollInterval = time.Duration(arg.(ClusterTestStepPollInterval))
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	setupInfo := loadSetupInfo()
	cli := sos.NewCli(proxy, clusterTestStepTimeout, clusterTestStepPollInterval)
	k2sCli := k2s.NewCli(setupInfo.CliPath, cli)

	expectClusterToBeRunning(ctx, k2sCli, ensureAddonsAreDisabled)

	rootDir := determineRootDir()

	return &k2sTestSuite{
		proxy:                proxy,
		testStepTimeout:      clusterTestStepTimeout,
		testStepPollInterval: clusterTestStepPollInterval,
		cli:                  cli,
		k2sCli:          k2sCli,
		setupInfo:            setupInfo,
		kubeProxyRestarter:   k2s.NewKubeProxyRestarter(*setupInfo, cli, *k2sCli),
		kubectl:              k8s.NewCli(cli, rootDir),
		cluster:              k8s.NewCluster(clusterTestStepTimeout, clusterTestStepPollInterval),
	}
}

func (s *k2sTestSuite) TearDown(ctx context.Context, args ...any) {
	restartKubeProxy := false

	for _, arg := range args {
		switch t := reflect.TypeOf(arg); {
		case t == reflect.TypeOf(RestartKubeProxy):
			restartKubeProxy = bool(arg.(restartKubeProxyType))
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	if restartKubeProxy {
		s.kubeProxyRestarter.Restart(ctx)
	}

	GinkgoWriter.Println("Waiting for all started processes to die..")

	gexec.KillAndWait()

	GinkgoWriter.Println("All processes exited")
}

// how long to wait for the test step to complete
func (s *k2sTestSuite) TestStepTimeout() time.Duration {
	return s.testStepTimeout
}

// how long to wait before polling for the expected result check within the timeout period
func (s *k2sTestSuite) TestStepPollInterval() time.Duration {
	return s.testStepPollInterval
}

func (s *k2sTestSuite) Proxy() string {
	return s.proxy
}

// OS cli for arbitrary executions
func (s *k2sTestSuite) Cli() *sos.CliExecutor {
	return s.cli
}

// convenience wrapper around k2s.exe
func (s *k2sTestSuite) k2sCli() *k2s.k2sCliRunner {
	return s.k2sCli
}

func (s *k2sTestSuite) SetupInfo() *k2s.SetupInfo {
	return s.setupInfo
}

func (s *k2sTestSuite) Kubectl() *k8s.Kubectl {
	return s.kubectl
}

func (s *k2sTestSuite) Cluster() *k8s.Cluster {
	return s.cluster
}

func loadSetupInfo() *k2s.SetupInfo {
	setupInfo, err := k2s.GetSetupInfo()

	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("Found setup type <", setupInfo.SetupType.Name, "( Linux-only:", setupInfo.SetupType.LinuxOnly, ") > in dir <", setupInfo.RootDir, ">")

	if setupInfo.SetupType.Name != "k2s" && setupInfo.SetupType.Name != "MultiVMK8s" {
		Fail(fmt.Sprintf("Unsupported setup type detected: '%s'", setupInfo.SetupType.Name))
	}

	return setupInfo
}

func expectClusterToBeRunning(ctx context.Context, k2sCli *k2s.k2sCliRunner, ensureAddonsAreDisabled bool) {
	GinkgoWriter.Println("Checking cluster status..")

	status := k2sCli.GetStatus(ctx)

	Expect(status.IsClusterRunning()).To(BeTrue(), "Cluster should be in Running State to execute the tests")

	GinkgoWriter.Println("Cluster is running")

	if ensureAddonsAreDisabled {
		expectAddonsToBeDisabled(status)
	}
}

func expectAddonsToBeDisabled(status *k2s.k2sStatus) {
	Expect(status.GetEnabledAddons()).To(BeEmpty(), "All addons should be disabled to execute the tests")

	GinkgoWriter.Println("All addons are disabled")
}

func determineRootDir() string {
	rootDir, err := sos.RootDir()

	Expect(err).ToNot(HaveOccurred())

	return rootDir
}
