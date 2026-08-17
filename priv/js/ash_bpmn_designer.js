/**
 * SPDX-FileCopyrightText: 2026 Luke Galea
 * SPDX-License-Identifier: MIT
 *
 * ash_bpmn designer/viewer Phoenix LiveView hooks.
 *
 * IMPORTANT: The bpmn.io watermark (".bjs-powered-by") must NEVER be removed,
 * hidden, or obscured.  It is required by the bpmn-js licence — bpmn.io is free
 * for any use including commercial, but attribution must stay visible.
 */

import Modeler from 'bpmn-js/lib/Modeler';
import Viewer from 'bpmn-js/lib/Viewer';

import 'bpmn-js/dist/assets/diagram-js.css';
import 'bpmn-js/dist/assets/bpmn-js.css';
import 'bpmn-js/dist/assets/bpmn-font/css/bpmn-embedded.css';

// The marker styles the viewer's highlight relies on. Without this the marker
// class lands on the element and paints nothing.
import './ash_bpmn.css';

// ---------------------------------------------------------------------------
// Moddle descriptor — ash: extension namespace
// URI:  https://github.com/lukegalea/ash_bpmn/ns
// Prefix: ash
//
// Vocabulary (DESIGN.md §3):
//   TaskConfig   attrs: action?, outcome?
//                children: candidates, exclusions, outcomes, timers
//   Candidates   child: candidate
//   Candidate    attrs: kind, of
//   Exclusions   child: exclusion
//   Exclusion    attrs: who
//   Outcomes     child: outcome
//   Outcome      attrs: name
//   Timers       child: timer
//   Timer        attrs: kind, minutes?, hours?, days?
//
// The package declares `xml: { tagAlias: 'lowerCase' }`, the same way
// camunda-bpmn-moddle does. Without it moddle looks for <ash:TaskConfig> and
// reports "unparsable content / unknown type" for the <ash:taskConfig> the
// compiler actually reads — so the modeller drops every binding on import and
// saves the diagram back with its ash: configuration silently erased.
// ---------------------------------------------------------------------------

