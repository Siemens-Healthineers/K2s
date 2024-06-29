package proxy

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/proxy/override"
	"github.com/spf13/cobra"
)

var ProxyCmd = &cobra.Command{
	Use:   "proxy",
	Short: "Manage proxy settings",
	Long:  "This command allows you to manage proxy settings.",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your code here to handle the proxy command
	},
}

func init() {
	ProxyCmd.AddCommand(proxySetCmd)
	ProxyCmd.AddCommand(proxyGetCmd)
	ProxyCmd.AddCommand(proxyShowCmd)
	ProxyCmd.AddCommand(proxyResetCmd)
	ProxyCmd.AddCommand(override.OverrideCmd)
}
