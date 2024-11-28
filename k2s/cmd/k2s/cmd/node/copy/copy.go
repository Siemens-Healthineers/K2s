// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package copy

import (
	"errors"
	"fmt"
	"time"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/core/node"
	nodecopy "github.com/siemens-healthineers/k2s/internal/core/node/copy"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	reverseFlag     = "reverse"
	ipAddressFlag   = "ip-addr"
	sourceFlag      = "source"
	targetFlag      = "target"
	usernameFlag    = "username"
	timeoutFlag     = "timeout"
	portFlag        = "port"
	longDescription = `Copies files/folders to/from nodes (default: to node).

The copy command behaves similar to the 'cp' command on Linux:
- If the target file exists, it will be overwritten without prompting.
- If the target folder does not exist, it gets created when the target's parent folder exists.
- If the target contains a folder with the same name as the source folder, all files will be copied into it, overwriting existing files that match the source files.
	
Remote node paths can but do not need to contain a tilde (~) since the working directory will always be the home directory of the node user, e.g.
'~/my-file' equals to 'my-file' equals to '/home/<user>/my-file' (Linux) or 'c:\users\<user>\my-file' (Windows). Locally (on the host), the working directory is the current working directory of the command execution.
`
	example = `# Copy a file from host to node, e.g. to home dir
	k2s node copy -i 192.168.1.2 -u remote -s C:\path\to\my-file -t ~/

	- or -

	k2s node copy -i 192.168.1.2 -u remote -s C:\path\to\my-file -t ~/my-file	


# Copy a folder from host to node, e.g. to home dir
	k2s node copy -i 192.168.1.2 -u remote -s C:\path\to\my-folder\ -t ~/


# Copy a file from node to host, e.g. from home dir on node
	k2s node copy -r -i 192.168.1.2 -u remote -s my-file -t C:\temp\my-file


# Copy a folder from node to host, e.g. from home dir on node
	k2s node copy -r -i 192.168.1.2 -u remote -s my-folder/ -t C:\temp\
`
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "copy",
		Short:   "[EXPERIMENTAL] Copies files/folders between host and nodes.",
		Long:    longDescription,
		Example: example,
		RunE:    copy,
	}

	cmd.Flags().StringP(ipAddressFlag, "i", "", "[required] Node IP address")
	cmd.Flags().StringP(usernameFlag, "u", "", "[required] Username for remote connection")
	cmd.Flags().StringP(sourceFlag, "s", "", "[required] Source file or folder to copy")
	cmd.Flags().StringP(targetFlag, "t", "", "[required] Target file or folder")

	cmd.MarkFlagRequired(ipAddressFlag)
	cmd.MarkFlagRequired(usernameFlag)
	cmd.MarkFlagRequired(sourceFlag)
	cmd.MarkFlagRequired(targetFlag)

	cmd.Flags().BoolP(reverseFlag, "r", false, "Copy from node to host (i.e. reverse direction)")
	cmd.Flags().Uint16P(portFlag, "p", ssh.DefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, "30s", "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func copy(cmd *cobra.Command, args []string) error {
	copyOptions, connectionOptions, err := extractOptions(cmd.Flags())
	if err != nil {
		return fmt.Errorf("failed to extract copy options: %w", err)
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

	err = node.Copy(*copyOptions, *connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to copy: %w", err)
	}

	pterm.Printfln("Command '%s' done.", cmd.Use) // TODO: align with other cmds

	return nil
}

func extractOptions(flags *pflag.FlagSet) (*nodecopy.CopyOptions, *ssh.ConnectionOptions, error) {
	ipAddress, err := flags.GetString(ipAddressFlag)
	if err != nil {
		return nil, nil, err
	}

	source, err := flags.GetString(sourceFlag)
	if err != nil {
		return nil, nil, err
	}

	target, err := flags.GetString(targetFlag)
	if err != nil {
		return nil, nil, err
	}

	reverse, err := flags.GetBool(reverseFlag)
	if err != nil {
		return nil, nil, err
	}

	direction := nodecopy.CopyToNode
	if reverse {
		direction = nodecopy.CopyFromNode
	}

	username, err := flags.GetString(usernameFlag)
	if err != nil {
		return nil, nil, err
	}

	port, err := flags.GetUint16(portFlag)
	if err != nil {
		return nil, nil, err
	}

	timeoutValue, err := flags.GetString(timeoutFlag)
	if err != nil {
		return nil, nil, err
	}

	timeout, err := time.ParseDuration(timeoutValue)
	if err != nil {
		return nil, nil, err
	}

	return &nodecopy.CopyOptions{
			Source:    source,
			Target:    target,
			Direction: direction,
		}, &ssh.ConnectionOptions{
			IpAddress:  ipAddress,
			RemoteUser: username,
			Timeout:    timeout,
			Port:       port,
		}, nil
}
