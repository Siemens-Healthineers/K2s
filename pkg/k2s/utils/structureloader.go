// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package utils

import (
	"errors"
	"fmt"
	"k2s/providers/marshalling"

	"k8s.io/klog/v2"
)

func LoadStructure[T any](psScriptPath string, msgType string, additionalParams ...string) (v T, err error) {
	psExecutor := NewPsExecutor()

	cmd := psScriptPath + " -EncodeStructuredOutput -MessageType " + msgType
	if len(additionalParams) > 0 {
		for _, param := range additionalParams {
			cmd += " " + param
		}
	}

	klog.V(4).Infoln("PS command created:", cmd)

	messages, err := psExecutor.ExecuteWithStructuredResultData(cmd)
	if err != nil {
		return v, fmt.Errorf("could not load structure: %s", err)
	}

	if len(messages) != 1 {
		errorMessage := fmt.Sprintf("unexpected number of messages. Expected 1, but got %d", len(messages))

		return v, errors.New(errorMessage)
	}

	message := messages[0]

	if message.Type() != msgType {
		errorMessage := fmt.Sprintf("unexpected message type. Expected '%s', but got '%s'", msgType, message.Type())

		return v, errors.New(errorMessage)
	}

	klog.V(4).Infoln("unmarshalling message..")

	marshaller := marshalling.NewJsonUnmarshaller()

	err = marshaller.Unmarshal(message.Data(), &v)
	if err != nil {
		return v, fmt.Errorf("could not unmarshal structure: %s", err)
	}

	klog.V(4).Infoln("message unmarshalled")

	return v, nil
}
