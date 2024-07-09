// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/logging"
	ve "github.com/siemens-healthineers/k2s/internal/version"

	"github.com/google/uuid"
	"github.com/sirupsen/logrus"
)

type VfpRoute struct {
	Name     string `json:name`
	Subnet   string `json:subnet`
	Gateway  string `json:gateway`
	Priority string `json:priority`
}

type VfpRoutes struct {
	Routes []VfpRoute `json:routes`
}

func logDuration(startTime time.Time, methodName string) {
	duration := time.Since(startTime)
	msg := fmt.Sprintf("[cni-net] %s took %s", methodName, duration)
	logrus.Info(msg)
}

func GetPort(name string, logDir string) (string, error) {
	logrus.Debug("[cni-net] GetPort for port with name: ", name)
	// open file for writing ports
	filename := filepath.Join(logDir, "vfp-ports-"+name+".log")
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY, os.FileMode(0777))
	if err != nil {
		log.Fatalf("failed opening file: %s", err)
	}
	// construct `vfpctrl` command
	cmd := exec.Command("vfpctrl", "/list-vmswitch-port")
	cmd.Stdout = file
	// run command
	if err := cmd.Run(); err != nil {
		logrus.Error("[cni-net] Get port name. Error:", err)
		file.Close()
		return "", err
	} else {
		logrus.Debug("[cni-net] Get port name. Successfull\n")
	}
	file.Close()
	// read file line by line and parse
	readFile, err := os.Open(filename)
	if err != nil {
		logrus.Error("[cni-net] Get port name. Open file rrror:", err)
		return "", err
	}
	// scan the whole file
	scanner := bufio.NewScanner(readFile)
	scanner.Split(bufio.ScanLines)
	lastportname := ""
	found := false
	for scanner.Scan() {
		line := scanner.Text()
		s := strings.Split(line, ":")
		if len(s) > 1 {
			// keep port name
			param := strings.TrimSpace(s[0])
			if param == "Port name" {
				lastportname = s[1]
			}

			// check switch name
			if param == "Port Friendly name" {
				value := strings.TrimSpace(s[1])
				valuelower := strings.ToLower(value)
				namelower := strings.ToLower(name)
				logrus.Debugf("[cni-net] Compare '%s' with '%s'", valuelower, namelower)
				if valuelower == namelower {
					found = true
					break
				}
			}
		}
	}
	readFile.Close()
	// err = os.Remove(filename)
	// if err != nil {
	// 	logrus.Error("[cni-net] Get port name. Deleting file error:", err)
	// }
	if !found {
		logrus.Error("[cni-net] GetPort No entry yet found for portid:", portid)
		return "", errors.New("No entry found")
	}
	return strings.TrimSpace(lastportname), nil
}

func WriteVFPRule(datawriter *bufio.Writer, name string, port string, macgateway string, subnet string, priority string) error {
	// build args
	command := "C:\\Windows\\System32\\vfpctrl.exe /port " + port + " /layer VNET_PA_ROUTE_LAYER /group VNET_GROUP_PA_ROUTE_IPV4_OUT /add-rule-ex "
	rulex := "\"" + name + " " + name + " * * * " + subnet + " * 128 * " + priority + " transpose *,0/*,0 modify 00-00-00-00-00-00 " + macgateway + "\""
	// use echo to format correctly
	stringunformated := command + rulex
	bytes, errWrite := datawriter.WriteString(stringunformated + "\n")
	if errWrite != nil {
		log.Fatalf("failed writing file: %s, bytes: %s", errWrite, string(bytes))
	}
	return errWrite
}

func GetMacOfGateway(ipgateway string) (string, error) {
	logrus.Debug("[cni-net] GetMacOfGateway: ", ipgateway)
	// get all the system's or local machine's network interfaces
	var currentNetworkHardwareName string
	currentNetworkHardwareName = ""
	interfaces, _ := net.Interfaces()
	for _, interf := range interfaces {

		if addrs, err := interf.Addrs(); err == nil {
			for index, addr := range addrs {
				logrus.Debug("[cni-net] GetMacOfGateway [", index, "]", interf.Name, ">", addr)
				// only interested in the name with current IP address
				if strings.Contains(addr.String(), ipgateway) {
					logrus.Debug("[cni-net]   Use name : ", interf.Name)
					currentNetworkHardwareName = interf.Name
				}
			}
		}
	}

	if len(currentNetworkHardwareName) == 0 {
		logrus.Debug("[cni-net] GetMacOfGateway No gateway found with this ip: ", ipgateway)
		return "", errors.New("No gateway found as configured: " + ipgateway)
	}

	logrus.Debug("[cni-net] GetMacOfGateway -----------------------------> ", currentNetworkHardwareName)

	// extract the hardware information base on the interface name
	// capture above
	netInterface, err := net.InterfaceByName(currentNetworkHardwareName)
	if err != nil {
		fmt.Println(err)
		return "", err
	}
	name := netInterface.Name
	macAddress := netInterface.HardwareAddr
	logrus.Debug("[cni-net] GetMacOfGateway Hardware name : ", name)
	logrus.Debug("[cni-net] GetMacOfGateway MAC address : ", macAddress)

	// verify if the MAC address can be parsed properly
	hwAddr, err := net.ParseMAC(macAddress.String())
	if err != nil {
		logrus.Debug("[cni-net] GetMacOfGateway No able to parse MAC address: ", err)
		return "", err
	}
	macUpper := strings.ToUpper(hwAddr.String())
	returnMac := strings.Replace(macUpper, ":", "-", 5)
	logrus.Debugf("[cni-net] GetMacOfGateway Physical hardware address: %s \n", returnMac)
	return returnMac, err
}

