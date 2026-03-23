// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
)

const (
	winVMIP      = "172.19.1.101"
	sshUser      = "remote"
)

type linuxImageProvider struct {
	installDir string
}

func newLinuxImageProvider(cfg ProviderConfig) *linuxImageProvider {
	return &linuxImageProvider{installDir: cfg.InstallDir}
}

// sshCmd executes a command on the Windows VM via SSH.
func sshCmd(command string) (string, error) {
	out, err := exec.Command("ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "ConnectTimeout=10",
		fmt.Sprintf("%s@%s", sshUser, winVMIP),
		command,
	).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("SSH command failed: %w: %s", err, string(out))
	}
	return string(out), nil
}

func (p *linuxImageProvider) List(cfg ImageListConfig) (*ImageListResult, error) {
	slog.Debug("[Image] Listing images (Linux)")
	result := &ImageListResult{}

	// List images on the local Linux node via crictl
	linuxImages, err := listCrictlImages()
	if err != nil {
		slog.Warn("[Image] Could not list Linux node images", "error", err)
	} else {
		for _, img := range linuxImages {
			if !cfg.IncludeK8sImages && isK8sImage(img.Repository) {
				continue
			}
			result.ContainerImages = append(result.ContainerImages, img)
		}
	}

	// List images on the Windows VM via SSH + crictl
	winImages, err := listWindowsVMImages()
	if err != nil {
		slog.Debug("[Image] Could not list Windows VM images (VM may be offline)", "error", err)
	} else {
		for _, img := range winImages {
			if !cfg.IncludeK8sImages && isK8sImage(img.Repository) {
				continue
			}
			result.ContainerImages = append(result.ContainerImages, img)
		}
	}

	return result, nil
}

func (p *linuxImageProvider) Pull(cfg ImagePullConfig) error {
	if cfg.Windows {
		slog.Info("[Image] Pulling image on Windows VM", "image", cfg.ImageName)
		_, err := sshCmd(fmt.Sprintf("crictl pull %s", cfg.ImageName))
		return err
	}
	slog.Info("[Image] Pulling image on Linux node", "image", cfg.ImageName)
	return exec.Command("crictl", "pull", cfg.ImageName).Run()
}

func (p *linuxImageProvider) Remove(cfg ImageRemoveConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Removing image", "ref", ref)
	return exec.Command("crictl", "rmi", ref).Run()
}

func (p *linuxImageProvider) Build(cfg ImageBuildConfig) error {
	slog.Info("[Image] Building image", "name", cfg.ImageName, "input", cfg.InputFolder)

	args := []string{"build"}
	if cfg.Dockerfile != "" {
		args = append(args, "-f", cfg.Dockerfile)
	}
	if cfg.ImageName != "" {
		args = append(args, "-t", cfg.ImageName)
	}
	args = append(args, cfg.InputFolder)

	cmd := exec.Command("nerdctl", args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("nerdctl build failed: %w", err)
	}

	if cfg.Push && cfg.ImageName != "" {
		return exec.Command("nerdctl", "push", cfg.ImageName).Run()
	}

	return nil
}

func (p *linuxImageProvider) Import(cfg ImageImportConfig) error {
	slog.Info("[Image] Importing image", "path", cfg.TarPath, "windows", cfg.Windows)

	if cfg.Windows {
		// Import on Windows VM via SSH
		_, err := sshCmd(fmt.Sprintf(`ctr -n k8s.io images import "%s"`, cfg.TarPath))
		return err
	}
	return exec.Command("ctr", "-n", "k8s.io", "images", "import", cfg.TarPath).Run()
}

func (p *linuxImageProvider) Export(cfg ImageExportConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Exporting image", "ref", ref, "output", cfg.OutputPath)
	return exec.Command("ctr", "-n", "k8s.io", "images", "export", cfg.OutputPath, ref).Run()
}

func (p *linuxImageProvider) Tag(cfg ImageTagConfig) error {
	ref := cfg.ImageId
	if ref == "" {
		ref = cfg.ImageName
	}
	slog.Info("[Image] Tagging image", "ref", ref, "target", cfg.ImageName)
	return exec.Command("ctr", "-n", "k8s.io", "images", "tag", ref, cfg.ImageName).Run()
}

func (p *linuxImageProvider) Push(cfg ImagePushConfig) error {
	slog.Info("[Image] Pushing image", "name", cfg.ImageName)
	return exec.Command("nerdctl", "push", cfg.ImageName).Run()
}

func (p *linuxImageProvider) Clean(cfg ImageCleanConfig) error {
	slog.Info("[Image] Cleaning non-K8s images")

	images, err := listCrictlImages()
	if err != nil {
		return err
	}

	for _, img := range images {
		if isK8sImage(img.Repository) {
			continue
		}
		if err := exec.Command("crictl", "rmi", img.ImageId).Run(); err != nil {
			slog.Warn("[Image] Could not remove image", "id", img.ImageId, "error", err)
		}
	}

	return nil
}

// ---------- helpers ----------

func listCrictlImages() ([]ContainerImage, error) {
	output, err := exec.Command("crictl", "images", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("crictl images: %w", err)
	}

	var result struct {
		Images []struct {
			Id          string   `json:"id"`
			RepoTags    []string `json:"repoTags"`
			RepoDigests []string `json:"repoDigests"`
			Size        string   `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal(output, &result); err != nil {
		return nil, fmt.Errorf("parsing crictl output: %w", err)
	}

	var images []ContainerImage
	for _, img := range result.Images {
		repo := "<none>"
		tag := "<none>"
		if len(img.RepoTags) > 0 && img.RepoTags[0] != "" {
			parts := strings.SplitN(img.RepoTags[0], ":", 2)
			repo = parts[0]
			if len(parts) > 1 {
				tag = parts[1]
			}
		}
		shortId := img.Id
		if len(shortId) > 12 {
			shortId = shortId[:12]
		}
		images = append(images, ContainerImage{
			ImageId:    shortId,
			Repository: repo,
			Tag:        tag,
			Node:       "linux",
			Size:       img.Size,
		})
	}

	return images, nil
}

func listWindowsVMImages() ([]ContainerImage, error) {
	output, err := sshCmd("crictl images -o json")
	if err != nil {
		return nil, err
	}

	var result struct {
		Images []struct {
			Id       string   `json:"id"`
			RepoTags []string `json:"repoTags"`
			Size     string   `json:"size"`
		} `json:"images"`
	}

	if err := json.Unmarshal([]byte(output), &result); err != nil {
		return nil, fmt.Errorf("parsing Windows VM crictl output: %w", err)
	}

	var images []ContainerImage
	for _, img := range result.Images {
		repo := "<none>"
		tag := "<none>"
		if len(img.RepoTags) > 0 && img.RepoTags[0] != "" {
			parts := strings.SplitN(img.RepoTags[0], ":", 2)
			repo = parts[0]
			if len(parts) > 1 {
				tag = parts[1]
			}
		}
		shortId := img.Id
		if len(shortId) > 12 {
			shortId = shortId[:12]
		}
		images = append(images, ContainerImage{
			ImageId:    shortId,
			Repository: repo,
			Tag:        tag,
			Node:       "windows",
			Size:       img.Size,
		})
	}

	return images, nil
}

func isK8sImage(repo string) bool {
	k8sPrefixes := []string{
		"registry.k8s.io/",
		"k8s.gcr.io/",
		"docker.io/flannel",
		"docker.io/calico",
		"quay.io/coreos",
	}
	for _, prefix := range k8sPrefixes {
		if strings.HasPrefix(repo, prefix) {
			return true
		}
	}
	return false
}
