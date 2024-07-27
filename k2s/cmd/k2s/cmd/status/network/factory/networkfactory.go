// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package factory

import (
	netchecker "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/resultobserver"
)

type ClusterNetworkFactory struct{}

func (f *ClusterNetworkFactory) CreateNetworkCheckChain(handlers ...netchecker.ObservableNetworkChecker) *netchecker.NetworkCheckChain {
	for i := 0; i < len(handlers)-1; i++ {
		handlers[i].SetNext(handlers[i+1])
	}
	networkChain := &netchecker.NetworkCheckChain{}
	networkChain.SetFirstHandler(handlers[0])
	return networkChain
}

func (f *ClusterNetworkFactory) CreateResultObservers(outputType string) []netchecker.ResultObserver {
	var finalObservers []netchecker.ResultObserver
	if outputType == "json" {
		finalObservers = append(finalObservers, resultobserver.NewJSONLogObserver())
	} else {
		finalObservers = append(finalObservers, resultobserver.NewPrettyLogObserver())
	}

	return finalObservers
}
