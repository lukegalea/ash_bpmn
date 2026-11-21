// SPDX-FileCopyrightText: 2026 Luke Galea
// SPDX-License-Identifier: MIT
//
// Round-trips every ash: extension the compiler reads through bpmn-moddle with the
// designer's descriptor, and fails if any attribute or element is lost on save.
//
// bpmn-js parses and saves through moddle, and moddle round-trips only what a descriptor
// declares: an attribute the descriptor does not know is dropped on save, silently. So a
// diagram whose timer says `date="= subject.notice_at"` would come back from the designer
// with no moment, and the compiler would refuse it for having none.
//
//   cd dev/assets && npm install && npm run test:moddle

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { BpmnModdle } from 'bpmn-moddle';

const here = path.dirname(fileURLToPath(import.meta.url));
const designer = readFileSync(path.join(here, '../../priv/js/ash_bpmn_designer.js'), 'utf8');

// The descriptor is a plain object literal; read it out of the hook rather than importing the
// hook, which pulls in bpmn-js and its stylesheets.
const start = designer.indexOf('export const ashBpmnModdle = ');
const end = designer.indexOf('\n};\n', start);
if (start < 0 || end < 0) throw new Error('ashBpmnModdle descriptor not found');
const literal = designer.slice(start + 'export const ashBpmnModdle = '.length, end + 2);
const descriptor = new Function(`return (${literal});`)();

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
  xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns" id="D" targetNamespace="x">
  <bpmn2:process id="P" isExecutable="true">
    <bpmn2:userTask id="Review">
      <bpmn2:extensionElements>
        <ash:taskConfig>
          <ash:schedule due="= subject.received_at + duration(&quot;P30D&quot;)" followUp="P21D"/>
          <ash:timers>
            <ash:timer kind="remind" hours="2"/>
            <ash:timer kind="remind" date="= task.due_at - duration(&quot;P2D&quot;)" ifPast="skip"/>
            <ash:timer kind="escalate" minutes="15" until="claimed" signal="stalled"/>
            <ash:timer kind="remind" cycle="R3/PT1H"/>
            <ash:timer kind="expire" duration="P3D"/>
          </ash:timers>
        </ash:taskConfig>
      </bpmn2:extensionElements>
    </bpmn2:userTask>
  </bpmn2:process>
</bpmn2:definitions>`;

const expected = [
  'due="= subject.received_at + duration(&#34;P30D&#34;)"',
  'followUp="P21D"',
  'kind="remind" hours="2"',
  'date="= task.due_at - duration(&#34;P2D&#34;)"',
  'ifPast="skip"',
  'until="claimed"',
  'signal="stalled"',
  'cycle="R3/PT1H"',
  'duration="P3D"'
];

const moddle = new BpmnModdle({ ash: descriptor });
const { rootElement, warnings } = await moddle.fromXML(xml);
const { xml: saved } = await moddle.toXML(rootElement);

const missing = expected.filter((fragment) => !saved.includes(fragment));

if (warnings.length > 0 || missing.length > 0) {
  console.error('warnings:', warnings.map((w) => w.message));
  console.error('lost on save:', missing);
  console.error(saved);
  process.exit(1);
}

console.log(`ok: ${expected.length} ash: attributes survive a bpmn-moddle round trip`);
