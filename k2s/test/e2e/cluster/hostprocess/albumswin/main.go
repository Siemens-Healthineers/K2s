// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"syscall"
	"unsafe"

	// Sub Repositories

	"github.com/gin-gonic/gin"
)

// album represents data about a record album.
type album struct {
	ID     string  `json:"id"`
	Title  string  `json:"title"`
	Artist string  `json:"artist"`
	Price  float64 `json:"price"`
}

// albums slice to seed record album data.
var albums = []album{
	{ID: "1", Title: "Pawn Hearts", Artist: "Van der Graaf Generator", Price: 26.99},
	{ID: "2", Title: "A Passion Play", Artist: "Jethro Tull", Price: 17.99},
	{ID: "3", Title: "Tales from Topographic Oceans", Artist: "Yes", Price: 32.99},
}

var (
	kernel32         = syscall.NewLazyDLL("kernel32.dll")
	procVirtualAlloc = kernel32.NewProc("VirtualAlloc")
	procVirtualLock  = kernel32.NewProc("VirtualLock")
)

const (
	MEM_COMMIT     = 0x1000
	MEM_RESERVE    = 0x2000
	PAGE_READWRITE = 0x04
)

func allocatePhysicalMemory(gb int) ([]byte, error) {
	// 1 GB = 1024 * 1024 * 1024 bytes
	size := gb * 1024 * 1024 * 1024

	// Allocate memory using VirtualAlloc
	addr, _, err := procVirtualAlloc.Call(
		0,
		uintptr(size),
		MEM_RESERVE|MEM_COMMIT,
		PAGE_READWRITE,
	)
	if addr == 0 {
		return nil, fmt.Errorf("VirtualAlloc failed: %v", err)
	}

	// Convert the pointer to a slice safely
	mem := unsafe.Slice((*byte)(unsafe.Pointer(addr)), size)
	return mem, nil
}

var (
	netioapi                          = syscall.NewLazyDLL("iphlpapi.dll")
	procSetCurrentThreadCompartmentId = netioapi.NewProc("SetCurrentThreadCompartmentId")
)

func SetCurrentThreadCompartmentId(compartmentId uint32) error {
	ret, _, err := procSetCurrentThreadCompartmentId.Call(uintptr(compartmentId))
	if ret != 0 {
		return err
	}
	return nil
}

func DumpNetworkInterfaces() {
	// Get a list of all network interfaces
	interfaces, err := net.Interfaces()
	if err != nil {
		log.Fatalf("Failed to get network interfaces: %v", err)
	}

	fmt.Println("Network Interfaces:")
	fmt.Println("-------------------")

	if len(interfaces) == 0 {
		fmt.Println("No network interfaces found.")
		return
	}

	// Iterate over each interface
	for _, i := range interfaces {
		fmt.Printf("Name: %v\n", i.Name)
		fmt.Printf("  Hardware Address (MAC): %v\n", i.HardwareAddr)
		fmt.Printf("  Flags: %v\n", i.Flags.String())
		fmt.Printf("  MTU: %v\n", i.MTU)

		// Get the addresses associated with the interface
		addrs, err := i.Addrs()
		if err != nil {
			log.Printf("  Failed to get addresses for %v: %v\n", i.Name, err)
			continue
		}

		fmt.Println("  IP Addresses:")
		if len(addrs) == 0 {
			fmt.Println("    No IP addresses found for this interface.")
		} else {
			for _, addr := range addrs {
				var ip net.IP
				switch v := addr.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if ip == nil {
					continue
				}
				fmt.Printf("    - %s\n", ip.String())
			}
		}
		fmt.Println("-------------------")
	}
}

func main() {
	resource, found := os.LookupEnv("RESOURCE")
	if !found {
		resource = "albums-win"
	}
	memoryinGB, found := os.LookupEnv("MEMORY-GB")
	if !found {
		memoryinGB = "0"
	}

	// convert from string to int
	gb, err := strconv.Atoi(memoryinGB)
	if err != nil {
		fmt.Println("Error converting memory in GB to int:", err)
		gb = 0
	}

	// allocate memory GBs in RAM if memory is bigger than 0
	memory := make([]byte, 10)
	if gb > 0 {
		// allocate memory in RAM
		memory, err = allocatePhysicalMemory(gb)
		if err != nil {
			fmt.Println("Error:", err)
			return
		}

		// set the memory content to a fixed value
		for i := 0; i < len(memory); i++ {
			memory[i] = 0x41
		}
	}

	// get environment variables for bind address and port
	bindAddress := os.Getenv("BIND_ADDRESS")
	if bindAddress == "" {
		bindAddress = "0.0.0.0" // default address
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080" // default port
	}

	// get environment variables for bind address and port
	compartmentId := os.Getenv("COMPARTMENTID")
	// Set default values if environment variables are not set
	if compartmentId != "" {
		num, err := strconv.Atoi(compartmentId)
		if err == nil {
			fmt.Println("Using compartment id: ", compartmentId)
			err := SetCurrentThreadCompartmentId(uint32(num))
			if err != nil {
				fmt.Println("Failed to set compartment ID: %v", err)
			}
		}
	}

	// dump the network interfaces
	DumpNetworkInterfaces()

	// create the full address string
	addr := fmt.Sprintf("%s:%s", bindAddress, port)

	router := gin.Default()
	router.SetTrustedProxies(nil)
	router.GET("/"+resource, getAlbums)
	router.GET("/"+resource+"/:id", getAlbumByID)
	router.POST("/"+resource, postAlbums)
	router.Run(addr)
}

// getAlbums responds with the list of all albums as JSON.
func getAlbums(c *gin.Context) {
	c.IndentedJSON(http.StatusOK, albums)
}

// postAlbums adds an album from JSON received in the request body.
func postAlbums(c *gin.Context) {
	var newAlbum album

	// Call BindJSON to bind the received JSON to
	// newAlbum.
	if err := c.BindJSON(&newAlbum); err != nil {
		return
	}

	// Add the new album to the slice.
	albums = append(albums, newAlbum)
	c.IndentedJSON(http.StatusCreated, newAlbum)
}

// getAlbumByID locates the album whose ID value matches the id
// parameter sent by the client, then returns that album as a response.
func getAlbumByID(c *gin.Context) {
	id := c.Param("id")

	// Loop through the list of albums, looking for
	// an album whose ID value matches the parameter.
	for _, a := range albums {
		if a.ID == id {
			c.IndentedJSON(http.StatusOK, a)
			return
		}
	}
	c.IndentedJSON(http.StatusNotFound, gin.H{"message": "album not found"})
}
