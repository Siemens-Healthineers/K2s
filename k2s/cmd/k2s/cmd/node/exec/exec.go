// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package exec

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

type cmdOptions struct {
	cmd               string
	connectionOptions ssh.ConnectionOptions
	rawOutput         bool
}

const (
	ipAddressFlag   = "ip-addr"
	usernameFlag    = "username"
	commandFlag     = "command"
	timeoutFlag     = "timeout"
	portFlag        = "port"
	rawFlag         = "raw"
	longDescription = "Executes a command on a remote node."
	example         = `# Execute a command on Linux node
k2s node exec -i 172.19.1.100 -u remote -c "echo 'Hello, World!'"

# Execute a command on Linux node only printing the remote output
k2s node exec -i 172.19.1.100 -u remote -c "echo 'Hello, World!'" -r
`
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "exec",
		Short:   "[EXPERIMENTAL] Executes a command on a remote node.",
		Long:    longDescription,
		Example: example,
		RunE:    exec,
	}

	cmd.Flags().StringP(ipAddressFlag, "i", "", "[required] Node IP address")
	cmd.Flags().StringP(usernameFlag, "u", "", "[required] Username for remote connection")
	cmd.Flags().StringP(commandFlag, "c", "", "[required] Command to execute")

	cmd.MarkFlagRequired(ipAddressFlag)
	cmd.MarkFlagRequired(usernameFlag)
	cmd.MarkFlagRequired(commandFlag)

	cmd.Flags().Uint16P(portFlag, "p", ssh.DefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, ssh.DefaultTimeout.String(), "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")
	cmd.Flags().BoolP(rawFlag, "r", false, "Print only the remote output, no other information")

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func exec(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	cmdOptions, err := extractOptions(cmd.Flags())
	if err != nil {
		return fmt.Errorf("failed to extract exec options: %w", err)
	}

	config := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()
	_, err = setupinfo.ReadConfig(config.Host().K2sConfigDir())
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("failed to read setup config: %w", err)
	}

	cmdOptions.connectionOptions.SshKeyPath = ssh.SshKeyPath(config.Host().SshDir())

	err = node.Exec(cmdOptions.cmd, cmdOptions.connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to exec: %w", err)
	}

	cmdSession.Finish(cmdOptions.rawOutput)

	return nil
}

func extractOptions(flags *pflag.FlagSet) (*cmdOptions, error) {
	ipAddress, err := flags.GetString(ipAddressFlag)
	if err != nil {
		return nil, err
	}

	command, err := flags.GetString(commandFlag)
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

	rawOutput, err := flags.GetBool(rawFlag)
	if err != nil {
		return nil, err
	}

	return &cmdOptions{
		cmd: command,
		connectionOptions: ssh.ConnectionOptions{
			IpAddress:  ipAddress,
			RemoteUser: username,
			Timeout:    timeout,
			Port:       port,
		},
		rawOutput: rawOutput,
	}, nil
}
