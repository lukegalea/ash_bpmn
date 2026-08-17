// SPDX-FileCopyrightText: 2026 Luke Galea
// SPDX-License-Identifier: MIT

// The library's LiveViews carry their own utility classes, so the content glob
// has to reach into lib/ as well as the demo app's own templates.
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/**/*.ex",
    "../../lib/ash_bpmn/web/**/*.ex",
  ],
  theme: { extend: {} },
  plugins: [],
};