export const ashBpmnModdle = {
  name: 'ash',
  uri: 'https://github.com/lukegalea/ash_bpmn/ns',
  prefix: 'ash',
  xml: { tagAlias: 'lowerCase' },
  types: [
    {
      name: 'TaskConfig',
      superClass: ['Element'],
      properties: [
        { name: 'action', type: 'String', isAttr: true },
        { name: 'outcome', type: 'String', isAttr: true },
        { name: 'candidates', type: 'Candidates' },
        { name: 'exclusions', type: 'Exclusions' },
        { name: 'outcomes', type: 'Outcomes' },
        { name: 'timers', type: 'Timers' }
      ]
    },
    {
      name: 'Candidates',
      superClass: ['Element'],
      properties: [
        { name: 'candidate', type: 'Candidate', isMany: true }
      ]
    },
    {
      name: 'Candidate',
      superClass: ['Element'],
      properties: [
        { name: 'kind', type: 'String', isAttr: true },
        { name: 'of', type: 'String', isAttr: true }
      ]
    },
    {
      name: 'Exclusions',
      superClass: ['Element'],
      properties: [
        { name: 'exclusion', type: 'Exclusion', isMany: true }
      ]
    },
    {
      name: 'Exclusion',
      superClass: ['Element'],
      properties: [
        { name: 'who', type: 'String', isAttr: true }
      ]
    },
    {
      name: 'Outcomes',
      superClass: ['Element'],
      properties: [
        { name: 'outcome', type: 'Outcome', isMany: true }
      ]
    },
    {
      name: 'Outcome',
      superClass: ['Element'],
      properties: [
        { name: 'name', type: 'String', isAttr: true }
      ]
    },
    {
      name: 'Timers',
      superClass: ['Element'],
      properties: [
        { name: 'timer', type: 'Timer', isMany: true }
      ]
    },
    {
      name: 'Timer',
      superClass: ['Element'],
      properties: [
        { name: 'kind', type: 'String', isAttr: true },
        { name: 'minutes', type: 'Integer', isAttr: true },
        { name: 'hours', type: 'Integer', isAttr: true },
        { name: 'days', type: 'Integer', isAttr: true }
      ]
    }
  ]
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function pushError(hook, err) {
  hook.pushEvent('import_error', {
    message: String(err?.message || err)
  });
}

/**
 * Read an element's existing ash:TaskConfig back into a plain object, in the
 * same shape buildTaskConfig consumes.
 *
 * The server only ever sees the last *saved* XML, so without this the
 * properties panel would render blank fields for an already-configured node —
 * and Apply, which rewrites extensionElements from scratch, would erase the
 * configuration the user was looking at.
 */
function readTaskConfig(element) {
  const bo = element && element.businessObject;
  const ext = bo && bo.get && bo.get('extensionElements');
  const values = ext ? ext.get('values') || [] : [];
  const cfg = values.filter(function (v) {
    return v.$type === 'ash:TaskConfig';
  })[0];

  if (!cfg) return {};

  const list = function (holder, prop) {
    if (!holder) return [];
    return holder.get(prop) || [];
  };

  return {
    action: cfg.action || '',
    outcome: cfg.outcome || '',
    candidates: list(cfg.candidates, 'candidate').map(function (c) {
      return { kind: c.kind || '', of: c.of || '' };
    }),
    exclusions: list(cfg.exclusions, 'exclusion').map(function (e) {
      return { who: e.who || '' };
    }),
    outcomes: list(cfg.outcomes, 'outcome').map(function (o) {
      return o.name || '';
    }),
    timers: list(cfg.timers, 'timer').map(function (t) {
      return {
        kind: t.kind || '',
        minutes: t.minutes != null ? t.minutes : null,
        hours: t.hours != null ? t.hours : null,
        days: t.days != null ? t.days : null
      };
    })
  };
}

/**
 * Build an ash:TaskConfig moddle element tree from a server config map.
 * The config map uses string keys (JSON round-tripped from Elixir).
 *
 * Shape (DESIGN.md §5 / §7.1):
 *   action?:    string
 *   outcome?:   string
 *   candidates?: [{ kind, of }]
 *   exclusions?: [{ who }]
 *   outcomes?:   string[] | [{ name }]
 *   timers?:     [{ kind, minutes?, hours?, days? }]
 */
function buildTaskConfig(moddle, config) {
  const props = {};

  if (config.action !== undefined && config.action !== null) {
    props.action = config.action;
  }
  if (config.outcome !== undefined && config.outcome !== null) {
    props.outcome = config.outcome;
  }

  if (Array.isArray(config.candidates) && config.candidates.length > 0) {
    props.candidates = moddle.create('ash:Candidates', {
      candidate: config.candidates.map(function (c) {
        return moddle.create('ash:Candidate', {
          kind: String(c.kind || ''),
          of: String(c.of || '')
        });
      })
    });
  }

  if (Array.isArray(config.exclusions) && config.exclusions.length > 0) {
    props.exclusions = moddle.create('ash:Exclusions', {
      exclusion: config.exclusions.map(function (e) {
        return moddle.create('ash:Exclusion', {
          who: String(e.who || '')
        });
      })
    });
  }

  if (Array.isArray(config.outcomes) && config.outcomes.length > 0) {
    props.outcomes = moddle.create('ash:Outcomes', {
      outcome: config.outcomes.map(function (o) {
        var name = typeof o === 'string' ? o : (o.name || '');
        return moddle.create('ash:Outcome', { name: String(name) });
      })
    });
  }

  if (Array.isArray(config.timers) && config.timers.length > 0) {
    props.timers = moddle.create('ash:Timers', {
      timer: config.timers.map(function (t) {
        return moddle.create('ash:Timer', {
          kind: String(t.kind || ''),
          minutes: t.minutes != null ? Number(t.minutes) : undefined,
          hours: t.hours != null ? Number(t.hours) : undefined,
          days: t.days != null ? Number(t.days) : undefined
        });
      })
    });
  }

  return moddle.create('ash:TaskConfig', props);
}

/**
 * Return a new bpmn:ExtensionElements containing the given taskConfig and
 * any pre-existing extension values that are NOT ash:TaskConfig.
 */
function rebuildExtensionElements(moddle, businessObject, taskConfig) {
  var existing = businessObject.get('extensionElements');
  var otherValues = existing
    ? (existing.get('values') || []).filter(function (v) {
        return v.$type !== 'ash:TaskConfig';
      })
    : [];

  return moddle.create('bpmn:ExtensionElements', {
    values: otherValues.concat([taskConfig])
  });
}

// ---------------------------------------------------------------------------
// resolveContainer — find the .ash-bpmn-canvas element to attach bpmn-js to.
// ---------------------------------------------------------------------------

function resolveContainer(el) {
  var child = el.querySelector('.ash-bpmn-canvas');
  if (child) return child;
  if (el.classList.contains('ash-bpmn-canvas')) return el;
  return null;
}

// ---------------------------------------------------------------------------
// AshBpmnDesigner — Phoenix LiveView hook  (plain object, NOT a class)
//
// Hook → LV  (pushEvent):
//   save_xml          %{ xml: string }
//   selection_changed %{ id, type, name }   |  %{}  (empty)
//   dirty_changed     %{ dirty: boolean }
//   import_error      %{ message: string }
//
// LV → Hook  (handleEvent):
//   load_xml     %{ xml }
//   collect_xml  %{}
//   apply_config %{ id, config, name }
//   fit          %{}
// ---------------------------------------------------------------------------

export const AshBpmnDesigner = {
  mounted() {
    var container = resolveContainer(this.el);
    if (!container) {
      pushError(this, 'AshBpmnDesigner: no .ash-bpmn-canvas container found');
      return;
    }

    try {
      this._modeler = new Modeler({
        container: container,
        moddleExtensions: { ash: ashBpmnModdle }
      });
    } catch (err) {
      pushError(this, err);
      return;
    }

    var eventBus = this._modeler.get('eventBus');
    var canvas = this._modeler.get('canvas');

    // -----------------------------------------------------------------------
    // Track selection — push only when identity actually changes
    // -----------------------------------------------------------------------
    this._currentSelection = null;

    eventBus.on('selection.changed', function (evt) {
      var newSelection = evt.newSelection;
      var sel;
      if (!newSelection || newSelection.length === 0) {
        sel = {};
      } else {
        var el = newSelection[0];
        sel = {
          id: el.id,
          type: el.businessObject.$type,
          name: el.businessObject.name || '',
          config: readTaskConfig(el)
        };
      }

      var selKey = JSON.stringify(sel);
      var prevKey = JSON.stringify(this._currentSelection);

      if (selKey !== prevKey) {
        this._currentSelection = sel;
        this.pushEvent('selection_changed', sel);
      }
    }.bind(this));

    // -----------------------------------------------------------------------
    // Track dirty via commandStack
    // -----------------------------------------------------------------------
    eventBus.on('commandStack.changed', function () {
      this.pushEvent('dirty_changed', { dirty: true });
    }.bind(this));

    // -----------------------------------------------------------------------
    // Initial import from data-xml attribute
    // -----------------------------------------------------------------------
    var xml = this.el.dataset.xml || '';
    if (xml) {
      this._modeler
        .importXML(xml)
        .then(function () {
          canvas.zoom('fit-viewport', 'auto');
          this._currentSelection = null;
        }.bind(this))
        .catch(function (err) {
          pushError(this, err);
        }.bind(this));
    }

    // -----------------------------------------------------------------------
    // Server → client event handlers
    // -----------------------------------------------------------------------

    this.handleEvent('load_xml', function (payload) {
      this._modeler
        .importXML(payload.xml)
        .then(function () {
          canvas.zoom('fit-viewport', 'auto');
          this._currentSelection = null;
          this.pushEvent('dirty_changed', { dirty: false });
        }.bind(this))
        .catch(function (err) {
          pushError(this, err);
        }.bind(this));
    }.bind(this));

    this.handleEvent('collect_xml', function () {
      this._modeler
        .saveXML({ format: true })
        .then(function (result) {
          this.pushEvent('save_xml', { xml: result.xml });
        }.bind(this))
        .catch(function (err) {
          pushError(this, err);
        }.bind(this));
    }.bind(this));

    this.handleEvent('apply_config', function (payload) {
      try {
        var elementRegistry = this._modeler.get('elementRegistry');
        var modeling = this._modeler.get('modeling');
        var moddle = this._modeler.get('moddle');

        var element = elementRegistry.get(payload.id);
        if (!element) {
          pushError(
            this,
            'apply_config: element "' + payload.id + '" not found in diagram'
          );
          return;
        }

        var taskConfig = buildTaskConfig(moddle, payload.config || {});
        var bo = element.businessObject;
        var newExt = rebuildExtensionElements(moddle, bo, taskConfig);

        var updates = { extensionElements: newExt };
        if (payload.name !== undefined && payload.name !== null) {
          updates.name = payload.name;
        }

        modeling.updateProperties(element, updates);
        this.pushEvent('dirty_changed', { dirty: true });
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this));

    this.handleEvent('fit', function () {
      try {
        canvas.zoom('fit-viewport', 'auto');
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this));
  },

  destroyed() {
    if (this._modeler) {
      this._modeler.destroy();
      this._modeler = null;
    }
  }
};

// ---------------------------------------------------------------------------
// AshBpmnViewer — Phoenix LiveView hook (plain object, NOT a class)
//
// LV → Hook  (handleEvent):
//   highlight  %{ node_ids: [string] }
//   fit        %{}
// ---------------------------------------------------------------------------

export const AshBpmnViewer = {
  mounted() {
    var container = resolveContainer(this.el);
    if (!container) {
      pushError(this, 'AshBpmnViewer: no .ash-bpmn-canvas container found');
      return;
    }

    try {
      this._viewer = new Viewer({
        container: container,
        moddleExtensions: { ash: ashBpmnModdle }
      });
    } catch (err) {
      pushError(this, err);
      return;
    }

    var canvas = this._viewer.get('canvas');
    this._highlightedIds = new Set();

    // The server pushes `highlight` from its first render, which can land
    // before importXML resolves — and markers cannot be applied to elements
    // that do not exist yet. Hold the last payload and replay it on import.
    this._imported = false;
    this._pendingHighlight = null;

    // Initial import from data-xml attribute
    var xml = this.el.dataset.xml || '';
    if (xml) {
      this._viewer
        .importXML(xml)
        .then(function () {
          canvas.zoom('fit-viewport', 'auto');
          this._imported = true;

          if (this._pendingHighlight) {
            var pending = this._pendingHighlight;
            this._pendingHighlight = null;
            this._applyHighlight(pending);
          }
        }.bind(this))
        .catch(function (err) {
          pushError(this, err);
        }.bind(this));
    }

    // -----------------------------------------------------------------------
    // Server → client event handlers
    // -----------------------------------------------------------------------

    this._applyHighlight = function (payload) {
      try {
        var elementRegistry = this._viewer.get('elementRegistry');

        // Clear previous highlights
        var _this = this;
        this._highlightedIds.forEach(function (prevId) {
          var prev = elementRegistry.get(prevId);
          if (prev) {
            canvas.removeMarker(prev, 'ash-bpmn-highlight');
          }
        });
        this._highlightedIds.clear();

        // Apply new highlights
        var nodeIds = payload.node_ids;
        if (Array.isArray(nodeIds)) {
          nodeIds.forEach(function (nodeId) {
            var el = elementRegistry.get(nodeId);
            if (el) {
              canvas.addMarker(el, 'ash-bpmn-highlight');
              _this._highlightedIds.add(nodeId);
            }
          });
        }
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this);

    this.handleEvent('highlight', function (payload) {
      if (this._imported) {
        this._applyHighlight(payload);
      } else {
        this._pendingHighlight = payload;
      }
    }.bind(this));

    this.handleEvent('fit', function () {
      try {
        canvas.zoom('fit-viewport', 'auto');
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this));
  },

  destroyed() {
    if (this._viewer) {
      this._viewer.destroy();
      this._viewer = null;
    }
  }
};
