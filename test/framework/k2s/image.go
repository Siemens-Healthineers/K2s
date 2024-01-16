// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k2s

import (
	"context"
	"encoding/json"
	"fmt"
	"k2s/cmd/image"

	. "github.com/onsi/gomega"
)

type k2sImage struct {
	internal *image.StoredImages
}

// wrapper around k2s.exe to retrieve and parse the images list
func (r *k2sCliRunner) GetImages(ctx context.Context) *k2sImage {
	output := r.Run(ctx, "image", "ls", "-o", "json")

	images := unmarshalImages(output)

	return &k2sImage{
		internal: images,
	}
}

func (images k2sImage) GetContainerImages() []string {
	var containerImageNames []string
	for _, image := range images.internal.ContainerImages {
		containerImageNames = append(containerImageNames, fmt.Sprintf("%s:%s", image.Repository, image.Tag))
	}

	return containerImageNames
}

func (status k2sImage) IsImageAvailable(name string, tag string) bool {
	for _, image := range status.internal.ContainerImages {
		if image.Repository == name && image.Tag == tag {
			return true
		}
	}

	return false
}

func unmarshalImages(imagesJson string) *image.StoredImages {
	var images image.StoredImages

	err := json.Unmarshal([]byte(imagesJson), &images)

	Expect(err).NotTo(HaveOccurred())
	Expect(images).NotTo(BeNil())

	return &images
}
