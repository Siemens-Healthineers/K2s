// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8s

import (
	"encoding/base64"
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/primitives/arrays"
	"github.com/siemens-healthineers/k2s/internal/yaml"
)

type CmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}

type RestClient interface {
	SetTlsClientConfig(caCert []byte, userCert []byte, userKey []byte) error
	Post(url string, payload any, result any) error
}

type Clusters []ClusterConf
type Users []UserConf

type KubeconfigFile struct {
	path string
	exec CmdExecutor
	rest RestClient
}

type KubeconfigRoot struct {
	Clusters       []ClusterConf `yaml:"clusters"`
	Users          []UserConf    `yaml:"users"`
	CurrentContext string        `yaml:"current-context"`
}

type ClusterConf struct {
	Name    string  `yaml:"name"`
	Cluster Cluster `yaml:"cluster"`
}

type Cluster struct {
	Cert   string `yaml:"certificate-authority-data"`
	Server string `yaml:"server"`
}

type UserConf struct {
	Name string     `yaml:"name"`
	User UserDetail `yaml:"user"`
}

type UserDetail struct {
	Cert string `yaml:"client-certificate-data"`
	Key  string `yaml:"client-key-data"`
}

type SelfSubjectReview struct {
	Kind       string     `json:"kind"`
	ApiVersion string     `json:"apiVersion"`
	Metadata   Metadata   `json:"metadata"`
	Status     AuthStatus `json:"status"`
}

type Metadata struct {
	Timestamp *string `json:"creationTimestamp"`
}

type AuthStatus struct {
	UserInfo UserInfo `json:"userInfo"`
}

type UserInfo struct {
	Name   string   `json:"username"`
	Groups []string `json:"groups"`
}

const whoAmIRequestUrlPart = "/apis/authentication.k8s.io/v1/selfsubjectreviews"

func NewKubeconfigFile(path string, cmdExecutor CmdExecutor, restClient RestClient) *KubeconfigFile {
	return &KubeconfigFile{
		path: path,
		exec: cmdExecutor,
		rest: restClient,
	}
}

func (k *KubeconfigFile) Path() string {
	return k.path
}

func (k *KubeconfigFile) SetCluster(clusterConfig *ClusterConf) error {
	slog.Debug("Setting cluster in kubeconfig", "path", k.path)

	// implicitly creates kubeconfig when not existing
	if err := k.execConfCmd("set-cluster", clusterConfig.Name, "--server", clusterConfig.Cluster.Server); err != nil {
		return fmt.Errorf("could not set cluster config: %w", err)
	}

	certJsonPath := fmt.Sprintf("clusters.%s.certificate-authority-data", clusterConfig.Name)

	// kubectl config set-cluster does not support in-memory cert data, therefor the cert data is set separately
	if err := k.execConfCmd("set", certJsonPath, clusterConfig.Cluster.Cert); err != nil {
		return fmt.Errorf("could not set cluster cert config: %w", err)
	}
	return nil
}

func (k *KubeconfigFile) SetCredentials(username string, certPath string, keyPath string) error {
	slog.Debug("Setting credentials in kubeconfig", "path", k.path, "username", username, "cert-path", certPath, "key-path", keyPath)

	if err := k.execConfCmd("set-credentials", username, "--client-certificate", certPath, "--client-key", keyPath, "--embed-certs=true"); err != nil {
		return fmt.Errorf("could not set user credentials: %w", err)
	}
	return nil
}

func (k *KubeconfigFile) SetContext(context string, username string, clusterName string) error {
	slog.Debug("Setting context in kubeconfig", "path", k.path, "context", context, "username", username, "cluster-name", clusterName)

	clusterParam := "--cluster=" + clusterName
	userParam := "--user=" + username

	if err := k.execConfCmd("set-context", context, clusterParam, userParam); err != nil {
		return fmt.Errorf("could not set context '%s': %w", context, err)
	}
	return nil
}

func (k *KubeconfigFile) UseContext(context string) error {
	slog.Debug("Setting active context in kubeconfig", "path", k.path, "context", context)

	if err := k.execConfCmd("use-context", context); err != nil {
		return fmt.Errorf("could not use context '%s': %w", context, err)
	}
	return nil
}

