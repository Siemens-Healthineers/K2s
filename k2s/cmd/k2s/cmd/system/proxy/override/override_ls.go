package override

import "github.com/spf13/cobra"

var overrideListCmd = &cobra.Command{
	Use:   "ls",
	Short: "List all overrides",
	Long:  "List all overrides in the system",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your logic here to list all overrides
	},
}
