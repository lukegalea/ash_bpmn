/**
 * SPDX-FileCopyrightText: 2026 Luke Galea
 * SPDX-License-Identifier: MIT
 *
 * The package's LiveView hooks, for hosts to register (see README and
 * documentation/topics/the-designer.md).
 *
 * No top-level imports: hosts import this file on every page, so it must not
 * pull in a hook's dependencies (bpmn-js and friends) — those arrive only
 * when a `load` below runs.
 *
 * `events`: every event name the hook passes to handleEvent; a host that
 * loads the hook lazily subscribes to these before the code arrives.
 * `load`: fetches the hook's code and resolves to the hook object.
 */

export const hooks = {
  AshBpmnDesigner: {
    events: ["load_xml", "collect_xml", "apply_config", "highlight", "select_element", "fit"],
    load: () => import("./ash_bpmn_designer.js").then((m) => m.AshBpmnDesigner),
  },
  AshBpmnViewer: {
    events: ["highlight", "fit"],
    load: () => import("./ash_bpmn_designer.js").then((m) => m.AshBpmnViewer),
  },
};
