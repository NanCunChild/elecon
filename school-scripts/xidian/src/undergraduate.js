/*! Copyright 2026 elecon contributors. SPDX-License-Identifier: MPL-2.0 */

import { climateCommand, climateDevices, climateStatus } from "./climate.js";
import { energyMeters, energyUsage } from "./energy.js";
import { createCapabilities } from "./index.js";

const undergraduate =
  (handler) =>
  async (ctx, params = {}) => {
    if (params.role != null && params.role !== "undergraduate")
      throw new Error("xidian_school_role_mismatch");
    return handler(ctx, params);
  };
export const capabilities = {
  ...createCapabilities("undergraduate"),
  "energy.meters": undergraduate(energyMeters),
  "energy.usage": undergraduate(energyUsage),
  "climate.devices": undergraduate(climateDevices),
  "climate.status": undergraduate(climateStatus),
  "climate.command": undergraduate(climateCommand),
};
