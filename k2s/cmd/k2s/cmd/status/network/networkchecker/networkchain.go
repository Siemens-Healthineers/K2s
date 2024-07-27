// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker

type NetworkCheckChain struct {
	firstHandler ObservableNetworkChecker
}

func (c *NetworkCheckChain) SetFirstHandler(handler ObservableNetworkChecker) {
	c.firstHandler = handler
}

func (c *NetworkCheckChain) CheckConnectivity() (*NetworkCheckResult, error) {
	if c.firstHandler != nil {
		return c.firstHandler.CheckConnectivity()
	}
	return nil, nil
}
