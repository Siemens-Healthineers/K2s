// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"bytes"
	"context"
	"os/exec"
	"time"
	"unsafe"
	"sync"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/logging"
	ve "github.com/siemens-healthineers/k2s/internal/version"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	kernel32                     = syscall.NewLazyDLL("kernel32.dll")
	procCreateProcessW           = kernel32.NewProc("CreateProcessW")
	procCreateRemoteThread       = kernel32.NewProc("CreateRemoteThread")
	procResumeThread             = kernel32.NewProc("ResumeThread")
	procVirtualAllocEx           = kernel32.NewProc("VirtualAllocEx")
	procWriteProcessMemory       = kernel32.NewProc("WriteProcessMemory")
	procGetExitCodeThread        = kernel32.NewProc("GetExitCodeThread")
	procCloseHandle              = kernel32.NewProc("CloseHandle")
	procLoadLibraryW             = kernel32.NewProc("LoadLibraryW")
	procCreateToolhelp32Snapshot = kernel32.NewProc("CreateToolhelp32Snapshot")
	procModule32FirstW           = kernel32.NewProc("Module32FirstW")
	procModule32NextW            = kernel32.NewProc("Module32NextW")
)

const (
	CREATE_SUSPENDED           = 0x00000004
	CREATE_UNICODE_ENVIRONMENT = 0x00000400
	MEM_COMMIT                 = 0x1000
	MEM_RESERVE                = 0x2000
	PAGE_READWRITE             = 0x04
	TH32CS_SNAPMODULE          = 0x00000008
	TH32CS_SNAPMODULE32        = 0x00000010
)

type startupInfo struct {
	Cb uint32
	_  [68]byte
}

type processInformation struct {
	Process   syscall.Handle
	Thread    syscall.Handle
	ProcessId uint32
	ThreadId  uint32
}

type moduleEntry32 struct {
	DwSize        uint32
	Th32ModuleID  uint32
	Th32ProcessID uint32
	GlblcntUsage  uint32
	ProccntUsage  uint32
	ModBaseAddr   uintptr
	ModBaseSize   uint32
	HModule       syscall.Handle
	SzModule      [256]uint16
	SzExePath     [260]uint16
}

func utf16Ptr(s string) *uint16 { p, _ := syscall.UTF16PtrFromString(s); return p }

// cliName used for version flag & logging prefixes (aligns with other small utilities e.g. vfprules)
const cliName = "cplauncher"

// cache for IP -> compartment lookups within a single execution
var (
	compCache   = map[string]int{}
	compCacheMu sync.RWMutex
)

func createSuspended(exe string, args []string) (processInformation, error) {
	var pi processInformation
	full, err := filepath.Abs(exe)
	if err != nil {
		return pi, err
	}
	if _, err = os.Stat(full); err != nil {
		return pi, fmt.Errorf("executable not found: %s", full)
	}
	cmdLine := fmt.Sprintf("\"%s\"", full)
	if len(args) > 0 {
		cmdLine += " " + strings.Join(args, " ")
	}
	si := startupInfo{Cb: uint32(unsafe.Sizeof(startupInfo{}))}
	r1, _, e1 := procCreateProcessW.Call(0, uintptr(unsafe.Pointer(utf16Ptr(full))), 0, 0, 0, CREATE_SUSPENDED|CREATE_UNICODE_ENVIRONMENT, 0, 0, uintptr(unsafe.Pointer(&si)), uintptr(unsafe.Pointer(&pi)))
	if r1 == 0 {
		return pi, fmt.Errorf("CreateProcessW failed: %v", e1)
	}
	return pi, nil
}

func allocWrite(h syscall.Handle, data []byte) (uintptr, error) {
	r1, _, e1 := procVirtualAllocEx.Call(uintptr(h), 0, uintptr(len(data)), MEM_RESERVE|MEM_COMMIT, PAGE_READWRITE)
	if r1 == 0 {
		return 0, fmt.Errorf("VirtualAllocEx: %v", e1)
	}
	var written uintptr
	r2, _, e2 := procWriteProcessMemory.Call(uintptr(h), r1, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), uintptr(unsafe.Pointer(&written)))
	if r2 == 0 || written != uintptr(len(data)) {
		return 0, fmt.Errorf("WriteProcessMemory: %v", e2)
	}
	return r1, nil
}

