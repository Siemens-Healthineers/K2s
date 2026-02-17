// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package controller

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-logr/logr"
	specs "github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/util/retry"
	"oras.land/oras-go/v2"
	"oras.land/oras-go/v2/content/oci"
	"oras.land/oras-go/v2/registry/remote"
	"oras.land/oras-go/v2/registry/remote/auth"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	sigsyaml "sigs.k8s.io/yaml"
)

// errOCIRepositoryNotReady is a sentinel error for transient OCIRepository not-ready states.
// The reconciler requeues with a fixed interval instead of marking the addon as Failed.
type errOCIRepositoryNotReady struct {
	name      string
	namespace string
	message   string
}

func (e *errOCIRepositoryNotReady) Error() string {
	if e.message != "" {
		return fmt.Sprintf("OCIRepository %s/%s is not Ready: %s", e.namespace, e.name, e.message)
	}
	return fmt.Sprintf("OCIRepository %s/%s is not Ready", e.namespace, e.name)
}

const (
	K2sAddonFinalizer = "k2s.siemens-healthineers.com/addon-finalizer"
	DefaultAddonsPath = "/addons"

	// hostRootMount is where the Linux DaemonSet mounts host "/".
	// Container-local paths are NOT visible after nsenter --mount.
	hostRootMount          = "/host"
	MediaTypeConfig        = "application/vnd.k2s.addon.config.v1+json"
	MediaTypeConfigFiles   = "application/vnd.k2s.addon.configfiles.v1.tar+gzip"
	MediaTypeManifests     = "application/vnd.k2s.addon.manifests.v1.tar+gzip"
	MediaTypeCharts        = "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
	MediaTypeScripts       = "application/vnd.k2s.addon.scripts.v1.tar+gzip"
	MediaTypeImagesLinux   = "application/vnd.oci.image.layer.v1.tar"
	MediaTypeImagesWindows = "application/vnd.oci.image.layer.v1.tar+windows"
	MediaTypePackages      = "application/vnd.k2s.addon.packages.v1.tar+gzip"
	MediaTypeAddonContent  = "application/vnd.k2s.addon.content.v1.tar+gzip"
)

type K2sAddonSpec struct {
	Name           string            `json:"name"`
	Implementation string            `json:"implementation,omitempty"`
	Version        string            `json:"version,omitempty"`
	Description    string            `json:"description,omitempty"`
	Source         AddonSource       `json:"source"`
	Layers         LayerConfig       `json:"layers,omitempty"`
	NodeSelector   map[string]string `json:"nodeSelector,omitempty"`
}

type AddonSource struct {
	Type          string      `json:"type"` // "oci", "local", or "OCIRepository"
	OciRef        string      `json:"ociRef,omitempty"`
	OCIRepository *OCIRepoRef `json:"ociRepository,omitempty"`
	LocalPath     string      `json:"localPath,omitempty"`
	Insecure      bool        `json:"insecure,omitempty"`
	PullSecretRef *SecretRef  `json:"pullSecretRef,omitempty"`
}

type OCIRepoRef struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
}

type SecretRef struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

type LayerConfig struct {
	SkipImages        bool `json:"skipImages,omitempty"`
	SkipLinuxImages   bool `json:"skipLinuxImages,omitempty"`
	SkipWindowsImages bool `json:"skipWindowsImages,omitempty"`
	SkipPackages      bool `json:"skipPackages,omitempty"`
	SkipManifests     bool `json:"skipManifests,omitempty"`
}

func (in *K2sAddonSpec) DeepCopyInto(out *K2sAddonSpec) {
	*out = *in
	out.Source = in.Source
	if in.Source.PullSecretRef != nil {
		out.Source.PullSecretRef = new(SecretRef)
		*out.Source.PullSecretRef = *in.Source.PullSecretRef
	}
	if in.Source.OCIRepository != nil {
		out.Source.OCIRepository = new(OCIRepoRef)
		*out.Source.OCIRepository = *in.Source.OCIRepository
	}
	out.Layers = in.Layers
	if in.NodeSelector != nil {
		out.NodeSelector = make(map[string]string, len(in.NodeSelector))
		for k, v := range in.NodeSelector {
			out.NodeSelector[k] = v
		}
	}
}

func (in *K2sAddonStatus) DeepCopyInto(out *K2sAddonStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(in.Conditions))
		for i := range in.Conditions {
			in.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
	out.LayerStatus = in.LayerStatus
	if in.NodeStatus != nil {
		out.NodeStatus = make([]NodeStatusEntry, len(in.NodeStatus))
		for i := range in.NodeStatus {
			out.NodeStatus[i] = in.NodeStatus[i]
			if in.NodeStatus[i].LastUpdated != nil {
				out.NodeStatus[i].LastUpdated = in.NodeStatus[i].LastUpdated.DeepCopy()
			}
		}
	}
	if in.LastProcessedTime != nil {
		out.LastProcessedTime = in.LastProcessedTime.DeepCopy()
	}
}

