// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package exec

import (
	"errors"
	"fmt"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	cssh "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/providers/ssh"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

type cmdOptions struct {
	cmd               string
	connectionOptions cssh.ConnectionOptions
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

	cmd.Flags().Uint16P(portFlag, "p", definitions.SSHDefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, definitions.SSHDefaultTimeout.String(), "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")
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

	k2sConfig := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()
	_, err = config.ReadRuntimeConfig(k2sConfig.Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("failed to read setup config: %w", err)
	}

	cmdOptions.connectionOptions.SshPrivateKeyPath = k2sConfig.Host().SshConfig().CurrentPrivateKeyPath()

	err = ssh.Exec(cmdOptions.cmd, cmdOptions.connectionOptions)
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
		connectionOptions: cssh.ConnectionOptions{
			IpAddress:  ipAddress,
			RemoteUser: username,
			Timeout:    timeout,
			Port:       port,
		},
		rawOutput: rawOutput,
	}, nil
}
