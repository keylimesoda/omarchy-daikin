# Schedule UX — design notes (paused)

Status: idea stage, nothing built. Prerequisite gap: CLI reads schedules
(`daikin schedule`, `daikin scheduler`) but cannot write a program
(`set_scdltimer`) yet.

## Data model (BRP072A43, via /aircon/get_scdltimer*)
- master: scheduler on/off + active slot (1–3)
- 3 named slots (scdlN_name), each = 7 days × ≤ few events
- event = time (minutes), on/off, mode, setpoint °C, enabled flag
- `set_scdltimer` replaces a whole slot → read-modify-write + explicit Save

## Agreed direction (recommended)
Collapsed summary row in panel (master switch, active slot, first two
transitions) → expand: slot chips (1–3, active badged) → day-scope chips
(Mon–Fri / Sat+Sun / single day; scope = write same events to N days) →
event list sorted by time (edit inline: time/mode/setpoint; delete; add
defaults to next :00, current mode/setpoint) → one Save button, errors via
existing lastError/lastAction. Read-only 24 h preview strip (segments:
grey as-is / dim off / red heat / blue cool) as delight layer or follow-up.
No autosave (single-threaded device + clobber risk). Manual override
pausing the scheduler → optional "resume?" chip.

## CLI shape to add first
    daikin schedule set --slot 1 --dry-run --json schedule.json
    daikin schedule set --slot 1 --day mon-fri \
        --event "06:30,heat,70f,on" --event "23:00,off"

## Open questions
- Expose all 3 slots or start with 1–2? (slot renaming is free)
- v1 cut: summary+slots+scope+list+save; 24 h strip as follow-up

Device discipline unchanged: dry-run / read-only only; user toggles live
state himself. Never touch get_week_power/get_year_power.