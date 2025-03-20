// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
)

type K2s struct {
	suite *framework.K2sTestSuite
}

type K2sCmdResult struct {
	output   string
	exitCode cli.ExitCode
}

func NewK2s(suite *framework.K2sTestSuite) *K2s {
	return &K2s{
		suite: suite,
	}
}
