// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package framework

import (
	"context"
	"crypto/tls"
	"fmt"
	"path"
	"path/filepath"
	"reflect"
	"time"

	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"
	"github.com/siemens-healthineers/k2s/test/framework/os"

	"github.com/siemens-healthineers/k2s/test/framework/k8s"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	"github.com/siemens-healthineers/k2s/test/framework/http"

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
	initialSystemState   expectedSystemStateType
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
	cliFunc              func(cliPath string) *os.CliExecutor
	k2sCliFunc           func() *os.CliExecutor
	setupInfo            *k2s.SetupInfo
	kubeProxyRestarter   *k2s.KubeProxyRestarter
	kubectlFunc          func() *os.CliExecutor
	cluster              *k8s.Cluster
	addonsAdditionalInfo *addons.AddonsAdditionalInfo
	newHttpClientFunc    func(tlsConfig ...*tls.Config) *http.ResilientHttpClient
	statusChecker        *k2s.StatusChecker
}
type ClusterTestStepTimeout time.Duration
type ClusterTestStepPollInterval time.Duration

type expectedSystemStateType string
type restartKubeProxyType bool
type ensureAddonsAreDisabledType bool
type noSetupInstalledType bool

const (
	RestartKubeProxy        = restartKubeProxyType(true)
	EnsureAddonsAreDisabled = ensureAddonsAreDisabledType(true)
	NoSetupInstalled        = noSetupInstalledType(true)

	// System is installed and stopped
	SystemMustBeStopped expectedSystemStateType = "stopped"
	// System is installed and running
	SystemMustBeRunning expectedSystemStateType = "running"
	// System is installed, but the state (started/stopped) does not matter
	SystemStateIrrelevant expectedSystemStateType = "irrelevant"
)

// Setup initializes the test suite and performs necessary pre-checks
func Setup(ctx context.Context, args ...any) *K2sTestSuite {
	proxy := determineProxy()
	offlineMode := determineOfflineMode()
	testStepTimeout := determineTestStepTimeout()
	testStepPollInterval := determineTestStepPollInterval()

	ensureAddonsAreDisabled := false
	clusterTestStepTimeout := testStepTimeout
	clusterTestStepPollInterval := testStepPollInterval
	noSetupInstalled := false
	expectedSystemState := SystemStateIrrelevant

	for _, arg := range args {
		switch t := reflect.TypeOf(arg); {
		case t == reflect.TypeFor[ensureAddonsAreDisabledType]():
			ensureAddonsAreDisabled = bool(arg.(ensureAddonsAreDisabledType))
		case t == reflect.TypeFor[ClusterTestStepTimeout]():
			clusterTestStepTimeout = time.Duration(arg.(ClusterTestStepTimeout))
		case t == reflect.TypeFor[ClusterTestStepPollInterval]():
			clusterTestStepPollInterval = time.Duration(arg.(ClusterTestStepPollInterval))
		case t == reflect.TypeFor[noSetupInstalledType]():
			noSetupInstalled = bool(arg.(noSetupInstalledType))
		case t == reflect.TypeFor[expectedSystemStateType]():
			expectedSystemState = arg.(expectedSystemStateType)
		default:
			Fail(fmt.Sprintf("type < %v > invalid as parameter for suite.Setup() method", t))
		}
	}

	newCliFunc := func(cliPath string) *os.CliExecutor {
		return os.NewCli(cliPath, proxy, clusterTestStepTimeout, clusterTestStepPollInterval)
	}

	newHttpClientFunc := func(tlsConfig ...*tls.Config) *http.ResilientHttpClient {
		return http.NewResilientHttpClient(clusterTestStepTimeout, tlsConfig...)
	}

	rootDir := determineRootDir()

	k2sCliFunc := func() *os.CliExecutor {
		return newCliFunc(filepath.Join(rootDir, "k2s.exe"))
	}
	setupInfo := k2s.CreateSetupInfo(rootDir)

	testSuite := &K2sTestSuite{
		proxy:                proxy,
		rootDir:              rootDir,
		setupInstalled:       !noSetupInstalled,
		offlineMode:          offlineMode,
		initialSystemState:   expectedSystemState,
		testStepTimeout:      clusterTestStepTimeout,
		testStepPollInterval: clusterTestStepPollInterval,
		cliFunc:              newCliFunc,
		k2sCliFunc:           k2sCliFunc,
		addonsAdditionalInfo: addons.NewAddonsAdditionalInfo(),
		setupInfo:            setupInfo,
		newHttpClientFunc:    newHttpClientFunc,
		statusChecker:        k2s.NewStatusChecker(newCliFunc, setupInfo),
	}

	if noSetupInstalled {
		GinkgoWriter.Println("Test Suite configured for runs without K2s being installed")
		return testSuite
	}

	testSuite.setupInfo.ReloadRuntimeConfig()

	GinkgoWriter.Println("Found setup type <", testSuite.setupInfo.RuntimeConfig.InstallConfig().SetupName(), "( Linux-only:", testSuite.setupInfo.RuntimeConfig.InstallConfig().LinuxOnly(), ") > in dir <", rootDir, ">")

	if testSuite.setupInfo.RuntimeConfig.InstallConfig().SetupName() != definitions.SetupNameK2s {
		Fail(fmt.Sprintf("Unsupported setup type detected: '%s'", testSuite.setupInfo.RuntimeConfig.InstallConfig().SetupName()))
	}

	GinkgoWriter.Println("Initial system state should be <", expectedSystemState, ">")

	if expectedSystemState == SystemStateIrrelevant {
		GinkgoWriter.Println("Skipping system state checks")
	} else {
		testSuite.expectSystemState(ctx, expectedSystemState, ensureAddonsAreDisabled)
	}

	nssmCli := newCliFunc(filepath.Join(rootDir, "bin", "nssm.exe"))

	kubectlFunc := func() *os.CliExecutor {
		return newCliFunc(filepath.Join(rootDir, "bin", "kube", "kubectl.exe"))
	}

	testSuite.kubeProxyRestarter = k2s.NewKubeProxyRestarter(testSuite.setupInfo.RuntimeConfig, nssmCli)
	testSuite.kubectlFunc = kubectlFunc
	testSuite.cluster = k8s.NewCluster(clusterTestStepTimeout, clusterTestStepPollInterval)

	return testSuite
}

