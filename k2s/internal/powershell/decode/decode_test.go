// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package decode_test

import (
	"encoding/base64"
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/powershell/decode"
)

func TestDecodePkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "decode pkg Unit Tests", Label("unit", "ci", "decode"))
}

var _ = Describe("decode pkg", func() {
	Describe("IsEncodedMessage", func() {
		When("message is not encoded", func() {
			It("returns false", func() {
				message := "not-encoded"

				actual := decode.IsEncodedMessage(message)

				Expect(actual).To(BeFalse())
			})
		})

		When("message is encoded", func() {
			It("returns true", func() {
				message := "#pm#some-payload"

				actual := decode.IsEncodedMessage(message)

				Expect(actual).To(BeTrue())
			})
		})
	})

	Describe("DecodeMessage", func() {
		When("message is malformed", func() {
			It("returns error", func() {
				message := "malformed"
				messageType := "test"

				actual, err := decode.DecodeMessage(message, messageType)

				Expect(err).To(MatchError(ContainSubstring("malformed")))
				Expect(actual).To(BeNil())
			})
		})

		When("message type does not match", func() {
			It("returns error", func() {
				message := "##wrong-type#"
				messageType := "test"

				actual, err := decode.DecodeMessage(message, messageType)

				Expect(err).To(MatchError(ContainSubstring("type mismatch")))
				Expect(actual).To(BeNil())
			})
		})

		When("base64 decoding failes", func() {
			It("returns error", func() {
				message := "##test#invalid-base64"
				messageType := "test"

				actual, err := decode.DecodeMessage(message, messageType)

				var decodingErr base64.CorruptInputError
				Expect(errors.As(err, &decodingErr)).To(BeTrue())
				Expect(actual).To(BeNil())
			})
		})

		When("uncompression failes", func() {
			It("returns error", func() {
				message := "##test#cGF5bG9hZA=="
				messageType := "test"

				actual, err := decode.DecodeMessage(message, messageType)

				Expect(err).To(MatchError(ContainSubstring("unexpected EOF")))
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			It("returns message", func() {
				message := "##test#H4sIAAAAAAAAAytJLS7RzU0tLk5MTwUAWnKJhAwAAAA="
				messageType := "test"

				actual, err := decode.DecodeMessage(message, messageType)

				Expect(err).ToNot(HaveOccurred())
				Expect(string(actual)).To(Equal("test-message"))
			})
		})
	})
})
