// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

//go:build linux

package main

import (
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

// registerPlatformHandler registers Unix signal handlers for graceful shutdown.
func registerPlatformHandler() error {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		slog.Info("Signal received, shutting down.", "signal", sig)
		cleanupWg.Add(1)
		go func() {
			defer cleanupWg.Done()
			if listener != nil {
				listener.Close()
			}
		}()
		cleanupWg.Wait()
	}()

	return nil
}
