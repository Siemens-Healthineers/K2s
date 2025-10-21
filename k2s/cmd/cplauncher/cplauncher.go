// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"errors"
	"bufio"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"context"
	"os/exec"
	"regexp"
	"sort"
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
	procGetExitCodeProcess       = kernel32.NewProc("GetExitCodeProcess")
	procCloseHandle              = kernel32.NewProc("CloseHandle")
	procLoadLibraryW             = kernel32.NewProc("LoadLibraryW")
	procSetHandleInformation     = kernel32.NewProc("SetHandleInformation")
	procCreatePipe               = kernel32.NewProc("CreatePipe")
	procCreateToolhelp32Snapshot = kernel32.NewProc("CreateToolhelp32Snapshot")
	procModule32FirstW           = kernel32.NewProc("Module32FirstW")
	procModule32NextW            = kernel32.NewProc("Module32NextW")
	iphlpapi                     = syscall.NewLazyDLL("iphlpapi.dll")
)

const (
	CREATE_SUSPENDED           = 0x00000004
	CREATE_UNICODE_ENVIRONMENT = 0x00000400
	MEM_COMMIT                 = 0x1000
	MEM_RESERVE                = 0x2000
	PAGE_READWRITE             = 0x04
	TH32CS_SNAPMODULE          = 0x00000008
	TH32CS_SNAPMODULE32        = 0x00000010
	STARTF_USESTDHANDLES      = 0x00000100
	HANDLE_FLAG_INHERIT       = 0x00000001
)

