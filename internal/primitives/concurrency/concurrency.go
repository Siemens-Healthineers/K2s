// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package concurrency

import (
	"errors"
	"sync"
)

// RunAll runs functions concurrently and returns the joined error of all failures.
func RunAll(funcs ...func() error) error {
	errs := make([]error, len(funcs))
	var tasks sync.WaitGroup
	tasks.Add(len(funcs))

	for i, fn := range funcs {
		go func(i int, fn func() error) {
			defer tasks.Done()
			errs[i] = fn()
		}(i, fn)
	}

	tasks.Wait()

	return errors.Join(errs...)
}
