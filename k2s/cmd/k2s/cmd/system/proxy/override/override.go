package override

import "github.com/spf13/cobra"

var OverrideCmd = &cobra.Command{
	Use:   "override",
	Short: "Override command",
	Long:  "Override command is used to override certain settings",
	Run: func(cmd *cobra.Command, args []string) {
		// Add your command logic here
	},
}

func init() {
	OverrideCmd.AddCommand(overrideAddCmd)
	OverrideCmd.AddCommand(overrideDeleteCmd)
	OverrideCmd.AddCommand(overrideListCmd)
}