func AddVfpRules(portid string, vfpRoutes *VfpRoutes, logDir string) error {
	// get the port related to id
	found, port := false, ""
	for i := 1; i < 30 && !found; i++ {
		var errPort error
		port, errPort = GetPort(portid, logDir)
		if errPort == nil {
			logrus.Debugf("[cni-net] Result of port name:'%s'", port)
			found = true
			break
		}
		time.Sleep(1000 * time.Millisecond)
	}
	// check if port was found
	if !found {
		logrus.Error("[cni-net] Error: Port with id:'%s' was not found", port)
		return errors.New("Port was not found")
	}

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

	logrus.Debug("[cni-net] Command file should be available:", filename)

	// try more times if needed
	execution := false
	for j := 1; j < 4 && !execution; j++ {
		// construct command for execution
		cmd := exec.Command("cmd", "/c", filename)
		// run command
		if output, err := cmd.Output(); err != nil {
			logrus.Warning("[cni-net] Adding extra VFP rules. Warning:", err)
			cmd.Wait()
			logrus.Warning("[cni-net] Adding extra VFP rules, will retry ...")
		} else {
			logrus.Debugf("[cni-net] Adding extra VFP rules. Output: %s\n", output)
			cmd.Wait()
			execution = true
			break
		}
		time.Sleep(1000 * time.Millisecond)
	}
	// check if port was found
	if !execution {
		errortext := "[cni-net] Error: Was unable to execute file:" + filename
		logrus.Error(errortext)
		return errors.New(errortext)
	}

	logrus.Debugf("[cni-net] Command file was executed successfully: %s\n", filename)

	// remove old vfp rules cmd file
	// os.Remove(filename)
	return nil
}

func IsValidUUID(u string) bool {
	_, err := uuid.Parse(u)
	return err == nil
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

func getVfpRoutes() (*VfpRoutes, error) {
	defer logDuration(time.Now(), "getVfpRoutes")
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

var portid = ""

const cliName = "vfprules"

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

func main() {

	version := flag.Bool("version", false, "show the current version of the CLI")
	// parameter for portid
	flag.StringVar(&portid, "portid", portid, "portid of the new port created (GUID)")
	flag.Parse()

	if *version {
		printCLIVersion()
		os.Exit(0)
	}

	fmt.Println("VFPRules started with portid:", portid)

	// check portid
	if IsValidUUID(portid) {
		fmt.Println("VFPRules starting with portid:", portid)
	} else {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage of %s:\n", os.Args[0])
		flag.PrintDefaults()
		return
	}

	logrus.SetFormatter(&logrus.TextFormatter{
		DisableColors: true,
		FullTimestamp: true,
	})
	logrus.SetLevel(logrus.DebugLevel)

	logDir := filepath.Join(logging.RootLogDir(), "vfprules")
	logFilePath := filepath.Join(logDir, "vfprules-"+portid+".log")

	if host.PathExists(logFilePath) {
		if err := os.Remove(logFilePath); err != nil {
			log.Fatalf("cannot remove log file '%s': %s", logFilePath, err)
		}
	}

	logFile := logging.InitializeLogFile(logFilePath)
	defer logFile.Close()
	logrus.SetOutput(logFile)

	// first log entry
	logrus.Debug("VFPRules started with portid:", portid)
	logrus.Debug("VFPRules logs in:", logFilePath)

	vfpRoutes, err := getVfpRoutes()
	if err != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", err)
	}

	// call to add the vfp rules
	errAdd := AddVfpRules(portid, vfpRoutes, logDir)
	if errAdd != nil {
		log.Fatalf("Fatal error in applying the vfp rules: %s", errAdd)
	}

	// remove older files
	oldfiles, erroldfiles := findFilesOlderThanOneDay(logDir)
	if erroldfiles == nil {
		for _, filetodelete := range oldfiles {
			logrus.Debug("Delete file:", filetodelete.Name())
			os.Remove(filepath.Join(logDir, filetodelete.Name()))
		}
	}

	// print final message
	fmt.Printf("VFPRules finished, please checks logs in %s\n", filepath.Join(logDir, logFilePath))
}

func init() {
	var err error
	directoryOfExecutable, err = host.ExecutableDir()
	if err != nil {
		panic(err)
	}
}

var directoryOfExecutable string
