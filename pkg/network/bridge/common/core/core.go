// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package core

import (
	"base/logging"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Microsoft/go-winio/pkg/etwlogrus"
	"github.com/Microsoft/windows-container-networking/cni"
	"github.com/Microsoft/windows-container-networking/common"
	"github.com/sirupsen/logrus"
)

// Version is populated by make during build.
var version string

// The entry point for CNI network plugin.
func Core() {

	// environment arg values
	containerID := os.Getenv("CNI_CONTAINERID")
	argsPlugin := os.Getenv("CNI_ARGS")
	argsCmd := os.Getenv("CNI_COMMAND")
	allPlugins := strings.Split(argsPlugin, ";")
	var podName string
	for _, v := range allPlugins {
		var value string
		n, err := fmt.Sscanf(v, "K8S_POD_NAME=%s", &value)
		if err == nil && n > 0 {
			podName = value
		}
	}

	// take pod name if exists
	var logFileName string
	if len(podName) == 0 {
		logFileName = "bridge-" + containerID
	} else {
		logFileName = "bridge-" + podName + "-" + argsCmd
	}

	var config common.PluginConfig
	config.Version = version

	// Provider ID: {c822b598-f4cc-5a72-7933-ce2a816d033f}
	if hook, err := etwlogrus.NewHook(logFileName); err == nil {
		logrus.AddHook(hook)
	}

	logDir := determineLogDir()
	if err := os.MkdirAll(logDir, os.ModePerm); err != nil {
		logrus.Println(err)
		os.Exit(1)
	}

	// logrus.SetFormatter(&logrus.JSONFormatter{})
	// logrus.SetFormatter(&logrus.JSONFormatter{})
	logrus.SetFormatter(&logrus.TextFormatter{
		DisableColors: true,
		FullTimestamp: true,
	})

	logrus.SetLevel(logrus.DebugLevel)
	filename := filepath.Join(logDir, logFileName+".log")
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY, os.FileMode(0777))
	if err != nil {
		logrus.Println("OpenFile " + logFileName + " error")
		os.Exit(1)
	}
	logrus.SetOutput(file)
	defer file.Close()

	// print all arguments
	logrus.Println("PLUGIN ENVIRONMENT:")
	logrus.Println("   CNI_COMMAND: ", argsCmd)
	logrus.Println("   CNI_CONTAINERID: ", containerID)
	logrus.Println("   CNI_NETNS: ", os.Getenv("CNI_NETNS"))
	logrus.Println("   CNI_IFNAME: ", os.Getenv("CNI_IFNAME"))
	logrus.Println("   CNI_ARGS: ", argsPlugin)
	logrus.Println("   CNI_PATH: ", os.Getenv("CNI_PATH"))
	logrus.Println("   LOG FILE: ", filename)

	netPlugin, err := NewPlugin(&config)
	if err != nil {
		logrus.Errorf("Failed to create network plugin, err:%v", err)
		os.Exit(1)
	}

	err = netPlugin.Start(&config)
	if err != nil {
		logrus.Errorf("Failed to start network plugin, err:%v.\n", err)
		os.Exit(1)
	}

	err = netPlugin.Execute(cni.PluginApi(netPlugin))

	netPlugin.Stop()

	if err != nil {
		logrus.Errorf("Failed to Execute network plugin, err:%v.\n", err)
		os.Exit(1)
	}

	// remove older files
	oldfiles, erroldfiles := findFilesOlderThanOneDay(logDir)
	if erroldfiles == nil {
		for _, filetodelete := range oldfiles {
			logrus.Debug("Delete file:", filetodelete.Name())
			os.Remove(filepath.Join(logDir, filetodelete.Name()))
		}
	}
}

func isOlderThanOneDay(t time.Time) bool {
	return time.Now().Sub(t) > 24*time.Hour
}

func findFilesOlderThanOneDay(dir string) (files []os.FileInfo, err error) {
	tmpfiles, err := ioutil.ReadDir(dir)
	if err != nil {
		return
	}
	for _, file := range tmpfiles {
		if file.Mode().IsRegular() {
			if isOlderThanOneDay(file.ModTime()) {
				files = append(files, file)
			}
		}
	}
	return
}

func determineLogDir() string {
	return filepath.Join(logging.RootLogDir(), "bridge")
}
