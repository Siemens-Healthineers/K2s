// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package containernetworking

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Microsoft/hcsshim/hcn"
	kos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/sirupsen/logrus"
)

const LocalSystemSID = "S-1-5-18"

type Policy struct {
	// Inbound proxy port. (Required)
	InboundProxyPort string

	// Outbound proxy port. (Required)
	OutboundProxyPort string

	// Ignore traffic originating from the specified user SID. (Optional)
	UserSID string

	// Only proxy traffic originating from the specified address. (Optional)
	LocalAddresses string

	// Only proxy traffic destinated to the specified address. (Optional)
	RemoteAddresses string

	// Only proxy traffic originating from the specified port or port range. (Optional)
	LocalPorts string

	// Only proxy traffic destinated to the specified port or port range. (Optional)
	RemotePorts string

	// The priority of this policy. (Optional)
	// For more info, see https://docs.microsoft.com/en-us/windows/win32/fwp/filter-weight-assignment.
	Priority uint16

	// Only proxy traffic using this protocol. TCP is the only supported
	// protocol for now, and this field defaults to that if left blank. (Optional)
	// Ex: 6 = TCP
	Protocol string

	// Inbound port exceptions
	InboundPortExceptions []string

	// Inbound address exceptions
	InboundAddressExceptions []string

	// Outbound port exceptions
	OutboundPortExceptions []string

	// Outbound address exceptions
	OutboundAddressExceptions []string
}

type HnsProxyConfig struct {
	InboundProxyPort          string `json:inboundproxyport`
	OutboundProxyPort         string `json:outboundproxyport`
	InboundPortExceptions     string `json:inboundportexceptions`
	InboundAddressExceptions  string `json:inboundaddressexceptions`
	OutboundPortExceptions    string `json:outboundportexceptions`
	OutboundAddressExceptions string `json:outboundaddressexceptions`
}

type VfpRoutes struct {
	HnsProxyConfig HnsProxyConfig `json:hnsproxy`
}

func HnsProxyAddPolicy(hnsEndpointID string, policy Policy) error {
	if err := HnsProxyValidatePolicy(policy); err != nil {
		return err
	}

	// TCP is the default protocol and is the only supported one anyway.
	policy.Protocol = "6"

	policySetting := hcn.L4WfpProxyPolicySetting{
		InboundProxyPort:  policy.InboundProxyPort,
		OutboundProxyPort: policy.OutboundProxyPort,
		UserSID:           policy.UserSID,
		FilterTuple: hcn.FiveTuple{
			LocalAddresses:  policy.LocalAddresses,
			RemoteAddresses: policy.RemoteAddresses,
			LocalPorts:      policy.LocalPorts,
			RemotePorts:     policy.RemotePorts,
			Protocols:       policy.Protocol,
			Priority:        policy.Priority,
		},
		InboundExceptions:  hcn.ProxyExceptions{IpAddressExceptions: policy.InboundAddressExceptions, PortExceptions: policy.InboundPortExceptions},
		OutboundExceptions: hcn.ProxyExceptions{IpAddressExceptions: policy.OutboundAddressExceptions, PortExceptions: policy.OutboundPortExceptions},
	}

	policyJSON, err := json.Marshal(policySetting)
	if err != nil {
		// log error
		log.Println("Error marshaling to json:", err)
		return err
	}

	// log on console the JSON
	log.Println("Policy JSON:", string(policyJSON))

	endpointPolicy := hcn.EndpointPolicy{
		Type:     hcn.L4WFPPROXY,
		Settings: policyJSON,
	}

	request := hcn.PolicyEndpointRequest{
		Policies: []hcn.EndpointPolicy{endpointPolicy},
	}

	endpoint, err := hcn.GetEndpointByID(hnsEndpointID)
	if err != nil {
		log.Println("Error getting endpoint:", err)
		return err
	}

	err1 := endpoint.ApplyPolicy(hcn.RequestTypeAdd, request)
	if err1 != nil {
		log.Println("Error applying policy	:", err1)
		return err1
	}
	return nil
}

func HnsProxyHnsListPolicies(hnsEndpointID string) ([]Policy, error) {
	hcnPolicies, err := HnsProxyListPolicies(hnsEndpointID)
	if err != nil {
		return nil, err
	}

	var policies []Policy
	for _, hcnPolicy := range hcnPolicies {
		policies = append(policies, HnsProxyPolicyToAPIPolicy(hcnPolicy))
	}

	return policies, nil
}

