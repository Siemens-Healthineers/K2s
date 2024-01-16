// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package os

import (
	"context"
	"os"
	"os/exec"
	"time"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

type CliExecutor struct {
	proxy                string
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
}

func NewCli(proxy string, testStepTimeout time.Duration, testStepPollInterval time.Duration) *CliExecutor {
	return &CliExecutor{
		proxy:                proxy,
		testStepTimeout:      testStepTimeout,
		testStepPollInterval: testStepPollInterval,
	}
}

// Execute Command and verify it exits with exit code zero
func (c *CliExecutor) ExecOrFail(ctx context.Context, cliPath string, cliArgs ...string) string {
	cmd := exec.Command(cliPath, cliArgs...)

	return c.exec(ctx, cmd)
}

func (c *CliExecutor) ExecPathWithProxyOrFail(ctx context.Context, cliPath string, execPath string, cliArgs ...string) string {
	cmd := exec.Command(cliPath, cliArgs...)
	cmd.Dir = execPath

	if c.proxy != "" {
		GinkgoWriter.Println("Using proxy <", c.proxy, "> for command execution..")
		cmd.Env = os.Environ()
		cmd.Env = append(cmd.Env, "https_proxy="+c.proxy)
		cmd.Env = append(cmd.Env, "http_proxy="+c.proxy)
	}

	return c.exec(ctx, cmd)
}

func (c *CliExecutor) exec(ctx context.Context, cmd *exec.Cmd) string {
	session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)

	Expect(err).ToNot(HaveOccurred())

	Eventually(session,
		c.testStepTimeout,
		c.testStepPollInterval,
		ctx).Should(gexec.Exit(0), "Cmd '%v' exited with error exit code '%v'", session.Command, session.ExitCode())

	return string(session.Out.Contents())
}