// TearDown performs necessary cleanup after test suite execution
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

// TestStepTimeout returns how long to wait for the test step to complete
func (s *K2sTestSuite) TestStepTimeout() time.Duration {
	return s.testStepTimeout
}

// TestStepPollInterval returns how long to wait before polling for the expected result check within the timeout period
func (s *K2sTestSuite) TestStepPollInterval() time.Duration {
	return s.testStepPollInterval
}

// Proxy returns the proxy URL configured for the test suite
func (s *K2sTestSuite) Proxy() string {
	return s.proxy
}

// IsOfflineMode indicates whether the test suite is running in offline mode
func (s *K2sTestSuite) IsOfflineMode() bool {
	return s.offlineMode
}

// RootDir returns the root directory of the K2s installation
func (s *K2sTestSuite) RootDir() string {
	return s.rootDir
}

// Cli creates a new CLI executor for the specified CLI path
func (s *K2sTestSuite) Cli(cliPath string) *os.CliExecutor {
	Expect(s.cliFunc).ToNot(BeNil())
	return s.cliFunc(cliPath)
}

// K2sCli creates a convenience wrapper around k2s.exe
func (s *K2sTestSuite) K2sCli() *os.CliExecutor {
	Expect(s.k2sCliFunc).ToNot(BeNil())
	return s.k2sCliFunc()
}

// SetupInfo returns the setup information of the K2s installation
func (s *K2sTestSuite) SetupInfo() *k2s.SetupInfo {
	Expect(s.setupInfo).ToNot(BeNil())
	return s.setupInfo
}

func (s *K2sTestSuite) AddonsAdditionalInfo() *addons.AddonsAdditionalInfo {
	Expect(s.addonsAdditionalInfo).ToNot(BeNil())
	return s.addonsAdditionalInfo
}

// Kubectl creates a convenience wrapper around kubectl.exe
func (s *K2sTestSuite) Kubectl() *os.CliExecutor {
	Expect(s.kubectlFunc).ToNot(BeNil())
	return s.kubectlFunc()
}

// Cluster returns the Kubernetes cluster associated with the test suite
func (s *K2sTestSuite) Cluster() *k8s.Cluster {
	Expect(s.cluster).ToNot(BeNil())
	return s.cluster
}

// HttpClient creates a new HTTP client with the specified TLS configuration
func (s *K2sTestSuite) HttpClient(tlsConfig ...*tls.Config) *http.ResilientHttpClient {
	Expect(s.newHttpClientFunc).ToNot(BeNil())
	return s.newHttpClientFunc(tlsConfig...)
}

// StatusChecker returns the status checker for the K2s system
func (s *K2sTestSuite) StatusChecker() *k2s.StatusChecker {
	Expect(s.statusChecker).ToNot(BeNil())
	return s.statusChecker
}

func (s *K2sTestSuite) expectSystemState(ctx context.Context, systemState expectedSystemStateType, ensureAddonsAreDisabled bool) {
	isRunning := s.statusChecker.IsK2sRunning(ctx)

	switch systemState {
	case SystemMustBeRunning:
		Expect(isRunning).To(BeTrue(), "System should be running to execute the tests")
	case SystemMustBeStopped:
		Expect(isRunning).To(BeFalse(), "System should be stopped to execute the tests")
	default:
		Fail(fmt.Sprintf("invalid expected system state: '%s'", systemState))
	}

	if ensureAddonsAreDisabled {
		Expect(s.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()).To(BeEmpty(), "All addons should be disabled to execute the tests")
		GinkgoWriter.Println("All addons are disabled")
	}
}

func determineRootDir() string {
	rootDir, err := os.RootDir()

	Expect(err).ToNot(HaveOccurred())

	return rootDir
}

func (s *K2sTestSuite) LogsDir() string {
	return path.Join("C:\\var\\log")
}
