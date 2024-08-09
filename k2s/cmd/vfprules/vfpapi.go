// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/sirupsen/logrus"
)

type VFXItemType uint8

const (
	VfxItemNone VFXItemType = iota
	VfxItemSpecifier
	VfxItemGeneral
	VfxItemLayer
	VfxItemGroup
	VfxItemRule
	VfxItemNatPool
	VfxItemNatRange
	VfxItemInformation
	VfxItemFlow
	VfxItemSpace
	VfxItemMapping
	VfxItemPacket
	VfxItemPortName
	VfxItemUnifiedFlow
	VfxItemHeaderTransposition
	VfxItemStatus
	VfxItemQosQueue
	VfxItemPort
	VfxItemNatPortBinding
	VfxItemInformationEx
	VfxItemCondition
	VfxItemDtlsSession
	VfxItemPADiscoveryRoute
	VfxItemPingInfo
	VfxItemTag
	VfxItemPortRuleCounter
	VfxItemVmContext
	VfxItemFlowToken
	VfxItemSimplifiedUnifiedFlowId
	VfxItemVMSwitchPort
	VfxItemVMSwitch
	VfxItemNode
	VfxItemTraceFilter
	VfxItemTrackedPacket
	VfxItemMax
)

type VFC_PARAMETERS struct {
	DeviceName    string
	SwitchName    string
	PortName      string
	ExtensionGuid string
}

type VFC_OBJECT_ID struct {
	Count uint32              // Assuming ULONG is 32-bit unsigned integer
	Id    [VfxItemMax]*uint16 // Array of PCWSTR (unicode pointers)
}

const VFX_MAXIMUM_CONDITION = 5
const VFX_MAXIMUM_RULE_DATA = 2

type VFX_CONDITION_DESCRIPTOR struct {
	Size [VFX_MAXIMUM_CONDITION]uint16
	Type [VFX_MAXIMUM_CONDITION]uint8
}

type VFC_DESCRIPTOR_HEADER struct {
	DescriptorSize uint16
	Type           uint8
	SubType        uint8
	Flags          uint16
	IdSize         uint16
	NameSize       uint16
	ContextSize    uint16
	Priority       uint16
	Reserved1      uint16
	Reserved2      uint64
	Id             unsafe.Pointer
	Name           unsafe.Pointer
	Context        unsafe.Pointer
}

type VFC_RULE_DESCRIPTOR struct {
	Header                VFC_DESCRIPTOR_HEADER
	Condition             [VFX_MAXIMUM_CONDITION]unsafe.Pointer
	ConditionSize         [VFX_MAXIMUM_CONDITION]uint16
	ConditionType         [VFX_MAXIMUM_CONDITION]uint8
	RuleData              [VFX_MAXIMUM_RULE_DATA]unsafe.Pointer
	RuleDataSize          [VFX_MAXIMUM_RULE_DATA]uint16
	TimeToLive            uint16
	MssDelta              int8
	ReverseMssDelta       int8
	RuleFlags             uint64
	PortRuleCounter       unsafe.Pointer
	PortRuleCounterIdSize uint16
}

// Load the DLL and the VfcAddObject function
var (
	vfpapiDLL        = syscall.NewLazyDLL("c:\\windows\\System32\\vfpapi.dll")
	procVfcAddObject = vfpapiDLL.NewProc("VfcAddObject")
)

// Define the Go wrapper for the VfcAddObject function
func VfcAddObject(parameters *VFC_PARAMETERS, objectId *VFC_OBJECT_ID, descriptor unsafe.Pointer) (uint32, error) {
	ret, _, err := procVfcAddObject.Call(
		uintptr(unsafe.Pointer(parameters)),
		uintptr(unsafe.Pointer(objectId)),
		uintptr(descriptor),
	)
	if ret != 0 {
		return uint32(ret), nil
	}
	return 0, err
}

func RtlZeroMemory(dest unsafe.Pointer, size uintptr) {
	mem := (*[1 << 30]byte)(dest)[:size:size]
	for i := range mem {
		mem[i] = 0
	}
}

func RtlZeroMemoryLength(destination unsafe.Pointer, length uint16) {
	mem := unsafe.Slice((*byte)(destination), length)
	for i := range mem {
		mem[i] = 0
	}
}

func AddVfpRulesWithVfpApi(portid string, port string, vfpRoutes *VfpRoutes, logDir string) error {
	logrus.Debug("[cni-net] AddVfpRulesWithVfpApi: ", portid, port, vfpRoutes, logDir)
	// open file for adding commands
	filename := filepath.Join(logDir, "vfp-rules-"+portid+".cmd")
	fileCmds, errCmds := os.OpenFile(filename, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if errCmds != nil {
		log.Fatalf("AddVfpRules: Failed creating file: %s", errCmds)
		return errCmds
	}

	datawriter := bufio.NewWriter(fileCmds)
	for _, vfpRoute := range vfpRoutes.Routes {
		debugLog := fmt.Sprintf("[cni-net] Name: %s, Subnet: %s, Gateway: %s, Priority: %s", vfpRoute.Name, vfpRoute.Subnet, vfpRoute.Gateway, vfpRoute.Priority)
		logrus.Info(debugLog)
		// get mac address of gateway
		mac, errmac := GetMacOfGateway(vfpRoute.Gateway)
		if errmac != nil {
			logrus.Info("AddVfpRules: Getting MAC not found error, will continue with the other rules, err:", errmac)
		} else {
			// write the rules to be added
			WriteVFPRule(datawriter, vfpRoute.Name, port, mac, vfpRoute.Subnet, vfpRoute.Priority)
		}
	}
	datawriter.Flush()
	fileCmds.Close()
	return nil
}
