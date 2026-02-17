// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"

	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/siemens-healthineers/k2s/addons/controller"
)

var (
	version   = "dev"
	buildDate = "unknown"
	gitCommit = "unknown"
)

func main() {
	var (
		metricsAddr string
		probeAddr   string
		devMode     bool
		showVersion bool
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&devMode, "dev-mode", false, "Enable development mode (human-readable logs, stack traces).")
	flag.BoolVar(&showVersion, "version", false, "Print version information and exit.")
	flag.Parse()

	if showVersion {
		fmt.Printf("k2s-addon-controller %s (commit: %s, built: %s, go: %s)\n",
			version, gitCommit, buildDate, runtime.Version())
		os.Exit(0)
	}

	ctrl.SetLogger(zap.New(zap.UseDevMode(devMode)))

	log := ctrl.Log.WithName("addon-controller")
	log.Info("Starting K2s Addon Controller",
		"version", version,
		"commit", gitCommit,
		"buildDate", buildDate,
		"go", runtime.Version(),
		"os", runtime.GOOS,
		"arch", runtime.GOARCH,
	)

	if bi, ok := debug.ReadBuildInfo(); ok {
		log.Info("Build info", "module", bi.Main.Path, "goVersion", bi.GoVersion)
	}

	scheme := clientgoscheme.Scheme
	utilruntime.Must(controller.AddToScheme(scheme))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: probeAddr,
		Metrics: metricsserver.Options{
			BindAddress: metricsAddr,
		},
		// DaemonSet runs one pod per node, so leader election is not strictly needed.
		// If future deployment model changes to Deployment replicas, enable:
		//   LeaderElection:   true,
		//   LeaderElectionID: "k2s-addon-controller-leader",
	})
	if err != nil {
		log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	nodeType := "linux"
	if runtime.GOOS == "windows" {
		nodeType = "windows"
	}

	addonsPath := os.Getenv("ADDONS_PATH")
	if addonsPath == "" {
		addonsPath = controller.DefaultAddonsPath
	}

	nodeName := os.Getenv("NODE_NAME")
	log.Info("Controller configuration",
		"addonsPath", addonsPath,
		"nodeType", nodeType,
		"nodeName", nodeName,
		"metricsAddr", metricsAddr,
		"probeAddr", probeAddr,
	)

	reconciler := &controller.K2sAddonReconciler{
		Client:     mgr.GetClient(),
		Log:        log.WithName("reconciler"),
		Scheme:     mgr.GetScheme(),
		AddonsPath: addonsPath,
		NodeName:   nodeName,
		NodeType:   nodeType,
	}

	if err := reconciler.SetupWithManager(mgr); err != nil {
		log.Error(err, "unable to create controller")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	log.Info("Starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "problem running manager")
		os.Exit(1)
	}
}
