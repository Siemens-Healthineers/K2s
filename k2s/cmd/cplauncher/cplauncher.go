// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
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
	flag.UintVar(&compartment, "compartment", 0, "Compartment ID (required)")
	flag.StringVar(&dll, "dll", "", "Helper DLL path (required)")
	flag.StringVar(&exportName, "export", "SetTargetCompartmentId", "Export name")
	flag.BoolVar(&selfEnv, "self-env", false, "Only set environment variable (no remote SetCurrentThreadCompartmentId); target must self-set")
	flag.BoolVar(&noInject, "no-inject", false, "Skip DLL injection (use with -self-env)")
	flag.StringVar(&envVarName, "env-name", "COMPARTMENT_ID", "Environment variable name to pass compartment to target when using -self-env")
	flag.Parse()
	if compartment == 0 || dll == "" {
		log.Fatal("-compartment and -dll required")
	}
	var target []string
	for i, a := range os.Args {
		if a == "--" {
			target = os.Args[i+1:]
			break
		}
	}
	if len(target) == 0 {
		log.Fatal("Usage: <launcher> -compartment <id> -dll <dll> -- <exe> [args]")
	}
	exe := target[0]
	args := target[1:]

	if err := createCompartmentIfNeeded(uint32(compartment)); err != nil {
		log.Printf("[warn] compartment provisioning attempt: %v", err)
	}

	// Always set COMPARTMENT_ID_ATTACH so the DLL's DllMain can attempt per-thread switching
	os.Setenv("COMPARTMENT_ID_ATTACH", fmt.Sprintf("%d", compartment))
	log.Printf("[info] set COMPARTMENT_ID_ATTACH=%d (DLL will queue per-thread compartment switch via APC on load)", compartment)

	if selfEnv {
		// Expose additional variable (possibly custom name) for target code that self-configures
		os.Setenv(envVarName, fmt.Sprintf("%d", compartment))
		log.Printf("[info] set %s=%d (target code may self-call SetCurrentThreadCompartmentId); COMPARTMENT_ID_ATTACH already set for automatic DLL handling", envVarName, compartment)
	}
	pi, err := createSuspended(exe, args)
	if err != nil {
		log.Fatalf("create process: %v", err)
	}
	defer procCloseHandle.Call(uintptr(pi.Process))
	defer procCloseHandle.Call(uintptr(pi.Thread))

	if !noInject {
		base, err := injectDLL(pi.Process, dll)
		if err != nil {
			log.Fatalf("inject: %v", err)
		}
		offset, err := computeExportOffset(dll, exportName)
		if err != nil {
			log.Fatalf("export offset: %v", err)
		}
		if enumBase, err2 := getModuleBase(pi.ProcessId, filepath.Base(dll)); err2 == nil {
			base = enumBase
		}
		if !selfEnv { // only attempt remote call if not deferring to target
			if err := callRemoteExport(pi.Process, base, offset, uint32(compartment)); err != nil {
				log.Fatalf("remote call: %v", err)
			} else {
				log.Printf("[info] remote thread SetCurrentThreadCompartmentId(%d) succeeded (NOTE: affects only that remote thread)", compartment)
			}
		} else {
			log.Printf("[info] skipped remote SetTargetCompartmentId call due to -self-env (DLL may still perform other instrumentation)")
		}
	} else if !selfEnv {
		log.Printf("[warn] -no-inject specified without -self-env; the main thread will remain in its original compartment")
	}

	if !selfEnv {
		log.Printf("[note] The current method sets compartment on a transient remote thread only; unless the target itself sets the compartment on its network threads it will continue operating in compartment 1.")
	}
	if err := resume(pi); err != nil {
		log.Fatalf("resume: %v", err)
	}
	log.Printf("Done. PID=%d", pi.ProcessId)
}
