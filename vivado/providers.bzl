"""Describe Vivado providers."""

VivadoSynthCheckpointInfo = provider(
    doc = "Contains infomation at output of synthesis.",
    fields = {
        "checkpoint": "A vivado checkpoint.",
    },
)

VivadoPlacementCheckpointInfo = provider(
    doc = "Contains infomation at output of placement.",
    fields = {
        "checkpoint": "A vivado checkpoint.",
    },
)

VivadoRoutingCheckpointInfo = provider(
    doc = "Contains infomation at output of routing.",
    fields = {
        "checkpoint": "A vivado checkpoint.",
    },
)