// ClearPolicies removes all the proxy policies from the specified endpoint.
// It returns the number of policies that were removed, which will be zero
// if an error occurred or if the endpoint did not have any active proxy policies.
func HnsProxyClearPolicies(hnsEndpointID string) (numRemoved int, err error) {
	fmt.Println("Clear the policies for endpoint: ", hnsEndpointID)
	policies, err := HnsProxyListPolicies(hnsEndpointID)
	if err != nil {
		return 0, err
	}

	policyReq := hcn.PolicyEndpointRequest{
		Policies: policies,
	}

	policyJSON, err := json.Marshal(policyReq)
	if err != nil {
		return 0, err
	}

	modifyReq := &hcn.ModifyEndpointSettingRequest{
		ResourceType: hcn.EndpointResourceTypePolicy,
		RequestType:  hcn.RequestTypeRemove,
		Settings:     policyJSON,
	}

	return len(policies), hcn.ModifyEndpointSettings(hnsEndpointID, modifyReq)
}

func HnsProxyListPolicies(hnsEndpointID string) ([]hcn.EndpointPolicy, error) {
	endpoint, err := hcn.GetEndpointByID(hnsEndpointID)
	if err != nil {
		return nil, err
	}

	var policies []hcn.EndpointPolicy
	for _, policy := range endpoint.Policies {
		if policy.Type == hcn.L4WFPPROXY {
			policies = append(policies, policy)
		}
	}

	return policies, nil
}

func HnsProxyPolicyToAPIPolicy(hcnPolicy hcn.EndpointPolicy) Policy {
	if hcnPolicy.Type != hcn.L4WFPPROXY {
		panic("not an L4 proxy policy")
	}

	// Assuming HNS will never return invalid values from here.
	var hcnPolicySetting hcn.L4WfpProxyPolicySetting
	_ = json.Unmarshal(hcnPolicy.Settings, &hcnPolicySetting)

	return Policy{
		InboundProxyPort:          hcnPolicySetting.InboundProxyPort,
		OutboundProxyPort:         hcnPolicySetting.OutboundProxyPort,
		UserSID:                   hcnPolicySetting.UserSID,
		LocalAddresses:            hcnPolicySetting.FilterTuple.LocalAddresses,
		RemoteAddresses:           hcnPolicySetting.FilterTuple.RemoteAddresses,
		LocalPorts:                hcnPolicySetting.FilterTuple.LocalPorts,
		RemotePorts:               hcnPolicySetting.FilterTuple.RemotePorts,
		Priority:                  hcnPolicySetting.FilterTuple.Priority,
		Protocol:                  hcnPolicySetting.FilterTuple.Protocols,
		InboundPortExceptions:     hcnPolicySetting.InboundExceptions.PortExceptions,
		InboundAddressExceptions:  hcnPolicySetting.InboundExceptions.IpAddressExceptions,
		OutboundPortExceptions:    hcnPolicySetting.OutboundExceptions.PortExceptions,
		OutboundAddressExceptions: hcnPolicySetting.OutboundExceptions.IpAddressExceptions,
	}
}

func HnsProxyValidatePolicy(policy Policy) error {
	if len(policy.InboundProxyPort) == 0 {
		return errors.New("policy missing proxy port")
	}
	port, _ := strconv.Atoi(policy.InboundProxyPort)
	if port == 0 {
		return errors.New("policy has invalid proxy port value: 0")
	}
	return nil
}

func logDuration(startTime time.Time, methodName string) {
	duration := time.Since(startTime)
	msg := fmt.Sprintf("[cni-net] %s took %s", methodName, duration)
	logrus.Info(msg)
}

func HnsProxyGetConfig() (*VfpRoutes, error) {
	defer logDuration(time.Now(), "getVfpRoutes")

	directoryOfExecutable, err := kos.ExecutableDir()
	if err != nil {
		panic(err)
	}

	routeConfJsonFp := directoryOfExecutable + "\\vfprules.json"
	routeConfJsonFile, err := os.Open(routeConfJsonFp)
	// if we os.Open returns an error then handle it
	if err != nil {
		errortext := fmt.Sprintf("[cni-net] Error: Unable to open file: %s. Reason: %s", routeConfJsonFp, err.Error())
		logrus.Error(errortext)
		return nil, errors.New(errortext)
	}
	defer routeConfJsonFile.Close()

	routesConfJsonBytes, err := ioutil.ReadAll(routeConfJsonFile)
	if err != nil {
		errortext := fmt.Sprintf("[cni-net] Error: Unable to read file: %s. Reason: %s", routeConfJsonFp, err.Error())
		logrus.Error(errortext)
		return nil, errors.New(errortext)
	}

	var vfpRoutes VfpRoutes

	err = json.Unmarshal(routesConfJsonBytes, &vfpRoutes)
	if err != nil {
		errortext := fmt.Sprintf("[cni-net] Error: Unable to unmarshall json file: %s. Reason: %s", routeConfJsonFp, err.Error())
		logrus.Error(errortext)
		return nil, errors.New(errortext)
	}

	return &vfpRoutes, nil
}