func injectDLL(h syscall.Handle, dll string) (uintptr, error) {
	abs, err := filepath.Abs(dll)
	if err != nil {
		return 0, err
	}
	if _, err = os.Stat(abs); err != nil {
		return 0, fmt.Errorf("dll not found: %s", abs)
	}
	u16, _ := syscall.UTF16FromString(abs)
	buf := make([]byte, len(u16)*2)
	for i, v := range u16 {
		buf[i*2] = byte(v)
		buf[i*2+1] = byte(v >> 8)
	}
	remoteStr, err := allocWrite(h, buf)
	if err != nil {
		return 0, err
	}
	hThread, _, e1 := procCreateRemoteThread.Call(uintptr(h), 0, 0, procLoadLibraryW.Addr(), remoteStr, 0, 0)
	if hThread == 0 {
		return 0, fmt.Errorf("CreateRemoteThread LoadLibraryW: %v", e1)
	}
	defer procCloseHandle.Call(hThread)
	syscall.WaitForSingleObject(syscall.Handle(hThread), syscall.INFINITE)
	var mod uintptr
	procGetExitCodeThread.Call(hThread, uintptr(unsafe.Pointer(&mod)))
	if mod == 0 {
		return 0, errors.New("LoadLibraryW returned NULL")
	}
	return mod, nil
}

func computeExportOffset(dllPath, export string) (uintptr, error) {
	h, err := syscall.LoadLibrary(dllPath)
	if err != nil {
		return 0, err
	}
	defer syscall.FreeLibrary(h)
	p, err := syscall.GetProcAddress(h, export)
	if err != nil {
		return 0, err
	}
	return uintptr(p) - uintptr(h), nil
}

func getModuleBase(pid uint32, module string) (uintptr, error) {
	snap, _, e1 := procCreateToolhelp32Snapshot.Call(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32, uintptr(pid))
	if snap == uintptr(syscall.InvalidHandle) {
		return 0, fmt.Errorf("snapshot: %v", e1)
	}
	defer procCloseHandle.Call(snap)
	var me moduleEntry32
	me.DwSize = uint32(unsafe.Sizeof(me))
	r, _, _ := procModule32FirstW.Call(snap, uintptr(unsafe.Pointer(&me)))
	if r == 0 {
		return 0, errors.New("Module32FirstW failed")
	}
	for {
		name := syscall.UTF16ToString(me.SzModule[:])
		if strings.EqualFold(name, module) {
			return me.ModBaseAddr, nil
		}
		r2, _, _ := procModule32NextW.Call(snap, uintptr(unsafe.Pointer(&me)))
		if r2 == 0 {
			break
		}
	}
	return 0, fmt.Errorf("module %s not found", module)
}

func callRemoteExport(h syscall.Handle, base, offset uintptr, compartment uint32) error {
	fn := base + offset
	hThread, _, e1 := procCreateRemoteThread.Call(uintptr(h), 0, 0, fn, uintptr(compartment), 0, 0)
	if hThread == 0 {
		return fmt.Errorf("CreateRemoteThread export: %v", e1)
	}
	defer procCloseHandle.Call(hThread)
	syscall.WaitForSingleObject(syscall.Handle(hThread), syscall.INFINITE)
	var code uint32
	procGetExitCodeThread.Call(hThread, uintptr(unsafe.Pointer(&code)))
	if code != 0 {
		return fmt.Errorf("remote SetTargetCompartmentId returned %d", code)
	}
	return nil
}

func createCompartmentIfNeeded(id uint32) error {
	iphlp := syscall.NewLazyDLL("iphlpapi.dll")
	proc := iphlp.NewProc("CreateNetworkCompartment")
	if err := iphlp.Load(); err != nil {
		return fmt.Errorf("load iphlpapi: %w", err)
	}
	if err := proc.Find(); err != nil {
		return nil
	}
	r1, _, e1 := proc.Call(uintptr(id))
	if r1 == 0 {
		return nil
	}
	if errno, ok := e1.(syscall.Errno); ok && errno == 183 {
		return nil
	}
	return fmt.Errorf("CreateNetworkCompartment failed: %v", e1)
}

func resume(pi processInformation) error {
	r, _, e := procResumeThread.Call(uintptr(pi.Thread))
	if int(r) == -1 {
		return fmt.Errorf("ResumeThread: %v", e)
	}
	return nil
}

