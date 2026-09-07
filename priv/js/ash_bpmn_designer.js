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
    // --- businessRuleTask -------------------------------------------------
    // A decision reference, its declared inputs, and the signals it promotes onto the token.
    // These must be registered here or bpmn-js drops them on save: moddle only round-trips
    // extension elements it has a descriptor for, and the loss is silent.
    {
      name: 'Decision',
      superClass: ['Element'],
      properties: [
        { name: 'ref', type: 'String', isAttr: true },
        { name: 'binding', type: 'String', isAttr: true },
        { name: 'version', type: 'String', isAttr: true },
        // The decision's name inside a multi-decision key. Optional.
        { name: 'name', type: 'String', isAttr: true }
      ]
    },
    {
      name: 'Inputs',
      superClass: ['Element'],
      properties: [
        { name: 'input', type: 'Input', isMany: true }
      ]
    },
    {
      name: 'Input',
      superClass: ['Element'],
      properties: [
        { name: 'name', type: 'String', isAttr: true },
        // A FEEL expression over the process context, evaluated by the engine before the
        // decision is called -- the host is never asked to evaluate anything.
        { name: 'from', type: 'String', isAttr: true }
      ]
    },
    {
      name: 'Promote',
      superClass: ['Element'],
      properties: [
        { name: 'signal', type: 'Signal', isMany: true }
      ]
    },
    {
      name: 'Signal',
      superClass: ['Element'],
      properties: [
        { name: 'name', type: 'String', isAttr: true },
        // Which of the callee's outputs this signal takes; defaults to the signal's own
        // name. Without this descriptor entry moddle drops the attribute on import and
        // a custom-named signal silently reverts to its default source.
        { name: 'from', type: 'String', isAttr: true },
        { name: 'required', type: 'String', isAttr: true }
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
 * Read an element's existing ash: bindings back into a plain object, in the
 * same shape buildAshValues consumes.
 *
 * The server only ever sees the last *saved* XML, so without this the
 * properties panel would render blank fields for an already-configured node —
 * and Apply, which rewrites extensionElements from scratch, would erase the
 * configuration the user was looking at.
 *
 * The element type decides which ash: elements the panel owns:
 *   - BusinessRuleTask: ash:decision + ash:inputs + ash:promote
 *   - ServiceTask / SendTask: ash:taskConfig(action) + ash:inputs + ash:promote
 *   - UserTask / EndEvent: ash:taskConfig(candidates/outcomes/…)
 *
 * Sequence flows and exclusive gateways carry no ash: vocabulary, but the
 * panel edits two plain-BPMN features on them — the flow's FEEL condition
 * (conditionExpression child) and the gateway's default flow (default
 * attribute) — so readConfig surfaces those in the same payload.
 */
function readConfig(element) {
  const bo = element && element.businessObject;
  if (!bo) return {};

  const type = bo.$type;
  const ext = bo.get && bo.get('extensionElements');
  const values = ext ? ext.get('values') || [] : [];

  const find = function ($type) {
    return values.filter(function (v) {
      return v.$type === $type;
    })[0];
  };

  const list = function (holder, prop) {
    if (!holder) return [];
    return holder.get(prop) || [];
  };

  const conditionBody = function (flowBo) {
    var expr = flowBo.get('conditionExpression');
    return expr && nonBlank(expr.get('body')) ? expr.get('body') : '';
  };

  const readInputs = function () {
    const holder = find('ash:Inputs');
    return list(holder, 'input').map(function (i) {
      return { name: i.name || '', from: i.from || '' };
    });
  };

  const readPromote = function () {
    const holder = find('ash:Promote');
    return list(holder, 'signal').map(function (s) {
      return { name: s.name || '', from: s.from || '', required: s.required || 'false' };
    });
  };

  if (type === 'bpmn:SequenceFlow') {
    const source = bo.get('sourceRef');

    return {
      condition: conditionBody(bo),
      // Set when the source gateway routes to this flow when nothing matches —
      // the panel then explains why the flow must not carry a condition.
      default_of:
        source && source.get && source.get('default') === bo ? source.id || '' : null
    };
  }

  if (type === 'bpmn:ExclusiveGateway') {
    const outgoing = (bo.get('outgoing') || []).map(function (flow) {
      return { id: flow.id, name: flow.name || '', condition: conditionBody(flow) !== '' };
    });

    const def = bo.get('default');

    return {
      outgoing: outgoing,
      default: def ? def.id : ''
    };
  }

  if (type === 'bpmn:BusinessRuleTask') {
    const decision = find('ash:Decision');

    return {
      decision: decision
        ? {
            ref: decision.ref || '',
            binding: decision.binding || 'latest',
            version: decision.version != null ? decision.version : '',
            name: decision.name || ''
          }
        : null,
      inputs: readInputs(),
      promote: readPromote()
    };
  }

  if (type === 'bpmn:ServiceTask' || type === 'bpmn:SendTask') {
    const cfg = find('ash:TaskConfig');
    if (!cfg) return {};

    return {
      action: cfg.action || '',
      inputs: readInputs(),
      promote: readPromote()
    };
  }

  const cfg = find('ash:TaskConfig');
  if (!cfg) return {};

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
 *
 * Blank optional attributes are omitted rather than written as empty strings —
 * the compiler treats an empty action on a userTask's taskConfig as an unknown
 * attribute, so writing one would corrupt a config the panel never showed.
 */
function buildTaskConfig(moddle, config) {
  const props = {};

  if (nonBlank(config.action)) {
    props.action = String(config.action);
  }
  if (nonBlank(config.outcome)) {
    props.outcome = String(config.outcome);
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
 * Build the ash: elements a given element type owns, from a server config map.
 * Returns a list: for a BusinessRuleTask [ash:Decision, ash:Inputs?, ash:Promote?],
 * for everything taskConfig-shaped [ash:TaskConfig, ash:Inputs?, ash:Promote?].
 *
 * Optional attributes are omitted when blank: name unless set, version unless the
 * binding is pinned, from unless the signal redirects. binding and required get
 * their defaults ("latest" / "false") when the row carried them blank, so a
 * save → load → save round-trip is stable.
 */
function buildAshValues(moddle, type, config) {
  const values = [];

  if (type === 'bpmn:BusinessRuleTask') {
    const d = config.decision;
    if (d) {
      const props = {};
      if (nonBlank(d.ref)) props.ref = String(d.ref);
      props.binding = String(nonBlank(d.binding) ? d.binding : 'latest');
      if (d.binding === 'pinned' && nonBlank(d.version)) {
        props.version = String(d.version);
      }
      if (nonBlank(d.name)) props.name = String(d.name);
      values.push(moddle.create('ash:Decision', props));
    }
  } else {
    values.push(buildTaskConfig(moddle, config));
  }

  if (Array.isArray(config.inputs) && config.inputs.length > 0) {
    values.push(
      moddle.create('ash:Inputs', {
        input: config.inputs.map(function (i) {
          const props = { name: String(i.name || '') };
          if (nonBlank(i.from)) props.from = String(i.from);
          return moddle.create('ash:Input', props);
        })
      })
    );
  }

  if (Array.isArray(config.promote) && config.promote.length > 0) {
    values.push(
      moddle.create('ash:Promote', {
        signal: config.promote.map(function (s) {
          const props = { name: String(s.name || '') };
          if (nonBlank(s.from)) props.from = String(s.from);
          props.required = truthy(s.required) ? 'true' : 'false';
          return moddle.create('ash:Signal', props);
        })
      })
    );
  }

  return values;
}

/**
 * The ash: extension element types each element type OWNS — the ones Apply
 * replaces. Everything else in extensionElements (other namespaces' elements,
 * other tools' extensions) survives untouched.
 */
function ownedAshTypes(type) {
  if (type === 'bpmn:BusinessRuleTask') {
    return ['ash:Decision', 'ash:Inputs', 'ash:Promote'];
  }
  if (type === 'bpmn:ServiceTask' || type === 'bpmn:SendTask') {
    return ['ash:TaskConfig', 'ash:Inputs', 'ash:Promote'];
  }
  return ['ash:TaskConfig'];
}

/**
 * Return a new bpmn:ExtensionElements containing the given ash: values and
 * any pre-existing extension values that are NOT owned by this element type.
 */
function rebuildExtensionElements(moddle, businessObject, type, ashValues) {
  const owned = {};
  ownedAshTypes(type).forEach(function (t) {
    owned[t] = true;
  });

  const existing = businessObject.get('extensionElements');
  const otherValues = existing
    ? (existing.get('values') || []).filter(function (v) {
        return !owned[v.$type];
      })
    : [];

  return moddle.create('bpmn:ExtensionElements', {
    values: otherValues.concat(ashValues)
  });
}

/**
 * Build a bpmn:FormalExpression for a flow condition. An empty/blank source
 * returns undefined, which is how bpmn-js itself clears the condition — the
 * same idiom ReplaceConnectionBehavior uses.
 *
 * The language attribute, when the existing expression declared one, is kept:
 * the compiler accepts feel/FEEL/absent, but the document should not lose what
 * its author wrote.
 */
function buildConditionExpression(moddle, businessObject, source) {
  if (!nonBlank(source)) return undefined;

  const props = { body: String(source).trim() };

  const existing = businessObject.get('conditionExpression');
  if (existing && existing.language) {
    props.language = existing.language;
  }

  return moddle.create('bpmn:FormalExpression', props);
}

/**
 * Resolve one of a gateway's outgoing flows by id — the default-flow picker's
 * options all come from bo.outgoing, so a miss means the panel and the canvas
 * disagree and must not be written blindly.
 */
function resolveOutgoingFlow(gatewayBo, flowId) {
  const outgoing = gatewayBo.get('outgoing') || [];

  for (var i = 0; i < outgoing.length; i++) {
    if (outgoing[i].id === flowId) return outgoing[i];
  }

  return undefined;
}

function nonBlank(value) {
  return value !== undefined && value !== null && String(value).trim() !== '';
}

function truthy(value) {
  return value === 'true' || value === '1' || value === true;
}

// Every bpmn:* gateway type — none of them own ash: extension elements, and
// the default-flow picker the panel renders applies to whichever gateway the
// descriptor gives a `default` attribute.
function endsWithGateway(type) {
  return typeof type === 'string' && type.indexOf(':') !== -1 &&
    type.slice(type.indexOf(':') + 1).endsWith('Gateway');
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

// A highlight that arrived mid-import is held on the hook; this runs once the
// import resolves and the elements exist to mark.
function replayPendingErrorHighlight(hook) {
  if (hook._pendingErrorHighlight) {
    var pending = hook._pendingErrorHighlight;
    hook._pendingErrorHighlight = null;
    hook._applyErrorHighlight(pending);
  }
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
//   load_xml      %{ xml }
//   collect_xml   %{}
//   apply_config  %{ id, config, name, condition?, default_flow? }
//                    condition    — sequence flow FEEL source (blank clears)
//                    default_flow — exclusive gateway default flow id (blank clears)
//   highlight     %{ node_ids: [string] }   — compile-error markers
//   select_element %{ id }                  — select + scroll to an element
//   fit           %{}
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
          config: readConfig(el)
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
          this._imported = true;
          replayPendingErrorHighlight(this);
        }.bind(this))
        .catch(function (err) {
          pushError(this, err);
        }.bind(this));
    }

    // -----------------------------------------------------------------------
    // Server → client event handlers
    // -----------------------------------------------------------------------

    this.handleEvent('load_xml', function (payload) {
      this._imported = false;
      this._modeler
        .importXML(payload.xml)
        .then(function () {
          canvas.zoom('fit-viewport', 'auto');
          this._currentSelection = null;
          this._imported = true;
          replayPendingErrorHighlight(this);
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

        var bo = element.businessObject;
        var type = bo.$type;
        var updates = {};

        // ash: extension elements — only on the element types that own the
        // vocabulary. A sequence flow or gateway carries none; rebuilding
        // extensionElements there would write an empty ash:taskConfig onto
        // elements the compiler never reads it from.
        if (type !== 'bpmn:SequenceFlow' && !endsWithGateway(type)) {
          var ashValues = buildAshValues(moddle, type, payload.config || {});
          updates.extensionElements = rebuildExtensionElements(moddle, bo, type, ashValues);
        }

        if (payload.name !== undefined && payload.name !== null) {
          updates.name = payload.name;
        }

        // A flow's condition: the FEEL expression the source gateway routes
        // on. Blank clears it.
        if (type === 'bpmn:SequenceFlow' && payload.condition != null) {
          updates.conditionExpression = buildConditionExpression(moddle, bo, payload.condition);
        }

        // An exclusive gateway's default flow: the branch taken when no
        // condition matches. Blank clears the reference.
        if (endsWithGateway(type) && payload.default_flow != null) {
          if (nonBlank(payload.default_flow)) {
            var defaultBo = resolveOutgoingFlow(bo, String(payload.default_flow));

            if (!defaultBo) {
              pushError(
                this,
                'apply_config: default flow "' +
                  payload.default_flow +
                  '" is not an outgoing flow of ' +
                  payload.id
              );
              return;
            }

            updates.default = defaultBo;
          } else {
            updates.default = undefined;
          }
        }

        modeling.updateProperties(element, updates);
        this.pushEvent('dirty_changed', { dirty: true });
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this));

    // -----------------------------------------------------------------------
    // Error highlighting — the same marker channel the instance viewer uses,
    // with an error-red marker. The payload can land before importXML
    // resolves, so the last one is held and replayed on import.
    // -----------------------------------------------------------------------
    this._imported = false;
    this._pendingErrorHighlight = null;
    this._errorIds = new Set();

    this._applyErrorHighlight = function (payload) {
      try {
        var elementRegistry = this._modeler.get('elementRegistry');

        var _this = this;
        this._errorIds.forEach(function (prevId) {
          var prev = elementRegistry.get(prevId);
          if (prev) {
            canvas.removeMarker(prev, 'ash-bpmn-error');
          }
        });
        this._errorIds.clear();

        var nodeIds = payload.node_ids;
        if (Array.isArray(nodeIds)) {
          nodeIds.forEach(function (nodeId) {
            var el = elementRegistry.get(nodeId);
            if (el) {
              canvas.addMarker(el, 'ash-bpmn-error');
              _this._errorIds.add(nodeId);
            }
          });
        }
      } catch (err) {
        pushError(this, err);
      }
    }.bind(this);

    this.handleEvent('highlight', function (payload) {
      if (this._imported) {
        this._applyErrorHighlight(payload);
      } else {
        this._pendingErrorHighlight = payload;
      }
    }.bind(this));

    // -----------------------------------------------------------------------
    // Select an element and bring it into view — the jump an error row makes.
    // Selecting goes through the selection service, so the panel opens through
    // exactly the channel a canvas click uses.
    // -----------------------------------------------------------------------
    this.handleEvent('select_element', function (payload) {
      try {
        var elementRegistry = this._modeler.get('elementRegistry');
        var selection = this._modeler.get('selection');

        var el = elementRegistry.get(payload.id);
        if (el) {
          selection.select(el);
          canvas.scrollToElement(el);
        }
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
