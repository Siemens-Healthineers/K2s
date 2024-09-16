// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cluster

import (
	"encoding/base64"
	"fmt"

	"github.com/samber/lo"
)

type restClient interface {
	SetTlsClientConfig(caCert []byte, userCert []byte, userKey []byte) error
	Post(url string, payload any, result any) error
}

type UserParam struct {
	Name  string
	Group string
	Key   string
	Cert  string
}

type ClusterParam struct {
	Cert   string
	Server string
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

type clusterAccess struct {
	client restClient
}

const whoAmIRequestUrlPart = "/apis/authentication.k8s.io/v1/selfsubjectreviews"

func NewClusterAccess(restClient restClient) *clusterAccess {
	return &clusterAccess{
		client: restClient,
	}
}

func (c *clusterAccess) VerifyAccess(userConfig *UserParam, clusterConfig *ClusterParam) error {
	caCert, userCert, userKey, err := extractCertInfo(userConfig, clusterConfig.Cert)
	if err != nil {
		return fmt.Errorf("could not extract cert/key info from cluster/user config: %w", err)
	}

	if err := c.client.SetTlsClientConfig(caCert, userCert, userKey); err != nil {
		return fmt.Errorf("could not set TLS client config from cluster/user config: %w", err)
	}

	whoAmIRequest := newWhoAmIRequest()
	url := clusterConfig.Server + whoAmIRequestUrlPart

	var whoAmIResponse SelfSubjectReview
	if err := c.client.Post(url, whoAmIRequest, &whoAmIResponse); err != nil {
		return fmt.Errorf("could not post who-am-I request to K8s API: %w", err)
	}
	return validateWhoAmIResponse(userConfig, &whoAmIResponse)
}

func extractCertInfo(userConfig *UserParam, clusterCert string) (caCert []byte, userCert []byte, userKey []byte, err error) {
	caCert, err = base64.StdEncoding.DecodeString(clusterCert)
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

func validateWhoAmIResponse(userConfig *UserParam, whoAmIResponse *SelfSubjectReview) error {
	if !lo.Contains(whoAmIResponse.Status.UserInfo.Groups, userConfig.Group) {
		return fmt.Errorf("user '%s' not part of the group '%s'", userConfig.Name, userConfig.Group)
	}

	if whoAmIResponse.Status.UserInfo.Name != userConfig.Name {
		return fmt.Errorf("confirmed user name '%s' does not match given user name '%s'", whoAmIResponse.Status.UserInfo.Name, userConfig.Name)
	}
	return nil
}

func newWhoAmIRequest() *SelfSubjectReview {
	return &SelfSubjectReview{
		Kind:       "SelfSubjectReview",
		ApiVersion: "authentication.k8s.io/v1",
		Metadata:   Metadata{},
		Status:     AuthStatus{UserInfo: UserInfo{}},
	}
}