func main() {
	var compartment uint
	var dll string
	var exportName string
	var selfEnv bool
	var noInject bool
	var envVarName string
	var dryRun bool
	var verbosity string
	var labelSelector string
	var namespace string
	var labelTimeoutStr string

	versionFlag := cli.NewVersionFlag(cliName)

	flag.UintVar(&compartment, "compartment", 0, "Compartment ID (required unless -label is used)")
	flag.StringVar(&dll, "dll", "", "Helper DLL path (optional if cphook.dll is beside the executable)")
	flag.StringVar(&exportName, "export", "SetTargetCompartmentId", "Export name of the compartment switching function inside the helper DLL")
	flag.BoolVar(&selfEnv, "self-env", false, "Only set environment variable (no remote SetCurrentThreadCompartmentId); target must self-set")
	flag.BoolVar(&noInject, "no-inject", false, "Skip DLL injection (use with -self-env)")
	flag.StringVar(&envVarName, "env-name", "COMPARTMENT_ID", "Environment variable name to pass compartment to target when using -self-env")
	flag.StringVar(&labelSelector, "label", "", "Kubernetes label selector to resolve a pod -> compartment (alternative to -compartment)")
	flag.StringVar(&namespace, "namespace", "", "Namespace scope for -label lookup (empty = all namespaces)")
	flag.StringVar(&labelTimeoutStr, "label-timeout", "10s", "Timeout for Kubernetes label resolution (e.g. 5s, 30s, 1m)")
	flag.BoolVar(&dryRun, "dry-run", false, "Show planned actions (compartment, dll resolution, target) without creating or modifying a process")
	flag.StringVar(&verbosity, cli.VerbosityFlagName, logging.LevelToLowerString(slog.LevelInfo), cli.VerbosityFlagHelp())
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	// Extract target command after -- (same pattern kept, but provide friendly usage like vfprules)
	var target []string
	for i, a := range os.Args {
		if a == "--" {
			target = os.Args[i+1:]
			break
		}
	}

	if (compartment == 0 && labelSelector == "") || len(target) == 0 {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s (-compartment <id> | -label <selector> [-namespace <ns>] [-label-timeout <dur>]) [-dll <dll>] [options] -- <exe> [args]\n", os.Args[0])
		flag.PrintDefaults()
		return
	}
	if compartment != 0 && labelSelector != "" {
		fmt.Fprintf(os.Stderr, "error: specify either -compartment or -label, not both\n")
		return
	}
	if namespace != "" && labelSelector == "" {
		fmt.Fprintf(os.Stderr, "error: -namespace provided without -label\n")
		return
	}

	// Setup structured file logging (one file per invocation, include timestamp for uniqueness)
	// Parse verbosity into a slog level prior to logger creation
	var levelVar slog.LevelVar
	levelVar.Set(slog.LevelInfo)
	if err := logging.SetVerbosity(verbosity, &levelVar); err != nil {
		fmt.Fprintf(os.Stderr, "invalid verbosity '%s': %v\n", verbosity, err)
		os.Exit(1)
	}

	logDir := filepath.Join(logging.RootLogDir(), cliName)
	logFileName := fmt.Sprintf("%s-%d-%d.log", cliName, os.Getpid(), time.Now().Unix())
	logFilePath := filepath.Join(logDir, logFileName)
	logFile, err := logging.SetupDefaultFileLogger(logDir, logFileName, levelVar.Level(), "component", cliName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to setup logger: %v\n", err)
		os.Exit(1)
	}
	defer logFile.Close()
	slog.Debug("logger initialized", "logFile", logFile.Name(), "compartment", compartment, "verbosity", verbosity)

	// Resolve default DLL if not provided and injection requested
	if dll == "" && !noInject {
		exePath, err := os.Executable()
		if err != nil {
			slog.Error("failed to determine executable path for default dll", "error", err)
		} else {
			candidate := filepath.Join(filepath.Dir(exePath), "cphook.dll")
			if _, statErr := os.Stat(candidate); statErr == nil {
				dll = candidate
				slog.Info("using default helper dll", "dll", dll)
			} else {
				slog.Error("dll not specified and default cphook.dll not found", "candidate", candidate)
				fmt.Fprintf(flag.CommandLine.Output(), "error: -dll not provided and default not found: %s\n", candidate)
				return
			}
		}
	} else if dll == "" && noInject {
		slog.Info("-dll not provided but -no-inject set; continuing without dll")
	}

	// If label selector provided, resolve compartment ID from pod IP before potential dry-run output
	var labelTimeout time.Duration
	if labelSelector != "" {
		var err error
		labelTimeout, err = time.ParseDuration(labelTimeoutStr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: invalid -label-timeout value '%s': %v\n", labelTimeoutStr, err)
			return
		}
		if labelTimeout <= 0 {
			fmt.Fprintf(os.Stderr, "error: -label-timeout must be > 0\n")
			return
		}
		resolvedComp, podIP, podName, ns, err := resolveCompartmentFromLabel(labelSelector, namespace, labelTimeout)
		if err != nil {
			slog.Error("failed to resolve compartment from label", "label", labelSelector, "error", err)
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			return
		}
		compartment = uint(resolvedComp)
		slog.Info("resolved compartment from pod label", "label", labelSelector, "compartment", compartment, "podIP", podIP, "pod", podName, "namespace", ns, "timeout", labelTimeout)
	}

	exe := target[0]
	args := target[1:]

	if dryRun {
			slog.Info("dry-run: planned execution", 
			"compartment", compartment,
			"dll", func() string { if dll == "" { return "(none / not needed)" } ; return dll }(),
			"export", exportName,
			"selfEnv", selfEnv,
			"noInject", noInject,
			"envVarName", envVarName,
			"label", labelSelector,
			"labelTimeout", labelTimeoutStr,
			"namespace", namespace,
			"targetExe", exe,
			"targetArgs", strings.Join(args, " "))
		// Show which env vars would be set
		if selfEnv {
			slog.Info("dry-run: would set environment variables", "COMPARTMENT_ID_ATTACH", fmt.Sprintf("%d", compartment), envVarName, fmt.Sprintf("%d", compartment))
		} else {
			slog.Info("dry-run: would set environment variable", "COMPARTMENT_ID_ATTACH", fmt.Sprintf("%d", compartment))
		}
		if !noInject {
			slog.Info("dry-run: would inject dll and call export (unless self-env suppresses export call)", "export", exportName)
		}
		slog.Info("dry-run complete; exiting without side effects", "logFile", logFilePath)
		fmt.Printf("cplauncher dry-run finished, log: %s\n", logFilePath)
		return
	}

	if err := createCompartmentIfNeeded(uint32(compartment)); err != nil {
		slog.Warn("compartment provisioning attempt failed or skipped", "error", err)
	}

	// Always set COMPARTMENT_ID_ATTACH so the DLL's DllMain can attempt per-thread switching
	os.Setenv("COMPARTMENT_ID_ATTACH", fmt.Sprintf("%d", compartment))
	slog.Info("set env", "name", "COMPARTMENT_ID_ATTACH", "value", compartment)

	if selfEnv {
		os.Setenv(envVarName, fmt.Sprintf("%d", compartment))
		slog.Info("set env", "name", envVarName, "value", compartment, "mode", "self-env")
	}
	pi, err := createSuspended(exe, args)
	if err != nil {
		slog.Error("create process failed", "error", err, "exe", exe)
		os.Exit(1)
	}
	defer procCloseHandle.Call(uintptr(pi.Process))
	defer procCloseHandle.Call(uintptr(pi.Thread))

	if !noInject {
		base, err := injectDLL(pi.Process, dll)
		if err != nil {
			slog.Error("dll injection failed", "error", err, "dll", dll)
			os.Exit(1)
		}
		offset, err := computeExportOffset(dll, exportName)
		if err != nil {
			slog.Error("compute export offset failed", "error", err, "export", exportName)
			os.Exit(1)
		}
		if enumBase, err2 := getModuleBase(pi.ProcessId, filepath.Base(dll)); err2 == nil {
			base = enumBase
			slog.Debug("module base enumerated", "base", fmt.Sprintf("0x%x", base))
		}
		if !selfEnv { // only attempt remote call if not deferring to target
			if err := callRemoteExport(pi.Process, base, offset, uint32(compartment)); err != nil {
				slog.Error("remote export call failed", "error", err, "compartment", compartment)
				os.Exit(1)
			} else {
				slog.Info("remote export invoked", "compartment", compartment)
			}
		} else {
			slog.Info("skipped remote export due to self-env", "export", exportName)
		}
	} else if !selfEnv {
		slog.Warn("-no-inject specified without -self-env; target main thread may remain in original compartment")
	}

	if !selfEnv {
		slog.Info("note: unless target sets compartment for its own network threads it stays in default compartment")
	}
	if err := resume(pi); err != nil {
		slog.Error("resume failed", "error", err)
		os.Exit(1)
	}
	finalDll := dll
	if noInject {
		if finalDll == "" { finalDll = "(no injection)" } else { finalDll += " (injection disabled)" }
	}
	slog.Info("done", "pid", pi.ProcessId, "dll", finalDll, "compartment", compartment, "selfEnv", selfEnv, "noInject", noInject, "logFile", logFilePath)
	fmt.Printf("cplauncher finished. pid=%d log=%s dll=%s\n", pi.ProcessId, logFilePath, finalDll)
}

