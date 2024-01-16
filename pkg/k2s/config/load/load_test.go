// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load_test

import (
	"errors"
	"testing"

	cd "k2s/config/defs"
	"k2s/config/load"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type testReader struct {
	result []byte
	err    error
}

type testUnmarshaller struct {
	resultConfig      *cd.Config
	resultSetupConfig *cd.SetupConfig
	err               error
}

func (t testReader) Read(filename string) ([]byte, error) {
	return t.result, t.err
}

func (t testUnmarshaller) Unmarshal(data []byte, v any) error {
	if t.err != nil {
		return t.err
	}

	if t.resultConfig != nil {
		ptr, ok := v.(**cd.Config)

		if !ok {
			return errors.New("Conversion error")
		}

		*ptr = t.resultConfig

		return nil
	} else if t.resultSetupConfig != nil {
		ptr, ok := v.(**cd.SetupConfig)

		if !ok {
			return errors.New("Conversion error")
		}

		*ptr = t.resultSetupConfig

		return nil
	}

	return errors.New("No expected test result defined.")
}

func TestLoad(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "load Unit Tests", Label("unit"))
}

var _ = Describe("load", func() {
	Describe("Load", func() {
		When("file read error occurred", func() {
			It("returns the error", func() {
				reader := &testReader{err: errors.New("oops")}
				sut := load.NewConfigLoader(reader, nil)

				actual, err := sut.Load("some path")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(reader.err))
			})
		})

		When("unmarshal error occurred", func() {
			It("returns the error", func() {
				reader := &testReader{}
				unmarshaller := &testUnmarshaller{err: errors.New("oops")}
				sut := load.NewConfigLoader(reader, unmarshaller)

				actual, err := sut.Load("some path")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(unmarshaller.err))
			})
		})

		It("returns correct result", func() {
			config := &cd.Config{SmallSetup: cd.SmallSetupConfig{ConfigDir: cd.ConfigDir{Kube: "test"}}}
			reader := &testReader{}
			unmarshaller := &testUnmarshaller{resultConfig: config}
			sut := load.NewConfigLoader(reader, unmarshaller)

			actual, err := sut.Load("some path")

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).ToNot(BeNil())
			Expect(actual.SmallSetup.ConfigDir.Kube).To(Equal(config.SmallSetup.ConfigDir.Kube))
		})
	})

	Describe("LoadForSetup", func() {
		When("file read error occurred", func() {
			It("returns the error", func() {
				reader := &testReader{err: errors.New("oops")}
				sut := load.NewConfigLoader(reader, nil)

				actual, err := sut.LoadForSetup("some path")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(reader.err))
			})
		})

		When("unmarshal error occurred", func() {
			It("returns the error", func() {
				reader := &testReader{}
				unmarshaller := &testUnmarshaller{err: errors.New("oops")}
				sut := load.NewConfigLoader(reader, unmarshaller)

				actual, err := sut.LoadForSetup("some path")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(unmarshaller.err))
			})
		})

		It("returns correct result", func() {
			config := &cd.SetupConfig{SetupType: "test"}
			reader := &testReader{}
			unmarshaller := &testUnmarshaller{resultSetupConfig: config}
			sut := load.NewConfigLoader(reader, unmarshaller)

			actual, err := sut.LoadForSetup("some path")

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).ToNot(BeNil())
			Expect(actual.SetupType).To(Equal(config.SetupType))
		})
	})
})