// startupInfo mirrors Windows STARTUPINFOW (only fields we need) for std handle redirection.
type startupInfo struct {
	Cb              uint32
	lpReserved      *uint16
	lpDesktop       *uint16
	lpTitle         *uint16
	dwX             uint32
	dwY             uint32
	dwXSize         uint32
	dwYSize         uint32
	dwXCountChars   uint32
	dwYCountChars   uint32
	dwFillAttribute uint32
	dwFlags         uint32
	wShowWindow     uint16
	cbReserved2     uint16
	lpReserved2     *byte
	hStdInput       syscall.Handle
	hStdOutput      syscall.Handle
	hStdError       syscall.Handle
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

// winEscapeArg applies Windows command line quoting rules for a single argument so CreateProcessW
// parses it back to the original string. Adapted from documented rules; intentionally minimal yet
// covers spaces, tabs, quotes and backslashes before quotes.
func winEscapeArg(a string) string {
	if a == "" { return "\"\"" }
	// Fast path: no special chars needing quotes
	// Need quotes if spaces, tabs, quotes, empty, or ends with backslash (so it isn't consumed)
	needQuotes := strings.ContainsAny(a, " \t\"") || len(a) == 0 || strings.HasSuffix(a, "\\")
	if !needQuotes {
		return a
	}
	var b strings.Builder
	b.Grow(len(a) + 2)
	b.WriteByte('"')
	backslashes := 0
	for i := 0; i < len(a); i++ {
		c := a[i]
		if c == '\\' {
			backslashes++
			continue
		}
		if c == '"' {
			// double the accumulated backslashes, then escape the quote
			b.WriteString(strings.Repeat("\\", backslashes*2))
			backslashes = 0
			b.WriteString("\\\"")
			continue
		}
		// normal char
		if backslashes > 0 {
			b.WriteString(strings.Repeat("\\", backslashes))
			backslashes = 0
		}
		b.WriteByte(c)
	}
	if backslashes > 0 {
		// Only double if we are about to terminate the quoted arg (so they precede the closing quote)
		b.WriteString(strings.Repeat("\\", backslashes*2))
	}
	b.WriteByte('"')
	return b.String()
}

// buildCommandLine constructs the full command line including the executable as the first argument.
func buildCommandLine(fullExe string, args []string) string {
	escaped := make([]string, 0, 1+len(args))
	// Always quote exe path to be safe (could contain spaces)
	escaped = append(escaped, winEscapeArg(fullExe))
	for _, a := range args { escaped = append(escaped, winEscapeArg(a)) }
	return strings.Join(escaped, " ")
}

func createSuspended(exe string, args []string, stdout, stderr syscall.Handle) (processInformation, error) {
	var pi processInformation
	full, err := filepath.Abs(exe)
	if err != nil {
		return pi, err
	}
	if _, err = os.Stat(full); err != nil {
		return pi, fmt.Errorf("executable not found: %s", full)
	}
	// Prepare STARTUPINFO with redirected handles when provided
	si := startupInfo{}
	si.Cb = uint32(unsafe.Sizeof(si))
	inherit := uintptr(0)
	if stdout != 0 || stderr != 0 {
		si.dwFlags |= STARTF_USESTDHANDLES
		if stdout != 0 { si.hStdOutput = stdout }
		if stderr != 0 { si.hStdError = stderr }
		inherit = 1
	}
	cmdLine := buildCommandLine(full, args)
	// Windows may modify the command line buffer in-place, so create a mutable UTF16 slice
	clUTF16 := syscall.StringToUTF16(cmdLine)
	appNamePtr := utf16Ptr(full)
	slog.Debug("CreateProcessW prepared", "application", full, "cmdLine", cmdLine, "inheritStd", inherit == 1)
	r1, _, e1 := procCreateProcessW.Call(
		uintptr(unsafe.Pointer(appNamePtr)),                                  // lpApplicationName
		uintptr(unsafe.Pointer(&clUTF16[0])),                                  // lpCommandLine (mutable)
		0, 0,                                                                  // lpProcessAttributes, lpThreadAttributes
		inherit,                                                               // bInheritHandles
		CREATE_SUSPENDED|CREATE_UNICODE_ENVIRONMENT,                           // dwCreationFlags
		0,                                                                     // lpEnvironment (inherit)
		0,                                                                     // lpCurrentDirectory (inherit)
		uintptr(unsafe.Pointer(&si)),                                          // lpStartupInfo
		uintptr(unsafe.Pointer(&pi)),                                          // lpProcessInformation
	)
	if r1 == 0 {
		return pi, fmt.Errorf("CreateProcessW failed: %v (cmdLine=%s)", e1, cmdLine)
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

// dumpRecentErrorLines prints up to 'max' recent lines containing level=ERROR from the log file to stderr.
// If none are found, it prints the last 'max' lines of the file instead. Best-effort; failures are silent.
func dumpRecentErrorLines(path string, max int) {
 	f, err := os.Open(path)
 	if err != nil { return }
 	defer f.Close()
 	scanner := bufio.NewScanner(f)
 	var all []string
 	for scanner.Scan() {
 		line := scanner.Text()
 		all = append(all, line)
 	}
 	var errs []string
 	for _, l := range all { if strings.Contains(l, "level=ERROR") { errs = append(errs, l) } }
 	selectLines := errs
 	if len(selectLines) == 0 { selectLines = all }
 	if max > 0 && len(selectLines) > max { selectLines = selectLines[len(selectLines)-max:] }
 	if len(selectLines) == 0 { return }
 	fmt.Fprintf(os.Stderr, "\n---- recent log lines (%s) ----\n", path)
 	for _, l := range selectLines { fmt.Fprintln(os.Stderr, l) }
 	fmt.Fprintln(os.Stderr, "---- end log excerpt ----")
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
	var logsKeep int
	var logMaxAgeStr string

	versionFlag := cli.NewVersionFlag(cliName)

	flag.UintVar(&compartment, "compartment", 0, "Compartment ID (required unless -label is used)")
	flag.StringVar(&dll, "dll", "", "Helper DLL path (optional if cphook.dll is beside the executable)")
	flag.StringVar(&exportName, "export", "SetTargetCompartmentId", "Export name of the compartment switching function inside the helper DLL")
	flag.BoolVar(&selfEnv, "self-env", false, "Only set environment variable (no remote SetCurrentThreadCompartmentId); target must self-set")
	flag.BoolVar(&noInject, "no-inject", false, "Skip DLL injection (use with -self-env)")
	flag.StringVar(&envVarName, "env-name", "COMPARTMENT_ID", "Environment variable name to pass compartment to target when using -self-env")
	flag.StringVar(&labelSelector, "label", "", "Kubernetes label selector to resolve a pod -> compartment (alternative to -compartment)")
	flag.StringVar(&namespace, "namespace", "", "Namespace scope for -label lookup (empty = all namespaces)")
	flag.StringVar(&labelTimeoutStr, "label-timeout", "20s", "Timeout for Kubernetes label resolution (e.g. 5s, 30s, 1m)")
	flag.IntVar(&logsKeep, "logs-keep", 30, "Maximum number of previous log files to retain (excluding current)" )
	flag.StringVar(&logMaxAgeStr, "log-max-age", "", "Optional max age for log files (e.g. 24h, 7d); empty disables age-based deletion")
	flag.BoolVar(&dryRun, "dry-run", false, "Show planned actions (compartment, dll resolution, target) without creating or modifying a process")
	flag.StringVar(&verbosity, cli.VerbosityFlagName, logging.LevelToLowerString(slog.LevelInfo), cli.VerbosityFlagHelp())
	flag.StringVar(&verbosity, "v", logging.LevelToLowerString(slog.LevelInfo), "Alias for -verbosity")
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

	// Perform log retention maintenance (best-effort)
	if err := cleanupOldLogs(logDir, logFileName, logsKeep, logMaxAgeStr); err != nil {
		slog.Warn("log cleanup encountered an issue", "error", err)
	}

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
			dumpRecentErrorLines(logFilePath, 20)
			os.Exit(1)
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
	// Prepare live streaming via anonymous pipes + persistent capture files.
	childStdoutPath := filepath.Join(logDir, fmt.Sprintf("%s-child-stdout-%d.log", cliName, time.Now().UnixNano()))
	childStderrPath := filepath.Join(logDir, fmt.Sprintf("%s-child-stderr-%d.log", cliName, time.Now().UnixNano()))
	stdoutCaptureFile, err := os.Create(childStdoutPath)
	if err != nil { slog.Error("create stdout capture file failed", "error", err); os.Exit(1) }
	defer stdoutCaptureFile.Close()
	stderrCaptureFile, err := os.Create(childStderrPath)
	if err != nil { slog.Error("create stderr capture file failed", "error", err); os.Exit(1) }
	defer stderrCaptureFile.Close()

	makePipe := func() (readH, writeH syscall.Handle, err error) {
		var r, w syscall.Handle
		ret, _, e1 := procCreatePipe.Call(uintptr(unsafe.Pointer(&r)), uintptr(unsafe.Pointer(&w)), 0, 0)
		if ret == 0 {
			return 0, 0, fmt.Errorf("CreatePipe: %v", e1)
		}
		// Ensure write end is inheritable, read end not inheritable
		if _, _, eW := procSetHandleInformation.Call(uintptr(w), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT); eW != nil && eW.Error() != "The operation completed successfully." {
			slog.Warn("SetHandleInformation write end", "error", eW)
		}
		if _, _, eR := procSetHandleInformation.Call(uintptr(r), HANDLE_FLAG_INHERIT, 0); eR != nil && eR.Error() != "The operation completed successfully." {
			slog.Warn("SetHandleInformation read end", "error", eR)
		}
		return r, w, nil
	}
	stdoutR, stdoutW, err := makePipe()
	if err != nil { slog.Error("pipe setup failed", "stream", "stdout", "error", err); os.Exit(1) }
	stderrR, stderrW, err := makePipe()
	if err != nil { slog.Error("pipe setup failed", "stream", "stderr", "error", err); os.Exit(1) }

	pi, err := createSuspended(exe, args, stdoutW, stderrW)
	if err != nil {
		slog.Error("create process failed", "error", err, "exe", exe)
		dumpRecentErrorLines(logFilePath, 20)
		os.Exit(1)
	}
	// Parent no longer needs write ends
	procCloseHandle.Call(uintptr(stdoutW))
	procCloseHandle.Call(uintptr(stderrW))

	// Print PID as first line before any child output (child still suspended)
	fmt.Printf("pid=%d\n", pi.ProcessId)
	// Flush to ensure ordering
	os.Stdout.Sync()

	// Start streaming goroutines before injection so DLL output (if any) is captured.
	var streamWG sync.WaitGroup
	stream := func(handle syscall.Handle, streamName string, persist *os.File) {
		defer streamWG.Done()
		f := os.NewFile(uintptr(handle), streamName)
		if f == nil { return }
		defer f.Close()
		scanner := bufio.NewScanner(f)
		buf := make([]byte, 0, 64*1024)
		scanner.Buffer(buf, 1024*1024)
		writer := bufio.NewWriter(persist)
		defer writer.Flush()
		for scanner.Scan() {
			line := scanner.Text()
			line = strings.TrimRight(line, "\r")
			if line == "" { continue }
			// Write to capture file
			writer.WriteString(line + "\n")
			writer.Flush()
			// Mirror to parent console promptly
			if streamName == "stdout" {
				fmt.Fprintln(os.Stdout, line)
			} else {
				fmt.Fprintln(os.Stderr, line)
			}
			// Structured log
			slog.Info("child", "stream", streamName, "line", line)
		}
		if err := scanner.Err(); err != nil {
			slog.Warn("child stream read error", "stream", streamName, "error", err)
		}
	}
	streamWG.Add(2)
	go stream(stdoutR, "stdout", stdoutCaptureFile)
	go stream(stderrR, "stderr", stderrCaptureFile)
	defer procCloseHandle.Call(uintptr(pi.Process))
	defer procCloseHandle.Call(uintptr(pi.Thread))

	if !noInject {
		base, err := injectDLL(pi.Process, dll)
		if err != nil {
			slog.Error("dll injection failed", "error", err, "dll", dll)
			dumpRecentErrorLines(logFilePath, 20)
			os.Exit(1)
		}
		offset, err := computeExportOffset(dll, exportName)
		if err != nil {
			slog.Error("compute export offset failed", "error", err, "export", exportName)
			dumpRecentErrorLines(logFilePath, 20)
			os.Exit(1)
		}
		if enumBase, err2 := getModuleBase(pi.ProcessId, filepath.Base(dll)); err2 == nil {
			base = enumBase
			slog.Debug("module base enumerated", "base", fmt.Sprintf("0x%x", base))
		}
		if !selfEnv { // only attempt remote call if not deferring to target
			if err := callRemoteExport(pi.Process, base, offset, uint32(compartment)); err != nil {
				slog.Error("remote export call failed", "error", err, "compartment", compartment)
				dumpRecentErrorLines(logFilePath, 20)
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
		dumpRecentErrorLines(logFilePath, 20)
		os.Exit(1)
	}
	finalDll := dll
	if noInject {
		if finalDll == "" { finalDll = "(no injection)" } else { finalDll += " (injection disabled)" }
	}
	slog.Info("child running", "pid", pi.ProcessId, "dll", finalDll, "compartment", compartment, "selfEnv", selfEnv, "noInject", noInject, "logFile", logFilePath, "stdoutCapture", childStdoutPath, "stderrCapture", childStderrPath)

	// Wait for child exit
	syscall.WaitForSingleObject(syscall.Handle(pi.Process), syscall.INFINITE)
	var exitCode uint32
	procGetExitCodeProcess.Call(uintptr(pi.Process), uintptr(unsafe.Pointer(&exitCode)))
	// Wait for stream goroutines to finish consuming remaining buffered data
	streamWG.Wait()

	slog.Info("child exited", "pid", pi.ProcessId, "exitCode", exitCode)
	fmt.Printf("cplauncher: child exited pid=%d exit=%d (log=%s)\n", pi.ProcessId, exitCode, logFilePath)
	os.Exit(int(exitCode))
}

// resolveCompartmentFromLabel locates a pod by label selector and maps its primary IP to a Windows network compartment ID.
// Strategy:
// 1. Load system kubeconfig and list pods by selector (optionally namespace constrained).
// 2. Enforce exactly one match.
// 3. Derive compartment via parsing `ipconfig /allcompartments` (primary approach) cached per IP.
func resolveCompartmentFromLabel(selector, namespace string, timeout time.Duration) (int, string, string, string, error) {
	kubeconfig := filepath.Join(os.Getenv("USERPROFILE"), ".kube", "config")
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
		// Wait for PodIP to be assigned within the provided timeout instead of failing immediately.
		start := time.Now()
		pollInterval := 1 * time.Second
		slog.Info("pod has no IP yet; waiting", "pod", pod.Name, "namespace", pod.Namespace, "timeout", timeout, "pollInterval", pollInterval)
		for {
			// Check context deadline first
			select {
			case <-ctx.Done():
				elapsed := time.Since(start)
				return 0, "", pod.Name, pod.Namespace, fmt.Errorf("pod '%s/%s' still has no IP after %s (timeout); consider increasing -label-timeout", pod.Namespace, pod.Name, elapsed)
			default:
			}

			// Re-fetch the pod to see if IP assigned
			refreshed, err := clientset.CoreV1().Pods(pod.Namespace).Get(context.Background(), pod.Name, metav1.GetOptions{})
			if err != nil {
				// Non-fatal transient errors: keep waiting unless context expired
				slog.Warn("pod get during IP wait failed", "pod", pod.Name, "namespace", pod.Namespace, "error", err)
			} else if refreshed.Status.PodIP != "" {
				pod = *refreshed
				break
			}
			time.Sleep(pollInterval)
		}
		elapsed := time.Since(start)
		slog.Info("pod IP resolved after wait", "pod", pod.Name, "namespace", pod.Namespace, "podIP", pod.Status.PodIP, "waitElapsed", elapsed)
	}
	comp, err := compartmentFromIP(pod.Status.PodIP)
	if err != nil {
		return 0, pod.Status.PodIP, pod.Name, pod.Namespace, fmt.Errorf("map pod ip to compartment: %w", err)
	}
	return comp, pod.Status.PodIP, pod.Name, pod.Namespace, nil
}

// compartmentFromIP returns the compartment id for a given IP via parsing ipconfig /allcompartments.
func compartmentFromIP(ip string) (int, error) {
	compCacheMu.RLock(); if v, ok := compCache[ip]; ok { compCacheMu.RUnlock(); return v, nil }; compCacheMu.RUnlock()
	comp, err := compartmentFromIPViaIpconfig(ip)
	if err != nil { return 0, fmt.Errorf("ipconfig scan failed for ip %s: %w", ip, err) }
	compCacheMu.Lock(); compCache[ip] = comp; compCacheMu.Unlock(); return comp, nil
}

// compartmentFromIPViaIpconfig parses the output of `ipconfig /allcompartments` to map an IP to a compartment id.
// This is a pragmatic fallback for cases where the process cannot enumerate addresses from other compartments via APIs.
func compartmentFromIPViaIpconfig(ip string) (int, error) {
 	cmd := exec.Command("ipconfig", "/allcompartments")
 	out, err := cmd.Output()
 	if err != nil { return 0, fmt.Errorf("run ipconfig: %w", err) }
 	lines := strings.Split(string(out), "\n")
 	compartmentRe := regexp.MustCompile(`(?i)compartment[^0-9]*([0-9]+)`) // attempts to catch lines introducing a compartment
 	ipRe := regexp.MustCompile(`\b` + regexp.QuoteMeta(ip) + `\b`)
 	current := -1
 	found := -1
 	for _, raw := range lines {
 		line := strings.TrimSpace(strings.ReplaceAll(raw, "\r", ""))
 		if line == "" { continue }
 		if m := compartmentRe.FindStringSubmatch(line); m != nil {
 			var cid int
 			fmt.Sscanf(m[1], "%d", &cid)
 			current = cid
 			continue
 		}
 		if current != -1 && ipRe.MatchString(line) {
 			if found != -1 && found != current { return 0, fmt.Errorf("ip %s appears in multiple compartments (%d,%d)", ip, found, current) }
 			found = current
 		}
 	}
 	if found == -1 { return 0, fmt.Errorf("ip %s not found in ipconfig /allcompartments output", ip) }
 	return found, nil
}

// cleanupOldLogs enforces log retention: keep latest 'keep' files (excluding current) and optionally delete older than maxAge.
func cleanupOldLogs(dir, current string, keep int, maxAgeStr string) error {
	if keep < 0 { keep = 0 }
	var maxAge time.Duration
	var err error
	if maxAgeStr != "" {
		maxAge, err = time.ParseDuration(maxAgeStr)
		if err != nil { return fmt.Errorf("parse log-max-age: %w", err) }
		if maxAge <= 0 { return fmt.Errorf("log-max-age must be > 0") }
	}
	entries, err := os.ReadDir(dir)
	if err != nil { return fmt.Errorf("read log dir: %w", err) }
	type lf struct { name string; info os.FileInfo }
	var files []lf
	for _, e := range entries {
		if e.IsDir() { continue }
		name := e.Name()
		if !strings.HasPrefix(name, cliName+"-") || !strings.HasSuffix(name, ".log") { continue }
		if name == current { continue }
		info, ierr := e.Info(); if ierr != nil { continue }
		files = append(files, lf{name: name, info: info})
	}
	// Sort newest first
	sort.Slice(files, func(i,j int) bool { return files[i].info.ModTime().After(files[j].info.ModTime()) })
	now := time.Now()
	var toDelete []lf
	if keep < len(files) {
		toDelete = append(toDelete, files[keep:]...)
	}
	if maxAgeStr != "" {
		for _, f := range files[:min(len(files), keep)] { // also age filter among retained set
			if now.Sub(f.info.ModTime()) > maxAge { toDelete = append(toDelete, f) }
		}
	}
	seen := map[string]struct{}{}
	for _, f := range toDelete {
		if _, ok := seen[f.name]; ok { continue }
		seen[f.name] = struct{}{}
		path := filepath.Join(dir, f.name)
		if err := os.Remove(path); err != nil {
			slog.Debug("log retention removal failed", "file", path, "error", err)
		} else {
			slog.Debug("log retention removed", "file", path)
		}
	}
	return nil
}

func min(a,b int) int { if a<b { return a }; return b }