// resolveCompartmentFromLabel locates a pod by label selector and maps its primary IP to a Windows network compartment ID.
// Strategy:
// 1. Build in-cluster style kubeconfig path (system profile) and query pods across all namespaces using the selector.
// 2. If multiple pods match, pick the first (future enhancement: allow index or fail if >1).
// 3. Use PowerShell / Get-NetIPInterface and Get-NetIPConfiguration to map the IP's interface alias to its CompartmentId.
func resolveCompartmentFromLabel(selector, namespace string, timeout time.Duration) (int, string, string, string, error) {
	kubeconfig := `C:\Windows\System32\config\systemprofile\config`
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return 0, "", "", "", fmt.Errorf("kubeconfig load: %w", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return 0, "", "", "", fmt.Errorf("kube client: %w", err)
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	listNs := namespace // empty means all
	pods, err := clientset.CoreV1().Pods(listNs).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return 0, "", "", "", fmt.Errorf("list pods: %w", err)
	}
	if len(pods.Items) == 0 {
		return 0, "", "", "", fmt.Errorf("no pods match label selector '%s'", selector)
	}
	if len(pods.Items) > 1 {
		return 0, "", "", "", fmt.Errorf("label selector '%s' matched %d pods (namespace='%s'); please refine with -namespace or a more specific selector", selector, len(pods.Items), namespace)
	}
	pod := pods.Items[0]
	if pod.Status.PodIP == "" {
		return 0, "", pod.Name, pod.Namespace, fmt.Errorf("pod '%s/%s' has no IP yet", pod.Namespace, pod.Name)
	}
	comp, err := compartmentFromIP(pod.Status.PodIP)
	if err != nil {
		return 0, pod.Status.PodIP, pod.Name, pod.Namespace, fmt.Errorf("map pod ip to compartment: %w", err)
	}
	return comp, pod.Status.PodIP, pod.Name, pod.Namespace, nil
}