func HnsProxyAddPoliciesFromConfig(hnsEndpointID string) (err error) {
	logrus.Debugf("Add the policies from config for endpoint: " + hnsEndpointID)

	// retrieve configuration
	vfpRoutes, err1 := HnsProxyGetConfig()
	if err1 != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", err1)
		return err1
	}

	// create array objects
	var inboundportexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.InboundPortExceptions != "" {
		inboundportexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.InboundPortExceptions, ",")
	}
	var inboundaddressexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.InboundAddressExceptions != "" {
		inboundaddressexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.InboundAddressExceptions, ",")
	}
	var outboundportexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.OutboundPortExceptions != "" {
		outboundportexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.OutboundPortExceptions, ",")
	}
	var outboundaddressexceptionsArray []string
	if vfpRoutes.HnsProxyConfig.OutboundAddressExceptions != "" {
		outboundaddressexceptionsArray = strings.Split(vfpRoutes.HnsProxyConfig.OutboundAddressExceptions, ",")
	}

	// creaty an policy object and copy from vfpRoutes
	Userid := "S-1-5-32-556"
	policy := Policy{
		InboundProxyPort:          vfpRoutes.HnsProxyConfig.InboundProxyPort,
		OutboundProxyPort:         vfpRoutes.HnsProxyConfig.OutboundProxyPort,
		UserSID:                   Userid,
		LocalAddresses:            "",
		RemoteAddresses:           "",
		LocalPorts:                "",
		RemotePorts:               "",
		Priority:                  0,
		InboundPortExceptions:     inboundportexceptionsArray,
		InboundAddressExceptions:  inboundaddressexceptionsArray,
		OutboundPortExceptions:    outboundportexceptionsArray,
		OutboundAddressExceptions: outboundaddressexceptionsArray,
	}

	// write content of policy to console
	logrus.Debugf(fmt.Sprintf(" EndpointID:  %s\n", hnsEndpointID))
	logrus.Debugf(fmt.Sprintf(" policy.InboundProxyPort:  %s\n", policy.InboundProxyPort))
	logrus.Debugf(fmt.Sprintf(" policy.OutboundProxyPort: %s\n", policy.OutboundProxyPort))
	logrus.Debugf(fmt.Sprintf(" policy.UserSID:           %s\n", policy.UserSID))
	logrus.Debugf(fmt.Sprintf(" policy.LocalAddresses:    %s\n", policy.LocalAddresses))
	logrus.Debugf(fmt.Sprintf(" policy.RemoteAddresses:   %s\n", policy.RemoteAddresses))
	logrus.Debugf(fmt.Sprintf(" policy.LocalPorts:        %s\n", policy.LocalPorts))
	logrus.Debugf(fmt.Sprintf(" policy.RemotePorts:       %s\n", policy.RemotePorts))
	logrus.Debugf(fmt.Sprintf(" policy.Priority:          %d\n", policy.Priority))
	logrus.Debugf(fmt.Sprintf(" policy.Protocol:          %s\n", policy.Protocol))
	logrus.Debugf(fmt.Sprintf(" policy.InboundPortExceptions:     %v\n", policy.InboundPortExceptions))
	logrus.Debugf(fmt.Sprintf(" policy.InboundAddressExceptions:  %v\n", policy.InboundAddressExceptions))
	logrus.Debugf(fmt.Sprintf(" policy.OutboundPortExceptions:    %v\n", policy.OutboundPortExceptions))
	logrus.Debugf(fmt.Sprintf(" policy.OutboundAddressExceptions: %v\n", policy.OutboundAddressExceptions))

	// try to add the policy
	err2 := HnsProxyAddPolicy(hnsEndpointID, policy)
	if err2 != nil {
		log.Fatalf("Fatal error in adding the policy: %s", err2)
		return err2
	}

	return nil
}
