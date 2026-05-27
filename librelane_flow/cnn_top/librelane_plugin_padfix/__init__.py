from __future__ import annotations

import os
from typing import Tuple

from librelane.common import Path, mkdirp
from librelane.state import DesignFormat, State
from librelane.steps import MetricsUpdate, Step, ViewsUpdate

from normalize_magic_lvs_spice import DEFAULT_TOP_PORTS, normalize_spice


@Step.factory.register()
class PadFix(Step):
    """
    Normalizes Magic's abstract sky130 pad SPICE before Netgen LVS.

    This step is intentionally placed between Magic.SpiceExtraction and
    Netgen.LVS. It rewrites only the extracted top-level SPICE connectivity
    that Magic exposes differently when pads are read from abstract views.
    """

    id = "Netgen.PadFix"
    name = "Netgen Pad Fix"
    long_name = "Normalize Abstract Pad SPICE for Netgen"

    inputs = [DesignFormat.SPICE]
    outputs = [DesignFormat.SPICE]

    def run(self, state_in: State, **kwargs) -> Tuple[ViewsUpdate, MetricsUpdate]:
        design_name = self.config["DESIGN_NAME"]
        input_spice = state_in[DesignFormat.SPICE]
        output_spice = Path(os.path.join(self.step_dir, f"{design_name}.padfix.spice"))

        mkdirp(self.step_dir)
        output_spice.write_text(
            normalize_spice(
                input_spice.read_text(),
                design_name,
                DEFAULT_TOP_PORTS,
            )
        )

        metrics_updates: MetricsUpdate = {
            "design__lvs_padfix__count": 1,
        }
        return {DesignFormat.SPICE: output_spice}, metrics_updates