// compartmentFromIP returns the compartment id for a given IP by querying PowerShell.
func compartmentFromIP(ip string) (int, error) {
	compCacheMu.RLock()
	if v, ok := compCache[ip]; ok {
		compCacheMu.RUnlock()
		return v, nil
	}
	compCacheMu.RUnlock()
	// Use PowerShell to find the interface alias for the IP then query its NetIPInterface for CompartmentId
	script := fmt.Sprintf(`$ip="%s"; $int=(Get-NetIPConfiguration | Where-Object { $_.IPv4Address.IPAddress -eq $ip }).InterfaceAlias; if(-not $int){ exit 99 }; $c=(Get-NetIPInterface -InterfaceAlias $int | Select-Object -First 1 -ExpandProperty CompartmentId); if(-not $c){ exit 98 }; Write-Output $c`, ip)
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	slog.Debug("executing powershell compartment query", "ip", ip)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		// Attempt to derive specific exit codes (98/99) for user-friendly diagnostics
		var exitCode int
		if ee, ok := err.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
			switch exitCode {
			case 99:
				return 0, fmt.Errorf("no network interface found for pod IP %s (exit 99). Possible causes: pod IP not yet bound on host, virtual/overlay network not exposed via Get-NetIPConfiguration, or insufficient privileges. Enable debug verbosity for script details. Raw output: %s", ip, strings.TrimSpace(out.String()))
			case 98:
				return 0, fmt.Errorf("failed to obtain CompartmentId for interface of pod IP %s (exit 98). Interface present but did not return a compartment. Raw output: %s", ip, strings.TrimSpace(out.String()))
			default:
				return 0, fmt.Errorf("PowerShell query failed (exit %d) resolving compartment for IP %s: %v. Output: %s", exitCode, ip, err, strings.TrimSpace(out.String()))
			}
		}
		return 0, fmt.Errorf("PowerShell execution error resolving compartment for IP %s: %v. Output: %s", ip, err, strings.TrimSpace(out.String()))
	}
	line := strings.TrimSpace(out.String())
	if line == "" {
		return 0, fmt.Errorf("empty compartment output for ip %s", ip)
	}
	var comp int
	_, scanErr := fmt.Sscanf(line, "%d", &comp)
	if scanErr != nil {
		return 0, fmt.Errorf("parse compartment id '%s': %v", line, scanErr)
	}
	compCacheMu.Lock()
	compCache[ip] = comp
	compCacheMu.Unlock()
	return comp, nil
}
