package nodeagent

import (
	"os"

	"github.com/sirupsen/logrus"
)

// selectNodeagentZboot keeps the original EVE backend by default.
// On NixOS, NodeAgent can run without assuming EVE A/B partitions.
func selectNodeagentZboot() Zboot {
	if os.Getenv("EVE_NODEAGENT_BOOT_BACKEND") == "nixos" {
		logrus.Info("NodeAgent: using NixOS boot compatibility backend")
		return nixosZboot{}
	}

	return realZboot{}
}

// nixosZboot represents a system without EVE-managed A/B partitions.
// It does not emulate IMGA or IMGB.
type nixosZboot struct{}

func (nixosZboot) EveCurrentPartition() string {
	return ""
}

func (nixosZboot) IsCurrentPartitionStateInProgress() bool {
	return false
}

func (nixosZboot) IsValidPartitionLabel(string) bool {
	return false
}

func (nixosZboot) GetValidPartitionLabels() []string {
	return nil
}

func (nixosZboot) GetOtherPartition() string {
	return ""
}

func (nixosZboot) IsOtherPartitionStateUpdating() bool {
	return false
}

func (nixosZboot) Reset() {
	logrus.Error("NodeAgent: reboot is not supported by the NixOS boot backend")
}

func (nixosZboot) Poweroff() {
	logrus.Error("NodeAgent: poweroff is not supported by the NixOS boot backend")
}
