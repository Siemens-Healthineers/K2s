// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package api

import (
	"fmt"
	"log/slog"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/definitions"
)

type restClient interface {
	SetTLSConfig(caCert, userCert, userKey []byte) error
	Post(url string, payload any, result any) error
}

type ApiAccessVerifier struct {
	restClient restClient
}

type SelfSubjectReview struct {
	Kind       string     `json:"kind"`
	ApiVersion string     `json:"apiVersion"`
	Metadata   metadata   `json:"metadata"`
	Status     AuthStatus `json:"status"`
}

type metadata struct {
	Timestamp *string `json:"creationTimestamp"`
}

type AuthStatus struct {
	UserInfo UserInfo `json:"userInfo"`
}

type UserInfo struct {
	Name   string   `json:"username"`
	Groups []string `json:"groups"`
}

const whoAmIRequestUrlRoute = "/apis/authentication.k8s.io/v1/selfsubjectreviews"

func NewApiAccessVerifier(restClient restClient) *ApiAccessVerifier {
	return &ApiAccessVerifier{
		restClient: restClient,
	}
}

func (v *ApiAccessVerifier) VerifyAccess(userName, server string, caCert, userCert, userKey []byte) error {
	slog.Debug("Verifying Kubernetes API access", "user-name", userName)

	if err := v.restClient.SetTLSConfig(caCert, userCert, userKey); err != nil {
		return fmt.Errorf("failed to set http client TLS config: %w", err)
	}

	request := newWhoAmIRequest()
	url := server + whoAmIRequestUrlRoute

	var response SelfSubjectReview
	if err := v.restClient.Post(url, request, &response); err != nil {
		return fmt.Errorf("failed to POST who-am-I request to K8s API '%s': %w", url, err)
	}

	if !lo.Contains(response.Status.UserInfo.Groups, definitions.K2sUserGroup) {
		return fmt.Errorf("user '%s' not part of the group '%s'", userName, definitions.K2sUserGroup)
	}

	if response.Status.UserInfo.Name != userName {
		return fmt.Errorf("confirmed user name '%s' does not match given user name '%s'", response.Status.UserInfo.Name, userName)
	}

	slog.Debug("Kubernetes API access verified", "user-name", userName)
	return nil
}

func newWhoAmIRequest() *SelfSubjectReview {
	return &SelfSubjectReview{
		Kind:       "SelfSubjectReview",
		ApiVersion: "authentication.k8s.io/v1",
		Metadata:   metadata{},
		Status:     AuthStatus{UserInfo: UserInfo{}},
	}
}
