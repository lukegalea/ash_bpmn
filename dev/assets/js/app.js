// SPDX-FileCopyrightText: 2026 Luke Galea
// SPDX-License-Identifier: MIT
//
// The demo app's bundle. This is exactly the wiring a host application does:
// import the hooks from the library's priv/js, register them on the LiveSocket,
// and let the app's own bundler resolve bpmn-js from its node_modules.

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import {
  AshBpmnDesigner,
  AshBpmnViewer,
} from "../../../priv/js/ash_bpmn_designer.js";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { AshBpmnDesigner, AshBpmnViewer },
});

liveSocket.connect();
window.liveSocket = liveSocket;
