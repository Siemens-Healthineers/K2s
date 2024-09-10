// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package framework

import (
	"context"
	"fmt"
	"path"
	"reflect"
	"time"

	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	"github.com/siemens-healthineers/k2s/test/framework/k8s"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

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
	offlineMode          bool
	initialSystemState   initialSystemStateType
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
	cli                  *sos.CliExecutor
	k2sCli               *k2s.K2sCliRunner
	setupInfo            *k2s.SetupInfo
	kubeProxyRestarter   *k2s.KubeProxyRestarter
	kubectl              *k8s.Kubectl
	cluster              *k8s.Cluster
	addonsAdditionalInfo *k2s.AddonsAdditionalInfo
}
type ClusterTestStepTimeout time.Duration
type ClusterTestStepPollInterval time.Duration

type initialSystemStateType string
type restartKubeProxyType bool
type ensureAddonsAreDisabledType bool
type noSetupInstalledType bool

const (
	RestartKubeProxy        = restartKubeProxyType(true)
	EnsureAddonsAreDisabled = ensureAddonsAreDisabledType(true)
	NoSetupInstalled        = noSetupInstalledType(true)

	SystemMustBeStopped   initialSystemStateType = "stopped"
	SystemMustBeRunning   initialSystemStateType = "running"
	SystemStateIrrelevant initialSystemStateType = "irrelevant"
)

func Setup(ctx context.Context, args ...any) *K2sTestSuite {
	proxy := determineProxy()
	offlineMode := determineOfflineMode()
	testStepTimeout := determineTestStepTimeout()
	testStepPollInterval := determineTestStepPollInterval()

	ensureAddonsAreDisabled := false
	clusterTestStepTimeout := testStepTimeout
	clusterTestStepPollInterval := testStepPollInterval
	noSetupInstalled := false
	initialSystemState := SystemStateIrrelevant

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
		case t == reflect.TypeOf(SystemStateIrrelevant):
			initialSystemState = arg.(initialSystemStateType)
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	rootDir := determineRootDir()
	cliPath := path.Join(rootDir, "k2s.exe")

	cli := sos.NewCli(proxy, clusterTestStepTimeout, clusterTestStepPollInterval)

	k2sCli := k2s.NewCli(cliPath, cli)

	addonsAdditionalInfo := k2s.NewAddonsAdditionalInfo()

	testSuite := &K2sTestSuite{
		proxy:                proxy,
		rootDir:              rootDir,
		setupInstalled:       !noSetupInstalled,
		offlineMode:          offlineMode,
		initialSystemState:   initialSystemState,
		testStepTimeout:      clusterTestStepTimeout,
		testStepPollInterval: clusterTestStepPollInterval,
		cli:                  cli,
		k2sCli:               k2sCli,
		addonsAdditionalInfo: addonsAdditionalInfo,
	}

	if noSetupInstalled {
		GinkgoWriter.Println("Test Suite configured for runs without K2s being installed")

		return testSuite
	}

	GinkgoWriter.Println("Initial system state should be <", initialSystemState, ">")

	if initialSystemState == SystemStateIrrelevant {
		GinkgoWriter.Println("Skipping system state checks")
	} else {
		expectSystemState(ctx, initialSystemState, k2sCli, ensureAddonsAreDisabled)
	}

	info := loadSetupInfo(rootDir)

	testSuite.setupInfo = info
	testSuite.kubeProxyRestarter = k2s.NewKubeProxyRestarter(rootDir, info.SetupConfig, cli, *k2sCli)
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

	if restartKubeProxy && s.setupInstalled && s.initialSystemState == SystemMustBeRunning {
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

func (s *K2sTestSuite) IsOfflineMode() bool {
	return s.offlineMode
}

func (s *K2sTestSuite) RootDir() string {
	return s.rootDir
}

// OS cli for arbitrary executions
func (s *K2sTestSuite) Cli() *sos.CliExecutor {
	Expect(s.cli).ToNot(BeNil())
	return s.cli
}

// convenience wrapper around k2s.exe
func (s *K2sTestSuite) K2sCli() *k2s.K2sCliRunner {
	Expect(s.k2sCli).ToNot(BeNil())
	return s.k2sCli
}

func (s *K2sTestSuite) SetupInfo() *k2s.SetupInfo {
	Expect(s.setupInfo).ToNot(BeNil())
	return s.setupInfo
}

func (s *K2sTestSuite) AddonsAdditionalInfo() *k2s.AddonsAdditionalInfo {
	Expect(s.addonsAdditionalInfo).ToNot(BeNil())
	return s.addonsAdditionalInfo
}

func (s *K2sTestSuite) Kubectl() *k8s.Kubectl {
	Expect(s.kubectl).ToNot(BeNil())
	return s.kubectl
}

func (s *K2sTestSuite) Cluster() *k8s.Cluster {
	Expect(s.cluster).ToNot(BeNil())
	return s.cluster
}

func loadSetupInfo(rootDir string) *k2s.SetupInfo {
	info, err := k2s.GetSetupInfo(rootDir)

	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("Found setup type <", info.SetupConfig.SetupName, "( Linux-only:", info.SetupConfig.LinuxOnly, ") > in dir <", rootDir, ">")

	if info.SetupConfig.SetupName != setupinfo.SetupNamek2s && info.SetupConfig.SetupName != setupinfo.SetupNameMultiVMK8s {
		Fail(fmt.Sprintf("Unsupported setup type detected: '%s'", info.SetupConfig.SetupName))
	}

	return info
}

func expectSystemState(ctx context.Context, initialSystemState initialSystemStateType, k2sCli *k2s.K2sCliRunner, ensureAddonsAreDisabled bool) {
	GinkgoWriter.Println("Checking system status..")

	status := k2sCli.GetStatus(ctx)
	isRunning := status.IsClusterRunning()

	switch initialSystemState {
	case SystemMustBeRunning:
		Expect(isRunning).To(BeTrue(), "System should be running to execute the tests")
		GinkgoWriter.Println("System is running")
	case SystemMustBeStopped:
		Expect(isRunning).To(BeFalse(), "System should be stopped to execute the tests")
		GinkgoWriter.Println("System is stopped")
	default:
		Fail(fmt.Sprintf("invalid initial system state: '%s'", initialSystemState))
	}

	addonsStatus := k2sCli.GetAddonsStatus(ctx)
	if ensureAddonsAreDisabled {
		expectAddonsToBeDisabled(addonsStatus)
	}
}

func expectAddonsToBeDisabled(addonsStatus *k2s.AddonsStatus) {
	Expect(addonsStatus.GetEnabledAddons()).To(BeEmpty(), "All addons should be disabled to execute the tests")

	GinkgoWriter.Println("All addons are disabled")
}

func determineRootDir() string {
	rootDir, err := sos.RootDir()

	Expect(err).ToNot(HaveOccurred())

	return rootDir
}
