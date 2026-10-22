import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// Every shell animation duration is multiplied by this factor.
const FACTOR = 0.6;

export default class FastAnimations extends Extension {
    enable() {
        this._settings = St.Settings.get();
        this._old = this._settings.slow_down_factor;
        this._settings.slow_down_factor = FACTOR;
    }

    disable() {
        this._settings.slow_down_factor = this._old ?? 1.0;
        this._settings = null;
    }
}