func (k *KubeconfigFile) ReadFile() (*KubeconfigRoot, error) {
	slog.Debug("Reading kubeconfig", "path", k.path)

	config, err := yaml.FromFile[KubeconfigRoot](k.path)
	if err != nil {
		return nil, fmt.Errorf("could not read kubeconfig '%s': %w", k.path, err)
	}
	return config, nil
}

func (k *KubeconfigFile) TestClusterAccess(username string, clusterName string, expectedGroup string, kubeconfig *KubeconfigRoot) error {
	userConfig, clusterConfig, err := extractConfig(username, clusterName, kubeconfig)
	if err != nil {
		return fmt.Errorf("could not extract cluster/user config from kubeconfig: %w", err)
	}

	caCert, userCert, userKey, err := extractCertInfo(userConfig, clusterConfig)
	if err != nil {
		return fmt.Errorf("could not extract cert/key info from cluster/user config: %w", err)
	}

	if err := k.rest.SetTlsClientConfig(caCert, userCert, userKey); err != nil {
		return fmt.Errorf("could not set TLS client config from cluster/user config: %w", err)
	}

	whoAmIRequest := newWhoAmIRequest()
	url := clusterConfig.Server + whoAmIRequestUrlPart

	var whoAmIResponse SelfSubjectReview
	if err := k.rest.Post(url, whoAmIRequest, &whoAmIResponse); err != nil {
		return fmt.Errorf("could not post who-am-I request to K8s API: %w", err)
	}
	return validateWhoAmIResponse(username, expectedGroup, &whoAmIResponse)
}

func (clusters Clusters) Find(name string) (*ClusterConf, error) {
	conf, found := lo.Find(clusters, func(c ClusterConf) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("cluster '%s' not found in config", name)
	}
	return &conf, nil
}

func (users Users) Find(name string) (*UserConf, error) {
	conf, found := lo.Find(users, func(c UserConf) bool {
		return c.Name == name
	})
	if !found {
		return nil, fmt.Errorf("user '%s' not found in config", name)
	}
	return &conf, nil
}

func extractCertInfo(userConfig *UserDetail, clusterConfig *Cluster) (caCert []byte, userCert []byte, userKey []byte, err error) {
	caCert, err = base64.StdEncoding.DecodeString(clusterConfig.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not decode cluster cert: %w", err)
	}

	userCert, err = base64.StdEncoding.DecodeString(userConfig.Cert)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not decode user cert: %w", err)
	}

	userKey, err = base64.StdEncoding.DecodeString(userConfig.Key)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not decode user key: %w", err)
	}
	return
}

func validateWhoAmIResponse(expectedUsername string, expectedGroup string, whoAmIResponse *SelfSubjectReview) error {
	if !lo.Contains(whoAmIResponse.Status.UserInfo.Groups, expectedGroup) {
		return fmt.Errorf("user '%s' not part of the group '%s'", expectedUsername, expectedGroup)
	}

	if whoAmIResponse.Status.UserInfo.Name != expectedUsername {
		return fmt.Errorf("confirmed user name '%s' does not match given user name '%s'", whoAmIResponse.Status.UserInfo.Name, expectedUsername)
	}
	return nil
}

func extractConfig(username string, clusterName string, kubeconfig *KubeconfigRoot) (*UserDetail, *Cluster, error) {
	userConfig, err := Users(kubeconfig.Users).Find(username)
	if err != nil {
		return nil, nil, err
	}

	clusterConfig, err := Clusters(kubeconfig.Clusters).Find(clusterName)
	if err != nil {
		return nil, nil, err
	}
	return &userConfig.User, &clusterConfig.Cluster, nil
}

func newWhoAmIRequest() *SelfSubjectReview {
	return &SelfSubjectReview{
		Kind:       "SelfSubjectReview",
		ApiVersion: "authentication.k8s.io/v1",
		Metadata:   Metadata{},
		Status:     AuthStatus{UserInfo: UserInfo{}},
	}
}

func (k *KubeconfigFile) execConfCmd(params ...string) error {
	slog.Debug("Executing 'kubectl config' cmd", "params-len", len(params))

	params = arrays.Insert(params, "config", 0)
	params = append(params, "--kubeconfig", k.path)

	if err := k.exec.ExecuteCmd("kubectl", params...); err != nil {
		return fmt.Errorf("could not execute 'kubectl config' cmd: %w", err)
	}
	return nil
}
