// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig

type Kubeconfig struct {
	Clusters       []ClusterConfig
	Users          []UserConfig
	Contexts       []ContextConfig
	CurrentContext string
}

type ClusterConfig struct {
	Name   string
	Cert   string
	Server string
}

type UserConfig struct {
	Name string
	Cert string
	Key  string
}

type ContextConfig struct {
	Name    string
	Cluster string
	User    string
}
