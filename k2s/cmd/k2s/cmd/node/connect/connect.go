// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package connect

import (
	"errors"
	"fmt"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/core/node"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	ipAddressFlag   = "ip-addr"
	usernameFlag    = "username"
	timeoutFlag     = "timeout"
	portFlag        = "port"
	longDescription = `Connects to a remote node.

This command uses the pre-installed Windows OpenSSH client to connect to a remote node.

Since K2s does not maintain this ssh.exe, make sure it is up-to-date.
Check the client version with 'ssh -V'.
See also the OpenSSH release notes at https://www.openssh.com/releasenotes.html.
`
	example = `# Connect to a remote node
k2s node connect -i 192.168.1.2 -u remote
`
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "connect",
		Short:   "[EXPERIMENTAL] Connects to a remote node.",
		Long:    longDescription,
		Example: example,
		RunE:    connect,
	}

	cmd.Flags().StringP(ipAddressFlag, "i", "", "[required] Node IP address")
	cmd.Flags().StringP(usernameFlag, "u", "", "[required] Username for remote connection")

	cmd.MarkFlagRequired(ipAddressFlag)
	cmd.MarkFlagRequired(usernameFlag)

	cmd.Flags().Uint16P(portFlag, "p", ssh.DefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, ssh.DefaultTimeout.String(), "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func connect(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	connectionOptions, err := extractOptions(cmd.Flags())
	if err != nil {
		return fmt.Errorf("failed to extract connection options: %w", err)
	}

	config := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()
	_, err = setupinfo.ReadConfig(config.Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("failed to read setup config: %w", err)
	}

	connectionOptions.SshKeyPath = ssh.SshKeyPath(config.Host.SshDir)

	err = node.Connect(*connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	cmdSession.Finish()

	return nil
}

func extractOptions(flags *pflag.FlagSet) (*ssh.ConnectionOptions, error) {
	ipAddress, err := flags.GetString(ipAddressFlag)
	if err != nil {
		return nil, err
	}

	username, err := flags.GetString(usernameFlag)
	if err != nil {
		return nil, err
	}

	port, err := flags.GetUint16(portFlag)
	if err != nil {
		return nil, err
	}

	timeoutValue, err := flags.GetString(timeoutFlag)
	if err != nil {
		return nil, err
	}

	timeout, err := time.ParseDuration(timeoutValue)
	if err != nil {
		return nil, err
	}

	return &ssh.ConnectionOptions{
		IpAddress:  ipAddress,
		RemoteUser: username,
		Timeout:    timeout,
		Port:       port,
	}, nil
}
