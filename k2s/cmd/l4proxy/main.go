package main

import (
	"context"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"time"

	cn "github.com/siemens-healthineers/k2s/internal/containernetworking"
	"github.com/siemens-healthineers/k2s/internal/logging"
	kos "github.com/siemens-healthineers/k2s/internal/os"
	ve "github.com/siemens-healthineers/k2s/internal/version"
	"github.com/sirupsen/logrus"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const cliName = "l4proxy"

func printCLIVersion() {
	version := ve.GetVersion()
	fmt.Printf("%s: %s\n", cliName, version)

	fmt.Printf("  BuildDate: %s\n", version.BuildDate)
	fmt.Printf("  GitCommit: %s\n", version.GitCommit)
	fmt.Printf("  GitTreeState: %s\n", version.GitTreeState)
	if version.GitTag != "" {
		fmt.Printf("  GitTag: %s\n", version.GitTag)
	}
	fmt.Printf("  GoVersion: %s\n", version.GoVersion)
	fmt.Printf("  Compiler: %s\n", version.Compiler)
	fmt.Printf("  Platform: %s\n", version.Platform)
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

func main() {
	// parse the flags
	var podname string = ""
	var namespace string = ""
	var endpointid string = ""
	version := flag.Bool("version", false, "show the current version of the CLI")
	flag.StringVar(&podname, "podname", podname, "podname of the running pod")
	flag.StringVar(&namespace, "namespace", namespace, "namespace of the running pod")
	flag.StringVar(&endpointid, "endpointid", endpointid, "endpointid of the running pod")
	flag.Parse()
	if *version {
		// print help
		printCLIVersion()
		os.Exit(0)
	}

	// check podname and namespace
	if podname == "" || namespace == "" || endpointid == "" {
		flag.PrintDefaults()
		os.Exit(0)
	}

	fmt.Printf("l4proxy started, checking if linkerd annotation is set for pod '%s' in namespace '%s'\n", podname, namespace)

	// set logging
	logrus.SetFormatter(&logrus.TextFormatter{
		DisableColors: true,
		FullTimestamp: true,
	})
	logrus.SetLevel(logrus.DebugLevel)
	logDir := filepath.Join(logging.RootLogDir(), "l4proxy")
	logFilePath := filepath.Join(logDir, "l4proxy-"+podname+"-"+namespace+".log")
	if kos.PathExists(logFilePath) {
		if err := os.Remove(logFilePath); err != nil {
			log.Fatalf("cannot remove log file '%s': %s", logFilePath, err)
		}
	}
	logFile := logging.InitializeLogFile(logFilePath)
	defer logFile.Close()
	logrus.SetOutput(logFile)

	// first log entry
	logrus.Debug("l4proxy started for podname:", podname, "namespace:", namespace)
	logrus.Debug("l4proxy logs in:", logFilePath)

	// dump current account under which process is running
	currentUser, err := user.Current()
	if err == nil {
		fmt.Printf("current user: %s\n", currentUser.Username) // log the entry
	}

	// Path to the kubeconfig file
	kubeconfig := "C:\\Windows\\System32\\config\\systemprofile\\config"

	// Build config from the kubeconfig file
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client configuration: %v", err)
	}

	// Create Kubernetes clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes clientset: %v", err)
	}

	// Check if an annotation exists on the pod in a retry loop
	pod, err := getPodWithRetries(clientset, namespace, podname)
	if err != nil {
		log.Fatalf("Failed to retrieve pod: %v", err)
	}

	// Check if the annotation value is "enabled"
	if pod.Annotations["linkerd.io/inject"] == "enabled" {
		// log the entry
		logrus.Debug("l4proxy annotation 'linkerd.io/inject' is set for podname:", podname, "namespace:", namespace)
		log.Println("l4proxy annotation 'linkerd.io/inject' is set for podname:", podname, "namespace:", namespace)
	} else {
		// log the entry
		logrus.Debug("l4proxy annotation 'linkerd.io/inject' is not set for podname:", podname, "namespace:", namespace)
		log.Println("l4proxy annotation 'linkerd.io/inject' is not set for podname:", podname, "namespace:", namespace)
		logrus.Debug("Deleting L4 policies")
		cn.HnsProxyClearPolicies(endpointid)
	}

	// remove older files
	oldfiles, erroldfiles := findFilesOlderThanOneDay(logDir)
	if erroldfiles == nil {
		for _, filetodelete := range oldfiles {
			logrus.Debug("Delete file:", filetodelete.Name())
			os.Remove(filepath.Join(logDir, filetodelete.Name()))
		}
	}

	fmt.Printf("l4proxy finished, please checks logs in %s\n", logFilePath)
}

const (
	maxRetries    = 5
	retryInterval = 2 * time.Second
)

func getPodWithRetries(clientset *kubernetes.Clientset, namespace, podname string) (*v1.Pod, error) {
	var pod *v1.Pod
	var err error

	for i := 0; i < maxRetries; i++ {
		internalPod, internalErr := clientset.CoreV1().Pods(namespace).Get(context.Background(), podname, metav1.GetOptions{})
		if internalErr == nil {
			pod = internalPod // Assign to the outer 'pod' variable
			return pod, nil   // Success, return the pod
		}

		log.Printf("Failed to retrieve pod '%s' in namespace '%s' (attempt %d/%d): %v", podname, namespace, i+1, maxRetries, internalErr)
		if i < maxRetries-1 {
			log.Printf("Retrying in %v...", retryInterval)
			time.Sleep(retryInterval)
		}
		err = internalErr // Store the last error
	}

	log.Fatalf("Failed to retrieve pod '%s' in namespace '%s' after %d retries: %v", podname, namespace, maxRetries, err)
	return nil, err // Return the last error if all retries fail
}
