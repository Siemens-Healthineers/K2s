// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	outFilePath := flag.String("outfile", "out.file", "The output file path")
	interval := flag.Int("interval", 1000, "The write interval in milliseconds")

	flag.Parse()

	log.Println("diskwriter started with outfilepath <", *outFilePath, "> and interval <", *interval, ">")

	for {
		log.Println("Writing to file..")

		file, err := os.OpenFile(*outFilePath, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
		if err != nil {
			log.Fatal(err)
		}

		line := fmt.Sprintf("%v\n", time.Now())

		log.Print(line)

		_, err = file.WriteString(line)
		if err != nil {
			log.Fatal(err)
		}

		err = file.Close()
		if err != nil {
			log.Fatal(err)
		}

		log.Println("Written to file, sleeping now..")

		time.Sleep(time.Millisecond * time.Duration(*interval))
	}
}
