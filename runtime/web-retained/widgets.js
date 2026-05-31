// Widget barrel. Importing this registers every widget kind (side effects in
// widgets/<kind>.js). app.js imports { widgetFor, THEME } from here.
export { widgetFor, THEME } from './registry.js';

import './widgets/label.js';
import './widgets/button.js';
import './widgets/box.js';
import './widgets/image.js';
import './widgets/layout.js';     // row, column, stack
import './widgets/checkbox.js';
import './widgets/switch.js';
import './widgets/radio.js';
import './widgets/slider.js';
import './widgets/progress.js';
import './widgets/dropdown.js';
import './widgets/divider.js';
import './widgets/group.js';
import './widgets/meter.js';
import './widgets/knob.js';
import './widgets/text_input.js';
