// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package proxy

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

type ProxyConfig struct {
	HttpProxy  string
	HttpsProxy string
	NoProxy    []string
}

type ProxyConfigHandler interface {
	ReadConfig() (*ProxyConfig, error)
	SaveConfig(*ProxyConfig) error
	Reset() error
}

type fileProxyConfigHandler struct {
	filePath string
}

func NewFileProxyConfigHandler(filePath string) ProxyConfigHandler {
	return &fileProxyConfigHandler{
		filePath: filePath,
	}
}

func (p *fileProxyConfigHandler) ReadConfig() (*ProxyConfig, error) {
	file, err := os.Open(p.filePath)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	config := &ProxyConfig{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key, value := parts[0], parts[1]
		switch key {
		case "http_proxy":
			config.HttpProxy = value
		case "https_proxy":
			config.HttpsProxy = value
		case "no_proxy":
			if value != "" {
				config.NoProxy = strings.Split(value, ",")
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return config, nil
}

// ensureDir ensures that the directory for the file exists
func ensureDirExists(filePath string) error {
	dir := filepath.Dir(filePath)
	return os.MkdirAll(dir, 0755)
}

// ensureFile ensures that the file exists, creating it if necessary
func ensureFileExists(filePath string) error {
	_, err := os.Stat(filePath)
	if os.IsNotExist(err) {
		if err := ensureDirExists(filePath); err != nil {
			return err
		}
		file, err := os.Create(filePath)
		if err != nil {
			return err
		}
		file.Close()
	}
	return nil
}

func (p *fileProxyConfigHandler) SaveConfig(config *ProxyConfig) error {
	if err := ensureFileExists(p.filePath); err != nil {
		return err
	}

	file, err := os.OpenFile(p.filePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0666)
	if err != nil {
		return err
	}
	defer file.Close()

	// delete the previously written content
	file.Truncate(0)
	file.Seek(0, 0)

	writer := bufio.NewWriter(file)
	defer writer.Flush()

	_, err = writer.WriteString("http_proxy=" + config.HttpProxy + "\n")
	if err != nil {
		return err
	}

	_, err = writer.WriteString("https_proxy=" + config.HttpsProxy + "\n")
	if err != nil {
		return err
	}

	noProxy := strings.Join(config.NoProxy, ",")
	_, err = writer.WriteString("no_proxy=" + noProxy + "\n")
	if err != nil {
		return err
	}

	return nil
}

func (p *fileProxyConfigHandler) Reset() error {
	return p.SaveConfig(&ProxyConfig{})
}
