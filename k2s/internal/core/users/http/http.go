// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package http

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
)

type restClient struct {
	httpClient *http.Client
}

func NewRestClient() *restClient {
	return &restClient{httpClient: &http.Client{}}
}

func (rc *restClient) SetTlsClientConfig(caCert []byte, userCert []byte, userKey []byte) error {
	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(caCert) {
		return errors.New("could not parse CA cert")
	}

	userCertKeyPair, err := tls.X509KeyPair(userCert, userKey)
	if err != nil {
		return fmt.Errorf("could not create user cert/key pair: %w", err)
	}

	rc.httpClient.Transport = &http.Transport{
		TLSClientConfig: &tls.Config{
			RootCAs:      certPool,
			Certificates: []tls.Certificate{userCertKeyPair},
		},
	}
	return nil
}

func (rc *restClient) Post(url string, payload any, result any) error {
	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("could not marshal json payload: %w", err)
	}

	bodyReader := bytes.NewReader(jsonBody)
	response, err := rc.httpClient.Post(url, "application/json", bodyReader)
	if err != nil {
		return fmt.Errorf("could not post json payload: %w", err)
	}

	defer func() {
		if err := response.Body.Close(); err != nil {
			slog.Error("could not close http response body", "error", err)
		}
	}()

	if response.StatusCode != http.StatusCreated {
		return fmt.Errorf("unexpected http status code: expected '%d', but got '%d'", http.StatusCreated, response.StatusCode)
	}

	bytes, err := io.ReadAll(response.Body)
	if err != nil {
		return fmt.Errorf("could not read response body: %w", err)
	}

	if err := json.Unmarshal(bytes, result); err != nil {
		return fmt.Errorf("could not unmarshal json response into given result variable: %w", err)
	}
	return nil
}
