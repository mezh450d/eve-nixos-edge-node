package baseosmgr

import (
	"errors"
	"os"
)

var errNixOSABUnsupported = errors.New(
	"EVE A/B partition management is unsupported on NixOS",
)

// Use the native EVE implementation unless explicitly configured
// to run on NixOS without EVE-managed A/B partitions.
func selectBaseosmgrZboot(fallback Zboot) Zboot {
	if os.Getenv("EVE_BASEOSMGR_BOOT_BACKEND") == "nixos" {
		log.Noticef("baseosmgr: using NixOS no-A/B boot backend")
		return nixosBaseosmgrZboot{}
	}
	return fallback
}

type nixosBaseosmgrZboot struct{}

func (nixosBaseosmgrZboot) GetCurrentPartition() string {
	return ""
}

func (nixosBaseosmgrZboot) GetOtherPartition() string {
	return ""
}

func (nixosBaseosmgrZboot) GetValidPartitionLabels() []string {
	return nil
}

func (nixosBaseosmgrZboot) IsValidPartitionLabel(string) bool {
	return false
}

func (nixosBaseosmgrZboot) IsCurrentPartition(string) bool {
	return false
}

func (nixosBaseosmgrZboot) IsOtherPartition(string) bool {
	return false
}

func (nixosBaseosmgrZboot) GetPartitionState(string) string {
	return ""
}

func (nixosBaseosmgrZboot) GetPartitionDevname(string) string {
	return ""
}

func (nixosBaseosmgrZboot) GetPartitionSizeInBytes(string) uint64 {
	return 0
}

func (nixosBaseosmgrZboot) GetShortVersion(string) (string, error) {
	return "", errNixOSABUnsupported
}

func (nixosBaseosmgrZboot) GetLongVersion(string) string {
	return ""
}

// Fail closed: never perform EVE partition mutations on NixOS.
func (nixosBaseosmgrZboot) SetOtherPartitionStateUpdating() {
	panic(errNixOSABUnsupported)
}

func (nixosBaseosmgrZboot) SetOtherPartitionStateUnused() {
	panic(errNixOSABUnsupported)
}

func (nixosBaseosmgrZboot) MarkCurrentPartitionStateActive() error {
	return errNixOSABUnsupported
}

func (nixosBaseosmgrZboot) WriteToPartition(string, string) error {
	return errNixOSABUnsupported
}
