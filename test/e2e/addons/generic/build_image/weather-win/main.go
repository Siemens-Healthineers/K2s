// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package main

import (
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
)

type weather struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Temp string `json:"temp"`
}

var weatherSummary = []weather{
	{ID: "1", Name: "New York", Temp: "15"},
	{ID: "2", Name: "Frankfurt", Temp: "10"},
	{ID: "3", Name: "Bangalore", Temp: "26"},
}

func main() {
	resource, found := os.LookupEnv("RESOURCE")
	if !found {
		resource = "weather-win"
	}
	router := gin.Default()
	router.SetTrustedProxies(nil)
	router.GET("/"+resource+"/ping", ping)
	router.GET("/"+resource, getWeather)
	router.GET("/"+resource+"/:id", getWeatherByID)

	router.Run()
}

func ping(c *gin.Context) {
	c.IndentedJSON(http.StatusOK, "pong")
}

func getWeather(c *gin.Context) {
	c.IndentedJSON(http.StatusOK, weatherSummary)
}

func getWeatherByID(c *gin.Context) {
	id := c.Param("id")

	for _, a := range weatherSummary {
		if a.ID == id {
			c.IndentedJSON(http.StatusOK, a)
			return
		}
	}
	c.IndentedJSON(http.StatusNotFound, gin.H{"message": "weather result not found"})
}
