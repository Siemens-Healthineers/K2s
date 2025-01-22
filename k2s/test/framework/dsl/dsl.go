// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

type K2s struct {
	suite *framework.K2sTestSuite
}

type K2sCmdResult struct {
	output   string
	exitCode k2s.ExitCode
}

func NewK2s(suite *framework.K2sTestSuite) *K2s {
	return &K2s{
		suite: suite,
	}
}
