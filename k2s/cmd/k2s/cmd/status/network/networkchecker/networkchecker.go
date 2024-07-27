// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker

// Interface for network check handlers
type NetworkChecker interface {
	CheckConnectivity() (*NetworkCheckResult, error)
	SetNext(handler NetworkChecker)
}

type ResultObserver interface {
	Update(result *NetworkCheckResult)
}

type ObservableNetworkChecker interface {
	NetworkChecker
	AddObserver(obs ResultObserver)
	NotifyObservers(result *NetworkCheckResult)
}

type ObserverManager struct {
	observers []ResultObserver
}

func (o *ObserverManager) AddObserver(obs ResultObserver) {
	o.observers = append(o.observers, obs)
}

func (o *ObserverManager) NotifyObservers(result *NetworkCheckResult) {
	for _, obs := range o.observers {
		obs.Update(result)
	}
}

type BaseNetworkChecker struct {
	next NetworkChecker
	ObserverManager
}

func (b *BaseNetworkChecker) SetNext(next NetworkChecker) {
	b.next = next
}

func (b *BaseNetworkChecker) CheckNext() (*NetworkCheckResult, error) {
	if b.next != nil {
		return b.next.CheckConnectivity()
	}
	return nil, nil
}