type K2sAddonStatus struct {
	Phase              string             `json:"phase,omitempty"`
	Available          bool               `json:"available,omitempty"`
	Enabled            bool               `json:"enabled,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
	LayerStatus        LayerStatusMap     `json:"layerStatus,omitempty"`
	NodeStatus         []NodeStatusEntry  `json:"nodeStatus,omitempty"`
	AddonPath          string             `json:"addonPath,omitempty"`
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	LastProcessedTime  *metav1.Time       `json:"lastProcessedTime,omitempty"`
	LastPulledDigest   string             `json:"lastPulledDigest,omitempty"`
	ErrorMessage       string             `json:"errorMessage,omitempty"`
}

type LayerStatusMap struct {
	Config        string `json:"config,omitempty"`
	Manifests     string `json:"manifests,omitempty"`
	Charts        string `json:"charts,omitempty"`
	Scripts       string `json:"scripts,omitempty"`
	ImagesLinux   string `json:"imagesLinux,omitempty"`
	ImagesWindows string `json:"imagesWindows,omitempty"`
	Packages      string `json:"packages,omitempty"`
}

type NodeStatusEntry struct {
	NodeName          string       `json:"nodeName"`
	NodeType          string       `json:"nodeType"` // "linux" or "windows"
	ImagesImported    bool         `json:"imagesImported"`
	PackagesInstalled bool         `json:"packagesInstalled"`
	LastUpdated       *metav1.Time `json:"lastUpdated,omitempty"`
}

type K2sAddon struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   K2sAddonSpec   `json:"spec,omitempty"`
	Status K2sAddonStatus `json:"status,omitempty"`
}

func (in *K2sAddon) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(K2sAddon)
	in.DeepCopyInto(out)
	return out
}

func (in *K2sAddon) DeepCopyInto(out *K2sAddon) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *K2sAddon) DeepCopy() *K2sAddon {
	if in == nil {
		return nil
	}
	out := new(K2sAddon)
	in.DeepCopyInto(out)
	return out
}

type K2sAddonList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []K2sAddon `json:"items"`
}

func (in *K2sAddonList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(K2sAddonList)
	in.DeepCopyInto(out)
	return out
}

func (in *K2sAddonList) DeepCopyInto(out *K2sAddonList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]K2sAddon, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *K2sAddonList) DeepCopy() *K2sAddonList {
	if in == nil {
		return nil
	}
	out := new(K2sAddonList)
	in.DeepCopyInto(out)
	return out
}

type K2sAddonReconciler struct {
	client.Client
	Log        logr.Logger
	Scheme     *runtime.Scheme
	AddonsPath string
	NodeName   string
	NodeType   string // "linux" or "windows"
}

func (r *K2sAddonReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("k2saddon", req.NamespacedName)

	// Fetch the K2sAddon instance
	addon := &K2sAddon{}
	if err := r.Get(ctx, req.NamespacedName, addon); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if !addon.ObjectMeta.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, addon, log)
	}

	if !controllerutil.ContainsFinalizer(addon, K2sAddonFinalizer) {
		controllerutil.AddFinalizer(addon, K2sAddonFinalizer)
		if err := r.Update(ctx, addon); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Skip if already processed for this generation.
	// Use ObservedGeneration alone — Phase can be transiently set by the other controller.
	if addon.Status.ObservedGeneration == addon.Generation {
		// For OCIRepository sources, check if FluxCD detected a new artifact digest.
		if addon.Spec.Source.Type == "OCIRepository" {
			changed, err := r.hasOCIRepositoryDigestChanged(ctx, addon, log)
			if err != nil {
				log.Error(err, "Failed to check OCIRepository digest, skipping")
				return ctrl.Result{}, nil
			}
			if !changed {
				return ctrl.Result{}, nil
			}
			log.Info("OCIRepository artifact digest changed, re-processing addon")
		} else {
			return ctrl.Result{}, nil
		}
	}

	// Process the addon
	if err := r.processAddon(ctx, addon, log); err != nil {
		now := metav1.Now()

		// Transient: requeue with fixed interval (nil error so controller-runtime
		// respects RequeueAfter instead of applying exponential backoff).
		if _, ok := err.(*errOCIRepositoryNotReady); ok {
			log.Info("OCIRepository not ready, will retry", "retryAfter", "30s", "detail", err.Error())
			addon.Status.Phase = "Pending"
			addon.Status.Available = false
			addon.Status.ErrorMessage = err.Error()
			setCondition(&addon.Status.Conditions, metav1.Condition{
				Type:               "Ready",
				Status:             metav1.ConditionFalse,
				Reason:             "WaitingForSource",
				Message:            err.Error(),
				LastTransitionTime: now,
			})
			r.updateStatus(ctx, addon)
			return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
		}

		// Hard failure — return error for controller-runtime retry.
		addon.Status.Phase = "Failed"
		addon.Status.Available = false
		addon.Status.ErrorMessage = err.Error()
		setCondition(&addon.Status.Conditions, metav1.Condition{
			Type:               "Ready",
			Status:             metav1.ConditionFalse,
			Reason:             "ProcessingFailed",
			Message:            err.Error(),
			LastTransitionTime: now,
		})
		r.updateStatus(ctx, addon)
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

func (r *K2sAddonReconciler) processAddon(ctx context.Context, addon *K2sAddon, log logr.Logger) error {
	log.Info("Processing addon", "name", addon.Spec.Name, "implementation", addon.Spec.Implementation)

	// Reset status to Pulling
	addon.Status.Phase = "Pulling"
	addon.Status.Available = false
	addon.Status.ErrorMessage = ""
	addon.Status.LayerStatus = LayerStatusMap{
		Config:        "Pending",
		Manifests:     "Pending",
		Charts:        "Pending",
		Scripts:       "Pending",
		ImagesLinux:   "Pending",
		ImagesWindows: "Pending",
		Packages:      "Pending",
	}
	if err := r.updateStatus(ctx, addon); err != nil {
		return err
	}

	addonPath := r.determineAddonPath(addon)
	addon.Status.AddonPath = addonPath

	ociStore, tempDir, err := r.pullOCIArtifact(ctx, addon, log)
	if err != nil {
		return fmt.Errorf("failed to pull OCI artifact: %w", err)
	}
	if tempDir != "" {
		defer os.RemoveAll(tempDir)
	}

	addon.Status.Phase = "Processing"
	r.updateStatus(ctx, addon)

	if ociStore != nil {
		if err := r.processLayers(ctx, addon, ociStore, log); err != nil {
			return fmt.Errorf("failed to process layers: %w", err)
		}
	}

	addon.Status.Phase = "Available"
	addon.Status.Available = true
	addon.Status.ObservedGeneration = addon.Generation
	now := metav1.Now()
	addon.Status.LastProcessedTime = &now

	setCondition(&addon.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		Reason:             "ProcessingComplete",
		Message:            "Addon is available for enabling",
		LastTransitionTime: now,
	})

	log.Info("K2sAddon processed successfully", "name", addon.Spec.Name, "phase", addon.Status.Phase)

	return r.updateStatus(ctx, addon)
}

// pullOCIArtifact fetches the OCI artifact. Caller must clean up the returned temp dir.
func (r *K2sAddonReconciler) pullOCIArtifact(ctx context.Context, addon *K2sAddon, log logr.Logger) (*oci.Store, string, error) {
	tempDir, err := os.MkdirTemp("", "k2s-addon-*")
	if err != nil {
		return nil, "", err
	}

	store, err := oci.New(tempDir)
	if err != nil {
		os.RemoveAll(tempDir)
		return nil, "", err
	}

	switch addon.Spec.Source.Type {
	case "oci":
		resultStore, err := r.pullFromRegistry(ctx, addon, store, log)
		if err != nil {
			os.RemoveAll(tempDir)
			return nil, "", err
		}
		return resultStore, tempDir, nil
	case "OCIRepository":
		resultStore, err := r.pullFromOCIRepository(ctx, addon, store, log)
		if err != nil {
			os.RemoveAll(tempDir)
			return nil, "", err
		}
		return resultStore, tempDir, nil
	case "local":
		resultStore, localTempDir, err := r.loadFromLocal(ctx, addon, log)
		if err != nil {
			os.RemoveAll(tempDir)
			return nil, "", err
		}
		// If local created its own temp dir, clean up the original
		if localTempDir != "" && localTempDir != tempDir {
			os.RemoveAll(tempDir)
			return resultStore, localTempDir, nil
		}
		return resultStore, tempDir, nil
	default:
		os.RemoveAll(tempDir)
		return nil, "", fmt.Errorf("unsupported source type: %s", addon.Spec.Source.Type)
	}
}

func (r *K2sAddonReconciler) pullFromRegistry(ctx context.Context, addon *K2sAddon, store *oci.Store, log logr.Logger) (*oci.Store, error) {
	ref := addon.Spec.Source.OciRef
	log.Info("Pulling from OCI registry", "ref", ref)

	repo, err := remote.NewRepository(ref)
	if err != nil {
		return nil, fmt.Errorf("failed to parse OCI reference: %w", err)
	}

	if addon.Spec.Source.Insecure {
		repo.PlainHTTP = true
	}

	if addon.Spec.Source.PullSecretRef != nil {
		creds, err := r.getRegistryCredentials(ctx, addon.Spec.Source.PullSecretRef)
		if err != nil {
			return nil, fmt.Errorf("failed to get registry credentials: %w", err)
		}
		repo.Client = &auth.Client{
			Credential: auth.StaticCredential(repo.Reference.Registry, creds),
		}
	}

	tag := "latest"
	if parts := strings.Split(ref, ":"); len(parts) > 1 {
		tag = parts[len(parts)-1]
	}

	desc, err := oras.Copy(ctx, repo, tag, store, tag, oras.DefaultCopyOptions)
	if err != nil {
		return nil, fmt.Errorf("failed to pull artifact: %w", err)
	}

	addon.Status.LastPulledDigest = desc.Digest.String()
	log.Info("Pulled OCI artifact", "digest", desc.Digest.String(), "tag", tag)

	return store, nil
}

func (r *K2sAddonReconciler) loadFromLocal(ctx context.Context, addon *K2sAddon, log logr.Logger) (*oci.Store, string, error) {
	localPath := addon.Spec.Source.LocalPath
	log.Info("Loading from local path", "path", localPath)

	if _, err := os.Stat(localPath); os.IsNotExist(err) {
		return nil, "", fmt.Errorf("local path does not exist: %s", localPath)
	}

	var tempDir string
	if strings.HasSuffix(localPath, ".tar") {
		var err error
		tempDir, err = os.MkdirTemp("", "k2s-extract-*")
		if err != nil {
			return nil, "", fmt.Errorf("failed to create temp dir: %w", err)
		}
		if err := extractTar(localPath, tempDir); err != nil {
			os.RemoveAll(tempDir)
			return nil, "", fmt.Errorf("failed to extract tar: %w", err)
		}
		localPath = filepath.Join(tempDir, "artifacts")
	}

	localStore, err := oci.New(localPath)
	if err != nil {
		if tempDir != "" {
			os.RemoveAll(tempDir)
		}
		return nil, "", fmt.Errorf("failed to open OCI layout: %w", err)
	}

	return localStore, tempDir, nil
}

func (r *K2sAddonReconciler) processLayers(ctx context.Context, addon *K2sAddon, store *oci.Store, log logr.Logger) error {
	addonPath := addon.Status.AddonPath

	if err := os.MkdirAll(addonPath, 0755); err != nil {
		return fmt.Errorf("failed to create addon directory: %w", err)
	}

	// Simplified index traversal: index.json -> manifest -> layers
	index, err := r.getIndex(store)
	if err != nil {
		return err
	}

	for _, manifestRef := range index.Manifests {
		manifest, err := r.getManifest(ctx, store, manifestRef)
		if err != nil {
			log.Error(err, "Failed to get manifest", "digest", manifestRef.Digest)
			continue
		}

		for _, layer := range manifest.Layers {
			if layer.MediaType == MediaTypeAddonContent {
				log.Info("Detected unified addon content layer, extracting")
				reader, err := store.Fetch(ctx, layer)
				if err != nil {
					return fmt.Errorf("failed to fetch unified content layer: %w", err)
				}
				contentDir, err := os.MkdirTemp("", "k2s-content-*")
				if err != nil {
					reader.Close()
					return fmt.Errorf("failed to create content temp dir: %w", err)
				}
				defer os.RemoveAll(contentDir)
				if err := extractTarGzToDir(reader, contentDir); err != nil {
					reader.Close()
					return fmt.Errorf("failed to extract unified content: %w", err)
				}
				reader.Close()
				return r.processDirectContent(ctx, addon, contentDir, log)
			}
			if err := r.processLayer(ctx, addon, store, layer, addonPath, log); err != nil {
				log.Error(err, "Failed to process layer", "mediaType", layer.MediaType)
				// Continue processing other layers
			}
		}
	}

	// Mark any layers still Pending as Skipped — the addon simply doesn't contain them
	r.finalizePendingLayers(addon)

	return nil
}

// finalizePendingLayers marks remaining Pending layers as Skipped.
func (r *K2sAddonReconciler) finalizePendingLayers(addon *K2sAddon) {
	ls := &addon.Status.LayerStatus
	if ls.Config == "Pending" {
		ls.Config = "Skipped"
	}
	if ls.Manifests == "Pending" {
		ls.Manifests = "Skipped"
	}
	if ls.Charts == "Pending" {
		ls.Charts = "Skipped"
	}
	if ls.Scripts == "Pending" {
		ls.Scripts = "Skipped"
	}
	if ls.ImagesLinux == "Pending" {
		ls.ImagesLinux = "Skipped"
	}
	if ls.ImagesWindows == "Pending" {
		ls.ImagesWindows = "Skipped"
	}
	if ls.Packages == "Pending" {
		ls.Packages = "Skipped"
	}
}

func (r *K2sAddonReconciler) processLayer(ctx context.Context, addon *K2sAddon, store *oci.Store, layer ocispec.Descriptor, addonPath string, log logr.Logger) error {
	log.Info("Processing layer", "mediaType", layer.MediaType, "size", layer.Size)

	reader, err := store.Fetch(ctx, layer)
	if err != nil {
		return fmt.Errorf("failed to fetch layer: %w", err)
	}
	defer reader.Close()

	switch layer.MediaType {
	case MediaTypeConfigFiles:
		addon.Status.LayerStatus.Config = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processConfigLayer(reader, addonPath); err != nil {
			addon.Status.LayerStatus.Config = "Failed"
			return err
		}
		addon.Status.LayerStatus.Config = "Completed"

	case MediaTypeManifests:
		if addon.Spec.Layers.SkipManifests {
			addon.Status.LayerStatus.Manifests = "Skipped"
			return nil
		}
		addon.Status.LayerStatus.Manifests = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processManifestsLayer(reader, addonPath); err != nil {
			addon.Status.LayerStatus.Manifests = "Failed"
			return err
		}
		addon.Status.LayerStatus.Manifests = "Completed"

	case MediaTypeCharts:
		addon.Status.LayerStatus.Charts = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processChartsLayer(reader, addonPath); err != nil {
			addon.Status.LayerStatus.Charts = "Failed"
			return err
		}
		addon.Status.LayerStatus.Charts = "Completed"

	case MediaTypeScripts:
		addon.Status.LayerStatus.Scripts = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processScriptsLayer(reader, addonPath); err != nil {
			addon.Status.LayerStatus.Scripts = "Failed"
			return err
		}
		addon.Status.LayerStatus.Scripts = "Completed"

	case MediaTypeImagesLinux:
		if addon.Spec.Layers.SkipImages || addon.Spec.Layers.SkipLinuxImages || r.NodeType != "linux" {
			addon.Status.LayerStatus.ImagesLinux = "Skipped"
			return nil
		}
		addon.Status.LayerStatus.ImagesLinux = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processLinuxImagesLayer(ctx, reader); err != nil {
			addon.Status.LayerStatus.ImagesLinux = "Failed"
			return err
		}
		addon.Status.LayerStatus.ImagesLinux = "Completed"

	case MediaTypeImagesWindows:
		if addon.Spec.Layers.SkipImages || addon.Spec.Layers.SkipWindowsImages || r.NodeType != "windows" {
			addon.Status.LayerStatus.ImagesWindows = "Skipped"
			return nil
		}
		addon.Status.LayerStatus.ImagesWindows = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processWindowsImagesLayer(ctx, reader); err != nil {
			addon.Status.LayerStatus.ImagesWindows = "Failed"
			return err
		}
		addon.Status.LayerStatus.ImagesWindows = "Completed"

	case MediaTypePackages:
		if addon.Spec.Layers.SkipPackages {
			addon.Status.LayerStatus.Packages = "Skipped"
			return nil
		}
		addon.Status.LayerStatus.Packages = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processPackagesLayer(ctx, reader, addon, log); err != nil {
			addon.Status.LayerStatus.Packages = "Failed"
			return err
		}
		addon.Status.LayerStatus.Packages = "Completed"
	}

	return nil
}

func (r *K2sAddonReconciler) processConfigLayer(reader io.Reader, addonPath string) error {
	return extractTarGzToDir(reader, addonPath)
}

func (r *K2sAddonReconciler) processManifestsLayer(reader io.Reader, addonPath string) error {
	manifestsDir := filepath.Join(addonPath, "manifests")
	os.MkdirAll(manifestsDir, 0755)
	return extractTarGzToDir(reader, manifestsDir)
}

func (r *K2sAddonReconciler) processChartsLayer(reader io.Reader, addonPath string) error {
	chartsDir := filepath.Join(addonPath, "manifests", "chart")
	os.MkdirAll(chartsDir, 0755)
	return extractTarGzToDir(reader, chartsDir)
}

func (r *K2sAddonReconciler) processScriptsLayer(reader io.Reader, addonPath string) error {
	return extractTarGzToDir(reader, addonPath)
}

// processLinuxImagesLayer imports container images via nsenter + buildah.
// Image tars are staged to /host/tmp/ because container-local paths are not
// visible after nsenter --mount into the host mount namespace.
func (r *K2sAddonReconciler) processLinuxImagesLayer(ctx context.Context, reader io.Reader) error {
	tempDir, err := os.MkdirTemp("", "k2s-images-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDir)

	if err := extractTarToDir(reader, tempDir); err != nil {
		return err
	}

	// Import each image tar via nsenter + buildah on the host
	return filepath.Walk(tempDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".tar") {
			return err
		}
		return r.importImageOnHost(ctx, path)
	})
}

// importImageOnHost stages an image tar to /host/tmp/ and imports via nsenter + buildah.
func (r *K2sAddonReconciler) importImageOnHost(ctx context.Context, containerLocalPath string) error {
	stageDir, hostRelPath, err := stageFileToHost(containerLocalPath)
	if err != nil {
		return fmt.Errorf("failed to stage image to host: %w", err)
	}
	defer os.RemoveAll(stageDir)

	cmd := exec.CommandContext(ctx, "nsenter", "--target", "1", "--mount", "--",
		"buildah", "pull", fmt.Sprintf("oci-archive:%s", hostRelPath))
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to import image %s: %w\nOutput: %s", filepath.Base(containerLocalPath), err, string(output))
	}
	return nil
}

// stageFileToHost copies a file to /host/tmp/ for visibility in the host mount namespace.
// Returns the staging dir (for cleanup) and host-relative path for nsenter commands.
func stageFileToHost(containerLocalPath string) (stageDirPath string, hostRelPath string, err error) {
	fileName := filepath.Base(containerLocalPath)
	// Create a unique staging name to avoid collisions
	stageDir, err := os.MkdirTemp(filepath.Join(hostRootMount, "tmp"), "k2s-stage-*")
	if err != nil {
		return "", "", fmt.Errorf("failed to create host staging dir: %w", err)
	}

	destPath := filepath.Join(stageDir, fileName)
	if err := copyFile(containerLocalPath, destPath); err != nil {
		os.RemoveAll(stageDir)
		return "", "", fmt.Errorf("failed to copy %s to host: %w", fileName, err)
	}

	// hostRelPath strips the /host prefix to get the path as seen from the host namespace
	hostRelPath = strings.TrimPrefix(stageDir, hostRootMount)
	hostRelPath = filepath.Join(hostRelPath, fileName)

	return stageDir, hostRelPath, nil
}

// processWindowsImagesLayer imports images to Windows containerd via nerdctl.
// Pre-import: removes existing tags to prevent <none>:<none> orphans.
// Post-import: prunes remaining dangling images.
func (r *K2sAddonReconciler) processWindowsImagesLayer(ctx context.Context, reader io.Reader) error {
	log := r.Log.WithName("windowsImages")

	// Extract tar containing individual image tars
	tempDir, err := os.MkdirTemp("", "k2s-images-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDir)

	if err := extractTarToDir(reader, tempDir); err != nil {
		return err
	}

	// Import each image tar using nerdctl on Windows
	if err := filepath.Walk(tempDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".tar") {
			return err
		}

		// Pre-import cleanup: parse the tar's manifest.json to discover RepoTags,
		// then remove existing images with those tags so nerdctl load doesn't orphan
		// the old content digest as <none>:<none>.
		tags, parseErr := parseDockerSaveRepoTags(path)
		if parseErr != nil {
			log.V(1).Info("Could not parse RepoTags from image tar, skipping pre-cleanup", "file", filepath.Base(path), "error", parseErr)
		} else {
			for _, tag := range tags {
				rmCmd := exec.CommandContext(ctx, "nerdctl", "-n", "k8s.io", "rmi", tag)
				if rmOut, rmErr := rmCmd.CombinedOutput(); rmErr != nil {
					// Not an error — image may not exist yet (first import)
					log.V(1).Info("Pre-import rmi (image may not exist yet)", "tag", tag, "output", strings.TrimSpace(string(rmOut)))
				} else {
					log.Info("Removed existing image before re-import", "tag", tag)
				}
			}
		}

		// Load the image tar
		cmd := exec.CommandContext(ctx, "nerdctl", "-n", "k8s.io", "load", "-i", path)
		output, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("failed to import image %s: %w\nOutput: %s", path, err, string(output))
		}
		return nil
	}); err != nil {
		return err
	}

	// Post-import cleanup: prune any remaining dangling (untagged) images.
	// This catches edge cases the pre-cleanup misses (e.g., interrupted previous imports).
	pruneCmd := exec.CommandContext(ctx, "nerdctl", "-n", "k8s.io", "image", "prune", "-f")
	if pruneOut, pruneErr := pruneCmd.CombinedOutput(); pruneErr != nil {
		log.V(1).Info("Image prune after import returned error (non-fatal)", "error", pruneErr, "output", strings.TrimSpace(string(pruneOut)))
	} else {
		log.V(1).Info("Pruned dangling images after import", "output", strings.TrimSpace(string(pruneOut)))
	}

	return nil
}

// parseDockerSaveRepoTags extracts RepoTags from a Docker-save format tar's manifest.json.
func parseDockerSaveRepoTags(tarPath string) ([]string, error) {
	f, err := os.Open(tarPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	tr := tar.NewReader(f)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil, fmt.Errorf("manifest.json not found in tar")
		}
		if err != nil {
			return nil, err
		}
		if hdr.Name == "manifest.json" {
			data, err := io.ReadAll(tr)
			if err != nil {
				return nil, fmt.Errorf("failed to read manifest.json: %w", err)
			}
			var manifests []struct {
				RepoTags []string `json:"RepoTags"`
			}
			if err := json.Unmarshal(data, &manifests); err != nil {
				return nil, fmt.Errorf("failed to parse manifest.json: %w", err)
			}
			var tags []string
			for _, m := range manifests {
				tags = append(tags, m.RepoTags...)
			}
			return tags, nil
		}
	}
}

// processPackagesLayer extracts and stages addon packages (debian, linux curl, windows curl).
func (r *K2sAddonReconciler) processPackagesLayer(ctx context.Context, reader io.Reader, addon *K2sAddon, log logr.Logger) error {
	addonPath := addon.Status.AddonPath

	// Extract packages to a temp directory (not the addon path)
	tempPkgDir, err := os.MkdirTemp("", "k2s-packages-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempPkgDir)

	if err := extractTarGzToDir(reader, tempPkgDir); err != nil {
		return err
	}

	return r.processExtractedPackages(ctx, tempPkgDir, addon, addonPath, log)
}

func (r *K2sAddonReconciler) processExtractedPackages(ctx context.Context, packagesDir string, addon *K2sAddon, addonPath string, log logr.Logger) error {
	manifestPath := filepath.Join(addonPath, "addon.manifest.yaml")
	var linuxCurlPkgs, windowsCurlPkgs []curlPackage
	if manifestData, err := os.ReadFile(manifestPath); err == nil {
		linuxCurlPkgs, windowsCurlPkgs = parseCurlPackages(manifestData, addon.Spec.Implementation)
	}

	if r.NodeType == "linux" {
		debDir := filepath.Join(packagesDir, "debianpackages")
		if _, err := os.Stat(debDir); err == nil {
			if err := r.stageDebianPackagesToHost(ctx, debDir, addon.Spec.Name, log); err != nil {
				return err
			}
		}

		linuxPkgDir := filepath.Join(packagesDir, "linuxpackages")
		if _, err := os.Stat(linuxPkgDir); err == nil {
			if err := r.installLinuxCurlPackages(ctx, linuxPkgDir, linuxCurlPkgs, log); err != nil {
				return err
			}
		}
	}

	if r.NodeType == "windows" {
		windowsPkgDir := filepath.Join(packagesDir, "windowspackages")
		if _, err := os.Stat(windowsPkgDir); err == nil {
			if err := r.installWindowsCurlPackages(windowsPkgDir, windowsCurlPkgs, log); err != nil {
				return err
			}
		}
	}

	return nil
}

type curlPackage struct {
	URL         string `json:"url"`
	Destination string `json:"destination"`
}

type addonManifestYAML struct {
	Spec struct {
		Implementations []struct {
			Name         string `json:"name"`
			OfflineUsage struct {
				Linux struct {
					Curl []curlPackage `json:"curl"`
				} `json:"linux"`
				Windows struct {
					Curl []curlPackage `json:"curl"`
				} `json:"windows"`
			} `json:"offline_usage"`
		} `json:"implementations"`
	} `json:"spec"`
}

func parseCurlPackages(manifestData []byte, implementation string) (linux []curlPackage, windows []curlPackage) {
	var manifest addonManifestYAML
	if err := sigsyaml.Unmarshal(manifestData, &manifest); err != nil {
		return nil, nil
	}

	for _, impl := range manifest.Spec.Implementations {
		if implementation == "" || impl.Name == implementation {
			return impl.OfflineUsage.Linux.Curl, impl.OfflineUsage.Windows.Curl
		}
	}
	// Fallback: use first implementation if no match
	if len(manifest.Spec.Implementations) > 0 {
		first := manifest.Spec.Implementations[0]
		return first.OfflineUsage.Linux.Curl, first.OfflineUsage.Windows.Curl
	}
	return nil, nil
}

// stageDebianPackagesToHost stages .deb files to ~/.<addonname>/ on the Linux host.
// Actual dpkg -i happens during Enable.ps1.
func (r *K2sAddonReconciler) stageDebianPackagesToHost(ctx context.Context, debDir string, addonName string, log logr.Logger) error {
	var debFiles []string
	filepath.Walk(debDir, func(path string, info os.FileInfo, err error) error {
		if err == nil && strings.HasSuffix(path, ".deb") {
			debFiles = append(debFiles, path)
		}
		return nil
	})

	if len(debFiles) == 0 {
		return nil
	}

	log.Info("Staging debian packages to host", "count", len(debFiles), "addonName", addonName)

	hostDestDir := filepath.Join(hostRootMount, "home", "remote", "."+addonName)

	cmd := exec.CommandContext(ctx, "nsenter", "--target", "1", "--mount", "--",
		"rm", "-rf", filepath.Join("/home/remote", "."+addonName))
	cmd.CombinedOutput() // ignore errors if dir doesn't exist

	os.MkdirAll(hostDestDir, 0755)

	for _, debFile := range debFiles {
		fileName := filepath.Base(debFile)
		destPath := filepath.Join(hostDestDir, fileName)
		if err := copyFile(debFile, destPath); err != nil {
			return fmt.Errorf("failed to stage deb %s to host: %w", fileName, err)
		}
		log.Info("Staged debian package", "file", fileName)
	}

	// Fix ownership to remote user (UID 1000) so Enable.ps1 can access them
	cmd = exec.CommandContext(ctx, "nsenter", "--target", "1", "--mount", "--",
		"chown", "-R", "1000:1000", filepath.Join("/home/remote", "."+addonName))
	if output, err := cmd.CombinedOutput(); err != nil {
		log.Error(err, "Failed to chown staged debs", "output", string(output))
	}

	return nil
}

// installLinuxCurlPackages copies curl packages to their destination paths on the Linux host.
func (r *K2sAddonReconciler) installLinuxCurlPackages(ctx context.Context, linuxPkgDir string, curlPkgs []curlPackage, log logr.Logger) error {
	for _, pkg := range curlPkgs {
		if pkg.URL == "" || pkg.Destination == "" {
			continue
		}
		parts := strings.Split(pkg.URL, "/")
		fileName := parts[len(parts)-1]

		sourcePath := filepath.Join(linuxPkgDir, fileName)
		if _, err := os.Stat(sourcePath); err != nil {
			log.Info("Linux curl package file not found, skipping", "file", fileName)
			continue
		}

		log.Info("Installing Linux curl package", "file", fileName, "destination", pkg.Destination)

		// Stage to /host/tmp/, then nsenter cp to destination
		stageDir, hostRelPath, err := stageFileToHost(sourcePath)
		if err != nil {
			return fmt.Errorf("failed to stage linux package %s: %w", fileName, err)
		}
		defer os.RemoveAll(stageDir)

		// Ensure destination directory exists on host
		destDir := filepath.Dir(pkg.Destination)
		cmd := exec.CommandContext(ctx, "nsenter", "--target", "1", "--mount", "--",
			"mkdir", "-p", destDir)
		cmd.CombinedOutput() // ignore if already exists

		// Copy from staging to final destination
		cmd = exec.CommandContext(ctx, "nsenter", "--target", "1", "--mount", "--",
			"cp", hostRelPath, pkg.Destination)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to install linux package %s to %s: %w\nOutput: %s",
				fileName, pkg.Destination, err, string(output))
		}
	}
	return nil
}

// installWindowsCurlPackages copies curl packages to their destination paths on the Windows host.
// Destinations are resolved relative to the K2s install root (parent of AddonsPath).
func (r *K2sAddonReconciler) installWindowsCurlPackages(windowsPkgDir string, curlPkgs []curlPackage, log logr.Logger) error {
	installRoot := filepath.Dir(r.AddonsPath)
	if installRoot == "" || installRoot == "." {
		installRoot = DefaultAddonsPath
	}

	for _, pkg := range curlPkgs {
		if pkg.URL == "" || pkg.Destination == "" {
			continue
		}
		parts := strings.Split(pkg.URL, "/")
		fileName := parts[len(parts)-1]

		sourcePath := filepath.Join(windowsPkgDir, fileName)
		if _, err := os.Stat(sourcePath); err != nil {
			log.Info("Windows curl package file not found, skipping", "file", fileName)
			continue
		}

		destPath := filepath.Join(installRoot, pkg.Destination)
		log.Info("Installing Windows curl package", "file", fileName, "destination", destPath)

		if err := os.MkdirAll(filepath.Dir(destPath), 0755); err != nil {
			return fmt.Errorf("failed to create destination dir for %s: %w", fileName, err)
		}

		if err := copyFile(sourcePath, destPath); err != nil {
			return fmt.Errorf("failed to install windows package %s to %s: %w", fileName, destPath, err)
		}
	}
	return nil
}

// processDirectContent handles addon content from a directory structure.
func (r *K2sAddonReconciler) processDirectContent(ctx context.Context, addon *K2sAddon, contentDir string, log logr.Logger) error {
	addonPath := addon.Status.AddonPath
	if err := os.MkdirAll(addonPath, 0755); err != nil {
		return fmt.Errorf("failed to create addon directory %s: %w", addonPath, err)
	}

	log.Info("Processing addon content", "contentDir", contentDir, "addonPath", addonPath)

	var linuxImageTars []string
	var windowsImageTars []string
	var packagesPath string

	imagesPrefix := "images" + string(os.PathSeparator)
	linuxImagesPrefix := filepath.Join("images", "linux") + string(os.PathSeparator)
	windowsImagesPrefix := filepath.Join("images", "windows") + string(os.PathSeparator)
	packagesPrefix := "packages" + string(os.PathSeparator)

	err := filepath.Walk(contentDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, _ := filepath.Rel(contentDir, path)
		if relPath == "." {
			return nil
		}

		// Collect image tars
		if relPath == "images" || strings.HasPrefix(relPath, imagesPrefix) {
			if !info.IsDir() && strings.HasSuffix(info.Name(), ".tar") {
				if strings.HasPrefix(relPath, linuxImagesPrefix) {
					linuxImageTars = append(linuxImageTars, path)
				} else if strings.HasPrefix(relPath, windowsImagesPrefix) {
					windowsImageTars = append(windowsImageTars, path)
				}
			}
			return nil // Don't copy images/ to addon path
		}

		if relPath == "packages" && info.IsDir() {
			packagesPath = path
			return nil
		}
		if strings.HasPrefix(relPath, packagesPrefix) {
			return nil // Skip files inside packages/ (handled separately)
		}

		destPath := filepath.Join(addonPath, relPath)
		if info.IsDir() {
			return os.MkdirAll(destPath, 0755)
		}
		return copyFile(path, destPath)
	})
	if err != nil {
		return fmt.Errorf("failed to process content directory: %w", err)
	}

	// Update layer status for file-based content
	addon.Status.LayerStatus.Config = "Completed"
	addon.Status.LayerStatus.Scripts = "Completed"
	addon.Status.LayerStatus.Manifests = "Completed"
	r.updateStatus(ctx, addon)

	log.Info("Collected image tars", "linux", len(linuxImageTars), "windows", len(windowsImageTars))

	if r.NodeType == "linux" && !addon.Spec.Layers.SkipImages && !addon.Spec.Layers.SkipLinuxImages {
		if len(linuxImageTars) > 0 {
			addon.Status.LayerStatus.ImagesLinux = "Processing"
			r.updateStatus(ctx, addon)
			for _, tarPath := range linuxImageTars {
				log.Info("Importing Linux container image", "file", filepath.Base(tarPath))
				if err := r.importImageOnHost(ctx, tarPath); err != nil {
					log.Error(err, "Failed to import Linux image", "path", tarPath)
				}
			}
			addon.Status.LayerStatus.ImagesLinux = "Completed"
		} else {
			addon.Status.LayerStatus.ImagesLinux = "Skipped"
		}
		addon.Status.LayerStatus.ImagesWindows = "Skipped"
	} else if r.NodeType == "windows" && !addon.Spec.Layers.SkipImages && !addon.Spec.Layers.SkipWindowsImages {
		if len(windowsImageTars) > 0 {
			addon.Status.LayerStatus.ImagesWindows = "Processing"
			r.updateStatus(ctx, addon)
			for _, tarPath := range windowsImageTars {
				log.Info("Importing Windows container image", "file", filepath.Base(tarPath))
				cmd := exec.CommandContext(ctx, "nerdctl", "-n", "k8s.io", "load", "-i", tarPath)
				if output, err := cmd.CombinedOutput(); err != nil {
					log.Error(err, "Failed to import Windows image", "path", tarPath, "output", string(output))
				}
			}
			addon.Status.LayerStatus.ImagesWindows = "Completed"
		} else {
			addon.Status.LayerStatus.ImagesWindows = "Skipped"
		}
		addon.Status.LayerStatus.ImagesLinux = "Skipped"
	} else {
		addon.Status.LayerStatus.ImagesLinux = "Skipped"
		addon.Status.LayerStatus.ImagesWindows = "Skipped"
	}

	// Process packages
	if packagesPath != "" && !addon.Spec.Layers.SkipPackages {
		addon.Status.LayerStatus.Packages = "Processing"
		r.updateStatus(ctx, addon)
		if err := r.processExtractedPackages(ctx, packagesPath, addon, addonPath, log); err != nil {
			addon.Status.LayerStatus.Packages = "Failed"
			log.Error(err, "Failed to process packages")
		} else {
			addon.Status.LayerStatus.Packages = "Completed"
		}
	} else {
		addon.Status.LayerStatus.Packages = "Skipped"
	}

	return nil
}

func (r *K2sAddonReconciler) determineAddonPath(addon *K2sAddon) string {
	basePath := r.AddonsPath
	if basePath == "" {
		basePath = DefaultAddonsPath
	}

	if addon.Spec.Implementation != "" && addon.Spec.Implementation != addon.Spec.Name {
		return filepath.Join(basePath, addon.Spec.Name, addon.Spec.Implementation)
	}
	return filepath.Join(basePath, addon.Spec.Name)
}

func (r *K2sAddonReconciler) handleDeletion(ctx context.Context, addon *K2sAddon, log logr.Logger) (ctrl.Result, error) {
	log.Info("Handling addon deletion", "name", addon.Spec.Name)

	if addon.Status.AddonPath != "" {
		if err := os.RemoveAll(addon.Status.AddonPath); err != nil {
			log.Error(err, "Failed to remove addon directory")
		}
	}

	controllerutil.RemoveFinalizer(addon, K2sAddonFinalizer)
	return ctrl.Result{}, r.Update(ctx, addon)
}

// updateStatus updates the K2sAddon status with retry and merge logic to handle
// concurrent reconciliation by Linux and Windows controllers.
func (r *K2sAddonReconciler) updateStatus(ctx context.Context, addon *K2sAddon) error {
	desiredStatus := addon.Status.DeepCopy()

	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &K2sAddon{}
		if err := r.Get(ctx, client.ObjectKeyFromObject(addon), latest); err != nil {
			return err
		}

		r.mergeStatus(&latest.Status, desiredStatus)

		if err := r.Status().Update(ctx, latest); err != nil {
			return err
		}

		addon.ResourceVersion = latest.ResourceVersion
		return nil
	})
}

// mergeStatus merges desired status into target, preserving the other controller's
// image layer status.
func (r *K2sAddonReconciler) mergeStatus(target *K2sAddonStatus, desired *K2sAddonStatus) {
	// Always apply phase, availability, error, and path from this controller
	target.Phase = desired.Phase
	target.Available = desired.Available
	target.ErrorMessage = desired.ErrorMessage
	target.AddonPath = desired.AddonPath
	target.ObservedGeneration = desired.ObservedGeneration
	if desired.LastPulledDigest != "" {
		target.LastPulledDigest = desired.LastPulledDigest
	}
	if desired.LastProcessedTime != nil {
		target.LastProcessedTime = desired.LastProcessedTime
	}
	if desired.Conditions != nil {
		target.Conditions = desired.Conditions
	}

	// Always apply common layer statuses
	target.LayerStatus.Config = desired.LayerStatus.Config
	target.LayerStatus.Manifests = desired.LayerStatus.Manifests
	target.LayerStatus.Charts = desired.LayerStatus.Charts
	target.LayerStatus.Scripts = desired.LayerStatus.Scripts
	target.LayerStatus.Packages = desired.LayerStatus.Packages

	// Only overwrite image status for OUR node type, preserve the other's
	if r.NodeType == "linux" {
		target.LayerStatus.ImagesLinux = desired.LayerStatus.ImagesLinux
	} else if r.NodeType == "windows" {
		target.LayerStatus.ImagesWindows = desired.LayerStatus.ImagesWindows
	}

	if desired.NodeStatus != nil {
		target.NodeStatus = desired.NodeStatus
	}
}

// setCondition upserts a condition by Type, preventing duplicate entries.
func setCondition(conditions *[]metav1.Condition, c metav1.Condition) {
	for i, existing := range *conditions {
		if existing.Type == c.Type {
			(*conditions)[i] = c
			return
		}
	}
	*conditions = append(*conditions, c)
}

func (in *K2sAddonStatus) DeepCopy() *K2sAddonStatus {
	if in == nil {
		return nil
	}
	out := new(K2sAddonStatus)
	in.DeepCopyInto(out)
	return out
}

type dockerConfigJSON struct {
	Auths map[string]dockerAuthEntry `json:"auths"`
}

type dockerAuthEntry struct {
	Username string `json:"username"`
	Password string `json:"password"`
	Auth     string `json:"auth"`
}

func (r *K2sAddonReconciler) getRegistryCredentials(ctx context.Context, secretRef *SecretRef) (auth.Credential, error) {
	secret := &corev1.Secret{}
	namespace := secretRef.Namespace
	if namespace == "" {
		namespace = "default"
	}

	if err := r.Get(ctx, client.ObjectKey{Name: secretRef.Name, Namespace: namespace}, secret); err != nil {
		return auth.Credential{}, err
	}

	if dockerConfigData, ok := secret.Data[".dockerconfigjson"]; ok {
		var config dockerConfigJSON
		if err := json.Unmarshal(dockerConfigData, &config); err != nil {
			return auth.Credential{}, fmt.Errorf("failed to parse .dockerconfigjson: %w", err)
		}

		for registry, authEntry := range config.Auths {
			if authEntry.Username != "" && authEntry.Password != "" {
				r.Log.Info("Using credentials from dockerconfigjson", "registry", registry)
				return auth.Credential{
					Username: authEntry.Username,
					Password: authEntry.Password,
				}, nil
			}
			if authEntry.Auth != "" {
				decoded, err := base64Decode(authEntry.Auth)
				if err != nil {
					r.Log.Error(err, "Failed to decode auth field", "registry", registry)
					continue
				}
				parts := strings.SplitN(decoded, ":", 2)
				if len(parts) == 2 {
					r.Log.Info("Using credentials from dockerconfigjson auth field", "registry", registry)
					return auth.Credential{
						Username: parts[0],
						Password: parts[1],
					}, nil
				}
			}
		}
	}

	if username, ok := secret.Data["username"]; ok {
		return auth.Credential{
			Username: string(username),
			Password: string(secret.Data["password"]),
		}, nil
	}

	return auth.Credential{}, fmt.Errorf("no credentials found in secret %s/%s", namespace, secretRef.Name)
}

func (r *K2sAddonReconciler) getIndex(store *oci.Store) (*ocispec.Index, error) {
	ctx := context.Background()

	// Collect all tags from the OCI store
	var tags []string
	err := store.Tags(ctx, "", func(t []string) error {
		tags = append(tags, t...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list tags: %w", err)
	}

	index := &ocispec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2},
		Manifests: []ocispec.Descriptor{},
	}

	for _, tag := range tags {
		desc, err := store.Resolve(ctx, tag)
		if err != nil {
			r.Log.Error(err, "Failed to resolve tag", "tag", tag)
			continue
		}

		// If it is an index/manifest list, inline its manifests
		if desc.MediaType == ocispec.MediaTypeImageIndex ||
			desc.MediaType == "application/vnd.docker.distribution.manifest.list.v2+json" {
			reader, err := store.Fetch(ctx, desc)
			if err != nil {
				r.Log.Error(err, "Failed to fetch image index", "tag", tag)
				continue
			}
			data, err := io.ReadAll(reader)
			reader.Close()
			if err != nil {
				r.Log.Error(err, "Failed to read image index", "tag", tag)
				continue
			}
			var childIndex ocispec.Index
			if err := json.Unmarshal(data, &childIndex); err != nil {
				r.Log.Error(err, "Failed to unmarshal image index", "tag", tag)
				continue
			}
			index.Manifests = append(index.Manifests, childIndex.Manifests...)
		} else {
			index.Manifests = append(index.Manifests, desc)
		}
	}

	if len(index.Manifests) == 0 {
		return nil, fmt.Errorf("no manifests found in OCI store (tags found: %d)", len(tags))
	}

	return index, nil
}

func (r *K2sAddonReconciler) getManifest(ctx context.Context, store *oci.Store, desc ocispec.Descriptor) (*ocispec.Manifest, error) {
	reader, err := store.Fetch(ctx, desc)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch manifest: %w", err)
	}
	defer reader.Close()

	data, err := io.ReadAll(reader)
	if err != nil {
		return nil, fmt.Errorf("failed to read manifest: %w", err)
	}

	var manifest ocispec.Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("failed to unmarshal manifest: %w", err)
	}

	return &manifest, nil
}

func extractTar(tarPath, destDir string) error {
	f, err := os.Open(tarPath)
	if err != nil {
		return err
	}
	defer f.Close()
	return extractTarStreamToDir(f, destDir)
}

func extractTarToDir(reader io.Reader, destDir string) error {
	return extractTarStreamToDir(reader, destDir)
}

func extractTarGzToDir(reader io.Reader, destDir string) error {
	gzReader, err := gzip.NewReader(reader)
	if err != nil {
		return fmt.Errorf("failed to create gzip reader: %w", err)
	}
	defer gzReader.Close()
	return extractTarStreamToDir(gzReader, destDir)
}

func extractTarStreamToDir(reader io.Reader, destDir string) error {
	tarReader := tar.NewReader(reader)
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("failed to read tar header: %w", err)
		}

		// Prevent directory traversal
		if strings.Contains(header.Name, "..") {
			continue
		}
		targetPath := filepath.Join(destDir, header.Name)

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0755); err != nil {
				return fmt.Errorf("failed to create directory %s: %w", targetPath, err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0755); err != nil {
				return fmt.Errorf("failed to create parent directory for %s: %w", targetPath, err)
			}
			outFile, err := os.Create(targetPath)
			if err != nil {
				return fmt.Errorf("failed to create file %s: %w", targetPath, err)
			}
			if _, err := io.Copy(outFile, tarReader); err != nil {
				outFile.Close()
				return fmt.Errorf("failed to write file %s: %w", targetPath, err)
			}
			outFile.Close()
		}
	}
	return nil
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

// pullFromOCIRepository resolves a FluxCD OCIRepository CR and pulls the OCI artifact
// directly from the registry via ORAS (not via source-controller's HTTP endpoint).
// This preserves the full multi-layer OCI manifest with media types intact.
func (r *K2sAddonReconciler) pullFromOCIRepository(ctx context.Context, addon *K2sAddon, store *oci.Store, log logr.Logger) (*oci.Store, error) {
	ociRepoRef := addon.Spec.Source.OCIRepository
	if ociRepoRef == nil {
		return nil, fmt.Errorf("OCIRepository source type requires ociRepository reference")
	}

	log.Info("Resolving FluxCD OCIRepository", "name", ociRepoRef.Name, "namespace", ociRepoRef.Namespace)

	// Fetch the FluxCD OCIRepository CR as unstructured
	ociRepo := &unstructured.Unstructured{}
	ociRepo.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "source.toolkit.fluxcd.io",
		Version: "v1beta2",
		Kind:    "OCIRepository",
	})

	if err := r.Get(ctx, client.ObjectKey{Name: ociRepoRef.Name, Namespace: ociRepoRef.Namespace}, ociRepo); err != nil {
		return nil, fmt.Errorf("failed to get OCIRepository %s/%s: %w", ociRepoRef.Namespace, ociRepoRef.Name, err)
	}

	conditions, found, err := unstructured.NestedSlice(ociRepo.Object, "status", "conditions")
	if err != nil || !found {
		return nil, fmt.Errorf("OCIRepository %s/%s has no status conditions", ociRepoRef.Namespace, ociRepoRef.Name)
	}

	isReady := false
	var readyMessage string
	for _, c := range conditions {
		condMap, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if condMap["type"] == "Ready" {
			if condMap["status"] == "True" {
				isReady = true
			} else if msg, ok := condMap["message"].(string); ok {
				readyMessage = msg
			}
			break
		}
	}
	if !isReady {
		return nil, &errOCIRepositoryNotReady{
			name:      ociRepoRef.Name,
			namespace: ociRepoRef.Namespace,
			message:   readyMessage,
		}
	}

	specURL, _, _ := unstructured.NestedString(ociRepo.Object, "spec", "url")
	specTag, _, _ := unstructured.NestedString(ociRepo.Object, "spec", "ref", "tag")
	specInsecure, _, _ := unstructured.NestedBool(ociRepo.Object, "spec", "insecure")

	if specURL == "" || !strings.HasPrefix(specURL, "oci://") {
		return nil, fmt.Errorf("OCIRepository %s/%s has no valid spec.url (got: %q)", ociRepoRef.Namespace, ociRepoRef.Name, specURL)
	}

	ref := strings.TrimPrefix(specURL, "oci://")
	if specTag != "" {
		ref = ref + ":" + specTag
	}

	artifactDigest, _, _ := unstructured.NestedString(ociRepo.Object, "status", "artifact", "digest")

	log.Info("FluxCD OCIRepository is Ready — pulling directly from OCI registry",
		"ref", ref, "insecure", specInsecure, "artifactDigest", artifactDigest)

	origRef := addon.Spec.Source.OciRef
	origInsecure := addon.Spec.Source.Insecure
	addon.Spec.Source.OciRef = ref
	addon.Spec.Source.Insecure = specInsecure
	result, err := r.pullFromRegistry(ctx, addon, store, log)
	addon.Spec.Source.OciRef = origRef
	addon.Spec.Source.Insecure = origInsecure

	if err == nil && artifactDigest != "" {
		addon.Status.LastPulledDigest = artifactDigest
	}

	return result, err
}

func base64Decode(s string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// ociRepositoryToK2sAddon maps an OCIRepository change event to K2sAddon CRs that
// reference it, enabling automatic re-reconciliation on new artifact digests.
func (r *K2sAddonReconciler) ociRepositoryToK2sAddon(ctx context.Context, obj client.Object) []reconcile.Request {
	log := r.Log.WithValues("ocirepository", obj.GetName(), "namespace", obj.GetNamespace())

	var addonList K2sAddonList
	if err := r.List(ctx, &addonList); err != nil {
		log.Error(err, "Failed to list K2sAddons for OCIRepository mapping")
		return nil
	}

	var requests []reconcile.Request
	for _, addon := range addonList.Items {
		if addon.Spec.Source.Type != "OCIRepository" {
			continue
		}
		ref := addon.Spec.Source.OCIRepository
		if ref == nil {
			continue
		}
		if ref.Name == obj.GetName() && ref.Namespace == obj.GetNamespace() {
			log.Info("Enqueuing K2sAddon for OCIRepository change", "addon", addon.Name)
			requests = append(requests, reconcile.Request{
				NamespacedName: client.ObjectKeyFromObject(&addon),
			})
		}
	}

	return requests
}

// SetupWithManager registers the controller. Watches K2sAddon CRs as the primary
// resource and FluxCD OCIRepository CRs (if CRD exists) as a secondary trigger.
func (r *K2sAddonReconciler) SetupWithManager(mgr ctrl.Manager) error {
	builder := ctrl.NewControllerManagedBy(mgr).
		For(&K2sAddon{})

	// Only watch OCIRepository if CRD is installed (not present in ArgoCD-only setups)
	ociRepoGVK := schema.GroupVersionKind{
		Group:   "source.toolkit.fluxcd.io",
		Version: "v1beta2",
		Kind:    "OCIRepository",
	}
	if _, err := mgr.GetRESTMapper().RESTMapping(ociRepoGVK.GroupKind(), ociRepoGVK.Version); err == nil {
		ociRepo := &unstructured.Unstructured{}
		ociRepo.SetGroupVersionKind(ociRepoGVK)
		builder.Watches(ociRepo, handler.EnqueueRequestsFromMapFunc(r.ociRepositoryToK2sAddon))
		r.Log.Info("FluxCD OCIRepository CRD detected, watching for changes")
	} else {
		r.Log.Info("FluxCD OCIRepository CRD not found, skipping watch (direct OCI mode only)")
	}

	return builder.Complete(r)
}

// hasOCIRepositoryDigestChanged checks whether the FluxCD OCIRepository has a new
// artifact digest since the last successful pull.
func (r *K2sAddonReconciler) hasOCIRepositoryDigestChanged(ctx context.Context, addon *K2sAddon, log logr.Logger) (bool, error) {
	ociRepoRef := addon.Spec.Source.OCIRepository
	if ociRepoRef == nil {
		return false, nil
	}

	// Fetch the OCIRepository CR
	ociRepo := &unstructured.Unstructured{}
	ociRepo.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "source.toolkit.fluxcd.io",
		Version: "v1beta2",
		Kind:    "OCIRepository",
	})
	if err := r.Get(ctx, client.ObjectKey{Name: ociRepoRef.Name, Namespace: ociRepoRef.Namespace}, ociRepo); err != nil {
		return false, err
	}

	currentDigest, _, _ := unstructured.NestedString(ociRepo.Object, "status", "artifact", "digest")
	if currentDigest == "" {
		return false, nil
	}

	if addon.Status.LastPulledDigest == "" {
		log.Info("No previous digest stored, will re-process", "currentDigest", currentDigest)
		return true, nil
	}

	if currentDigest != addon.Status.LastPulledDigest {
		log.Info("OCIRepository artifact digest changed",
			"previous", addon.Status.LastPulledDigest, "current", currentDigest)
		return true, nil
	}

	return false, nil
}

func hashContent(content []byte) string {
	h := sha256.New()
	h.Write(content)
	return hex.EncodeToString(h.Sum(nil))
}

func AddToScheme(s *runtime.Scheme) error {
	gv := schema.GroupVersion{Group: "k2s.siemens-healthineers.com", Version: "v1alpha1"}
	s.AddKnownTypes(gv,
		&K2sAddon{},
		&K2sAddonList{},
	)
	metav1.AddToGroupVersion(s, gv)
	return nil
}
