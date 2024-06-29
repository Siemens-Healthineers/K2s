package override

import (
	"fmt"

	"github.com/spf13/cobra"
)

var overrideAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add an override",
	Run:   overrideAdd,
}

func overrideAdd(cmd *cobra.Command, args []string) {
	// Add your implementation here
	fmt.Println("Override add command executed")
}
