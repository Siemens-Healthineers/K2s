package networkstatus

import (
	"context"
	"encoding/json"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestNetworkStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "network status CLI Command Acceptance Tests", Label("cli", "status", "network", "acceptance", "setup-required", "invasive", "setup=k2s", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("network status", Ordered, func() {
	Context("JSON output", func() {
		var result map[string]interface{}

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "status", "network", "-n", "kubemaster", "-o", "json")

			err := json.Unmarshal([]byte(output), &result)
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Println(output)
		})

		It("allcheckedpassed available", func() {

			allChecksPassed, ok := result["allcheckspassed"].(bool)
			Expect(ok).To(BeTrue())
			Expect(allChecksPassed).To(BeTrue())
		})
	})
})
