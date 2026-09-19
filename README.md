# BPM Analyzer

A program that works out the tempo of a piece of music, not one number for the
whole track, but how the tempo changes over time and then lets you check the
answer by ear, correct it by hand, and export it (to use for osu mapping).

Built in [Jai](https://github.com/BSVino/JaiPrimer/blob/master/JaiPrimer.md),
with SDL2 for the window and audio, OpenGL for the graphs, and ImGui for the
controls.

---

## Contents

- [The two tabs](#the-two-tabs)
- [How the analysis works](#how-the-analysis-works)
- [Configurable settings](#configurable-settings)
- [Limitations](#limitations)
- [How it is built](#how-it-is-built)
- [Where the numbers come from](#where-the-numbers-come-from)

---

## The two tabs

### Analyzer

The analyzed results.

- **File** and **Source** — what was loaded and how it decoded.
- **Analysis settings** — the knobs, described [below](#configurable-settings).
  Open by default, with the result of the current settings beside them.
- **Onset envelope** — a spike wherever the music does something percussive,
  with the detected beats and bar-starts marked over it.
- **Tempogram** — a heatmap of how strongly each tempo from 30 to 300 BPM is
  present at each moment, with the traced tempo curve drawn over it.
- **Tempo curve** — the traced tempo on its own.
- Statistics for every stage, and a validation pass that flags values out of
  range and jumps the map does not support.

Scroll over a graph to zoom, drag to pan, double-click to fit the whole track
back in. Each graph zooms independently. Hovering shows the timestamp and the
BPM at that point.

### Editor

Where you check the answer by ear and fix it.

- **Waveform** with the beat grid drawn over it and a playhead showing where the
  music has got to — the point of the tab, because you can *see* whether the
  grid lands on the drum hits.
- **Transport** — play, pause, stop, ±1 s, ±5 s, volume, and speed (1x, 0.75x,
  0.5x, 0.25x, optionally holding the pitch).
- **Timing points** — the list of tempo changes. Move them, retune them, add and
  delete them, shift them all if the track is consistently early or late, or
  scale them all if the right pattern was found at the wrong speed.
- **Export timing points (.txt)** — writes the `[TimingPoints]` section in osu!'s
  format to `output/<name>_timing.txt` and opens the folder with the file
  selected.

**Keyboard.** Space plays and pauses, resuming where it stopped. Delete removes
the selected timing point. Left and right arrows step to the previous and next
grid division (one beat) and holding either accelerates: the step doubles
every 800 ms up to 64 beats, and the music pauses for the duration and resumes
when you let go.

**Mouse, on the waveform.** Click to seek. Drag a marker to move it. Ctrl+click
to add a timing point on the nearest beat.

### File menu

New, Open, Save, Save As, with Ctrl+N / Ctrl+O / Ctrl+S. A saved timing file
(`.bpmproj`) holds the audio path, every edited timing point, the playhead, the
volume, and the grid settings. Opening one loads and analyzes the audio it names
and lays the saved points back over the result.

---

## How the analysis works

Nine stages, each feeding the next. Everything downstream is limited by the one
before it.

### 1. Preprocess — `preprocess.jai`

The file is decoded, mixed to mono, resampled to 22050 Hz, and peak-normalised.

Resampling is windowed sinc rather than nearest neighbour or linear: a straight
line between samples is a low-pass filter with a bad response, and it aliases
everything above the new Nyquist back down into the audible range, which for
onset detection means invented transients.

The result is one channel of float32 at a known rate, which is what every stage
below works on.

### 2. Onset envelope — `onset.jai`

A one dimensional signal that spikes when something percussive happens.

1. **STFT** — 2048-sample Hann window, 512-sample hop. 23 ms per frame at
   22050 Hz.
2. **Magnitude** — the phase is thrown away; only energy matters.
3. **Compression** — `log(1 + γ·x)` with γ = 1000, so a quiet hi-hat is not
   invisible next to a loud kick.
4. **Spectral flux** — the sum of the positive frame-to-frame differences across
   frequency. Energy that *appeared*, which is what an onset is.
5. **Running mean** — a 1.5 second moving average is subtracted, so that slow
   changes in loudness stop looking like onsets.
6. **Rectify** — onset strength cannot be negative.
7. **Normalise** — scaled so the whole envelope runs 0 to 1.

The envelope is deliberately **not** smoothed. Smoothing blurs exactly the fine
timing that variable-tempo analysis needs.

### 3. Tempogram — `tempogram.jai`

For every 93 ms column, how strongly each candidate tempo from 30 to 300 BPM is
present.

The method is **autocorrelation, read through a comb**. The envelope is
autocorrelated over a 2 second window, and for each candidate period the
autocorrelation is sampled at that period and at its harmonics, up to four of
them and summed. A tempo whose period, half-period, third and quarter all show
periodicity in the signal scores well (one that does not, scores badly).

Three details matter more than they look:

- **The lag is read by Catmull-Rom interpolation**, not linear. At 116 BPM the
  beat period is 21.5 frames, and reading between samples with a straight line
  cuts the corner off the peak, it reads a little low, and it reads *least* low
  for lags landing just under a sample. That is a tempo bias, not a rounding
  detail: a 116 BPM track came out as 118 before this was fixed.
- **The 2 second window is short on purpose.** Six seconds is usual for a
  whole-track estimate, but every column here is a tempo *for that moment*, so
  the window is the shortest span the answer can change over. Measured on a
  track with ten known changes: six seconds put the curve a whole octave out,
  two seconds gives a mean error of 0.16 octaves.
- **The window also sets the slowest tempo visible.** The longest lag that can
  be read is one window, so 2 seconds reaches down to 30 BPM and no further.

### 4. Tempo curve — `tempo.jai`

One tempo per moment, traced through the tempogram.

A shortest-path problem. Each cell of the tempogram costs `-log(value)`, so
standing where the music is well explained is cheap. Moving between adjacent
columns costs `smoothing × distance²`, where distance is measured in tempo bins, 
and the bins are log-spaced, so that penalty is really in log-BPM and is
therefore octave-symmetric: a step from 150 to 300 costs the same as 150 to 75.

The temperature of that trade is the whole character of the curve. A small
penalty follows every wobble. A large one reports a tempo that never existed.

### 5. Octave correction — `octave.jai`

The curve can settle on the wrong member of a tempo's harmonic family. A track
whose beat is at 83 BPM also has strong periodicity at 167 and 250, and which
one the tracker picks depends on tiny differences in the map. Nothing downstream
can recover from that, so it is fixed here.

The procedure is the one you would use by hand:

1. Take `log2` of every BPM in the curve.
2. A real tempo change is a small step in log2; a flip is a step of about ±1.0
   (an octave) or ±0.585 (a fifth). Split the curve at every step big enough to
   be a candidate flip, giving a handful of segments.
3. For each segment, try shifting it by each of the metrical ratios: a quarter,
   a third, a half, one, two, three, four, and score the result two ways: how
   well the shifted curve fits the tempogram, and how plausible the tempo is in
   the first place.
4. Keep the shift that scores best, insisting that neighbouring segments still
   meet each other afterwards. That last part is a small Viterbi over the
   segments; with a single segment, the common case, a track simply at the
   wrong octave throughout, it degenerates to picking the best ratio.

The **tempo prior** is what decides most cases. The tempogram often cannot: 83
and 250 BPM are both genuinely bright when the beat is at 83, so "which fits the
map better" is close to a coin toss. What breaks the tie is that music is far
more often near 120 BPM than near 250, and this is the single most consequential
setting in the program. See [Limitations](#limitations).

### 6. Smoothing — `smooth.jai`

A 5-frame median filter followed by a 3-frame moving average, applied in log
space. The median removes spikes without dragging the values around them; the
moving average takes off what is left. Both are short enough not to flatten real
tempo movement.

### 7. Beat tracking — `beats.jai`

The tempo curve says how fast the music is at every moment, but not where the
beats fall. This finds them.

Another shortest-path problem, over a state of *a beat at frame q, arriving via
a gap of tempo t*. Two things pull against each other:

- **Reward** for landing on an onset, the envelope value at the beat.
- **Penalty** on the arriving gap disagreeing with the curve at that point.
- **Penalty** on the gap's tempo differing from the previous gap's.

The third term is what permits a gradual accelerando while forbidding a leap.
The second is measured against the *curve* rather than a fixed period, which is
what lets the tracker follow rubato without being told about it in advance.

### 8. Downbeats — `downbeat.jai`

Which beat is the first of the bar.

A second onset envelope is built from the low band, below 150 Hz, where kick
drums live. The meter is estimated as 3 or 4 by comparing how much low-frequency
energy falls on each position in the bar, and a beat-level dynamic program picks
the offset that puts the strongest kicks on the one.

### 9. Validation — `report.jai`

The finished curve is checked against the tempogram. Values outside 40–300 BPM
are masked, jumps over 20% are counted, and each jump is looked up in the map to
see whether the evidence supports it. The summary is printed to the log and
shown on the Analyzer tab.

### Where the changes come from

The list of tempo changes, on screen and in the exports, comes from
`osu.jai`, which run length encodes the curve subject to two rules:

- **A tempo has to move by more than 5 BPM** before it counts as changed,
  compared against the tempo the stretch has been *holding* rather than the
  previous column. A slow drift of forty beats per minute is a change even
  though no two neighbouring columns are far apart; a wobble of one beat is not
  a change however long it goes on for.
- **It has to stay there for 4 seconds.** A column away from the tempo in force
  only ends a stretch if the curve stays away; an excursion that comes back
  inside the hold is passed over and its columns folded back into the stretch
  they interrupted.

Both are needed. The tolerance alone is not enough, because where the beat is
briefly ambiguous the curve does not wobble by a beat or two, it dips by ten or
twenty BPM for a second or three and comes back. Those dips are wider than any
tolerance worth setting, so what separates them from a real change is that they
end.

---

## Configurable settings

Ten are on the panel, the rest are in the source. All of them live in
`Analysis_Settings` in `main.jai` and are read by the stages rather than baked
into them.

**Reset to defaults** puts everything back and re-runs.

### Tempo prior

The most consequential setting in the program, and the one most likely to need
changing for a particular track.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Preferred tempo | 120 | 40–300 | The centre of a log-Gaussian preference for where the tempo probably is |
| How far it reaches | 1.00 | 0.25–3 | Sigma, in octaves. At 1.0, a tempo an octave away is about 1/3 as likely |
| How strongly it pulls | 1.00 | 0–2 | Weight. At 0 the prior is ignored and the fit alone decides |

The prior exists because the tempogram genuinely cannot always decide. On a track
whose beat is at 83 BPM, 167 and 250 are both bright, and the difference between
them in the map is smaller than the difference a musically plausible tempo makes.
So the program assumes what is true of most music: that the tempo is nearer 120
than 250.

**This is wrong for whole genres and whole tracks.** Half the test material is
above 200 BPM, where a centre of 120 pulls the answer down an octave. If a track
comes out at exactly half or double what you know it to be, this is the control:
drag *How strongly it pulls* toward 0 and watch the number beside it.

Setting it to 0 does not always help. On some tracks the map is ambiguous in a
way the prior resolves correctly, and removing it lets the map pick a tempo four
times too fast. That is the honest trade, and the reason the control is here
rather than a better default existing.

### Tempogram

| Setting | Default | Range | What it does |
|---|---|---|---|
| Window | 2.00 s | 1–12 | How much of the track each tempo estimate is made from |
| Harmonics read | 4 | 1–8 | How many multiples of the beat period the comb reads |
| Harmonic weighting | 0.00 | 0–2 | How fast the comb's weight decays with harmonic number |

**Window** is the sharpest trade in the program. Longer resolves tempo better and
smears changes more; shorter localises changes and sees fewer cycles. It also
sets the slowest tempo visible, since the longest lag that can be read is one
window — below about 1.5 seconds, 40 BPM stops being reachable.

**Harmonics** — reading more makes the score more robust to a missed beat, at the
cost of pulling in longer lags, which are weaker and noisier. Measured across the
test tracks, 4 is the only value at which all of them are as right as they get.

**Harmonic weighting** — whether the first harmonic of the beat counts for more
than the fourth. Measured: 1.0 is much worse, 0.5 is a wash. The uniform sum is
what the rest of the tuning was done against; the setting is here because it is
the obvious thing to try and the measurement should not have to be repeated.

### Tracker

| Setting | Default | Range | What it does |
|---|---|---|---|
| Tempo-change penalty | 0.250 | 0.005–2 | How much the curve is penalised for moving between columns |
| Flip threshold | 0.40 | 0.2–1.0 | How big a step in log2 counts as a candidate octave flip |

**Tempo-change penalty** is the temperature of the Viterbi. Small follows every
wobble in the map and produces a curve that changes tempo constantly (large
produces a flat line that ignores a real accelerando). What is measured is
`smoothing × distance²` in tempo bins, so quadrupling it quarters the distance
the curve is willing to move for the same evidence.

**Flip threshold** decides how the curve is cut into segments before the octave
stage. Below it, a step is treated as drift within one segment (above it, as a
candidate flip between two). Too low and ordinary drift gets cut into pieces that
are then corrected independently. Too high and a real flip is treated as drift
and never corrected.

### What counts as a change 

| Setting | Default | Range | What it does |
|---|---|---|---|
| Smallest change | 5.0 BPM | 0–30 | How far the tempo must move to be reported |
| How long it must hold | 4000 ms | 0–20000 | How long it must stay there |

These do not change the curve and take effect immediately. Their defaults were
measured on the ten test tracks, as changes reported on each. The first four are
constant and should report none, the rest have known changes:

| Hold | test1 | test2 | test3 | test4 | test5 | False reports |
|---|---|---|---|---|---|---|
| 500 ms | 2 | 12 | 0 | 0 | 11 | 135 |
| 2000 ms | 0 | 3 | 0 | 0 | 7 | 49 |
| 3000 ms | 0 | 1 | 0 | 0 | 3 | 24 |
| **4000 ms** | **0** | **1** | **0** | **0** | **3** | **15** |
| 6000 ms | 0 | 1 | 0 | 0 | 2 | 14 |

4000 ms cuts false reports by nearly 90% against the old 500 ms. The cost is
placement: the mean error in *when* a real change is reported grows from about
1.0 s to about 2.0 s, because a longer hold only accepts changes that last, and
those start further from where the change actually is.

see [Where the numbers come from](#where-the-numbers-come-from)

### Not on the panel

| Setting | Default | Where | What it does |
|---|---|---|---|
| Sample rate | 22050 | `preprocess` | The rate everything works at. Halving the cost of the FFT, at the cost of not seeing above 11 kHz |
| Normalise | PEAK | `preprocess` | Peak or RMS normalisation of the whole signal |
| Resample kernel | 16 | `preprocess` | Half-width of the windowed-sinc kernel, in samples |
| STFT window | 2048 | `onset` | Frequency resolution against time resolution |
| STFT hop | 512 | `onset` | 23 ms per frame. Halving it doubles the cost and halves the beat quantisation |
| Compression | LOG, γ 1000 | `onset` | How hard quiet onsets are lifted. `CUBE_ROOT` is gentler and parameter-free |
| Max frequency | 0 (all) | `onset` | Setting 5000 mostly removes hiss; the default follows the classic definition |
| Running mean | 1.5 s | `onset` | The local "normal" level of flux that is subtracted |
| Envelope normalise | FILE | `onset` | `WINDOW` normalises over a running 4-second window instead. Measured: much worse on this material |
| Median filter | 0 | `onset` | Optional 3 or 5 frame denoising. Anything wider smears onset timing |
| SuperFlux | 0 | `onset` | Max filter across frequency before the flux, so vibrato stops reading as onsets. Measured: worse |
| Tempo range | 30–300 | `tempogram` | Candidate tempi |
| Tempo bins | 240 | `tempogram` | Log-spaced, about 17 cents per bin |
| Column hop | 4 frames | `tempogram` | 93 ms per column |
| Subdivision weight | 0 | `tempogram` | Extra comb weight half way between beats |
| Half-note weight | 0 | `tempogram` | Extra weight on every second beat |
| Log compression | on, γ 100 | `tempogram` | Flattens dominant ridges and lifts weak ones |
| Observation floor | 1e-3 | `tempo` | Prevents `-log(0)` in empty cells |
| Max jump | 24 bins | `tempo` | The furthest the Viterbi may move in one step |
| Octave tolerance | 0.17 | `octave` | How near a step must be to a whole-number ratio to count as a metrical flip |
| Continuity weight | 0.3 | `octave` | Penalty on the step left between corrected segments |
| Smoothing method | median + MA | `smooth` | Or `KALMAN` |
| Median / MA frames | 5 / 3 | `smooth` | Both deliberately short |
| Beat range | 40–300 | `beats` | Tempi a gap may imply |
| Beat tempo bins | 48 | `beats` | Quantisation of the implied gap |
| Onset / mismatch / change weights | 1.0 / 6.0 / 1.0 | `beats` | The three pulls on the beat tracker |
| Onset lead | 25 ms | `beats` | Compensates the envelope's known early lead |
| Beats per bar | 4 | `downbeat` | 3 or 4 |
| Kick band | 150 Hz | `downbeat` | Where the kick detector looks |
| Validation range | 40–300 | `report` | Values outside are masked |

---

## Limitations

These are measured, not guessed. The test set is ten tracks with known answers. See [Where the numbers come from](#where-the-numbers-come-from)

### The tempo can come out an octave wrong, and no setting fixes every track

Four of the ten come out at the wrong tempo: three at exactly half, one at two
thirds. All four are the tempo prior overriding evidence that was right.

But weakening the prior is not a fix, because it breaks others in exchange. At
weight 0 the errors move rather than disappear:

| Prior weight | Tempo right | Wrong |
|---|---|---|
| 0 | 7/10 | test2, test8, test10 |
| 1.0 (default) | 6/10 | test3, test7, test8, test9 |

Every sweep: weight, centre, sigma, tops out at 7 of 10, with a different set
wrong each time. **There is no single configuration that gets all ten**, which is
why the settings are on the panel: the right answer depends on the track, and
only the person listening can say which they have.

One track (test8) is wrong in *every* configuration, because its tempo of 181
sits a 3:2 relation from both 120 and 240 and the map prefers both over the
truth.

### Tempo changes shorter than the analysis window are invisible

Each tempo estimate is made from a 2 second window, so a tempo that lasts less
than about two seconds cannot be resolved, it is averaged into its neighbours.
This is a property of the method, not a setting. 

### Changes are reported late

The mean error in *when* a real change is reported is about 2 seconds with the
default hold, and it was 1 second with the previous 500 ms hold. The curve is
smeared by the analysis window, and we report where the curve broke the tolerance
rather than where it started moving. For a timing tool this is the limitation
most worth improving.

### The beat grid is quantised to 23 ms

Beats land on envelope frames. Halving the hop would halve that, at double the
cost, hop 256 makes the results worse overall, so 512 stays.

### Tempo outside 30–300 BPM

Below 30 needs a longer window, which smears changes. Above 300 the envelope's
own frame rate starts to be the limit. 

### Some material has no tempo in it to find

test2's envelope is dense enough that a grid at four times the true tempo keeps
finding more onset energy than one at the truth. A beat-evidence score built for
exactly this problem was measured, worked in isolation, and produced results
identical to simply turning the prior off, so it was not shipped. There is no
tempo information in that envelope to find, and no scorer will invent it.

### The meter is only 3/4 or 4/4

Compound and irregular meters are not handled. The downbeat stage also fails
quietly, and on drumless material it fails completely.

### Adjusting a track discards the analysis

Re-running the analysis re-seeds the Editor tab's timing points from the result.
If the points have been edited, the program asks about saving first.

### The time-stretch is not free

Holding the pitch while playing at 0.5x and 0.25x uses WSOLA, which cuts the
track into overlapping windows and lays them down closer together. Pitch is held
within 0.8%, measured on a 440 Hz tone, but it leaves the artefacts any stretch
does: a slight flutter on sustained pads and reverb tails. Uncheck **Keep pitch**
for the cleaner alternative, which shifts everything down with the tempo. Neither
is a phase vocoder, deliberately: a phase vocoder smears transients, and a
transient is precisely what this program exists to look at.

### What I plan to do about these limitations

These limitations have something in common: most of them are not failures of the
method so much as the method being asked to work on material it was not tuned for.
The tempo prior is the clearest case. It is what decides the hard tracks, and it is
right about most music and wrong about anything much above 200 BPM -- so a track at
250 comes out at 125, and dragging *How strongly it pulls* to zero fixes that track
and breaks others instead.

The answer is therefore not a better single configuration. Ten test tracks already
show that there is no such thing: tuning the prior until all ten come out right tops
out at seven, and which seven changes with the setting. What varies is the material,
so what is needed is one configuration per kind of material.

The plan is per-genre presets, built the way everything else in this program was
built (by measuring).

1. **Collect a labelled set for each genre.** The format already exists in
   `tests/notes.txt`: a tempo per track, and for the variable ones, the times and
   tempi of each change. What is missing is enough tracks per genre that a preset is
   fitted to a body of music rather than to three songs.

2. **Score whole sets, not single tracks.** `tests/main_tests.jai` already reports
   the four numbers that matter: how many tracks come out at the right tempo, how
   many known changes are found, how many changes are invented, and the mean error in
   where a found change is placed. A configuration that fixes one track by breaking
   two is not an improvement, and scoring one track at a time hides exactly that.

3. **Choose each preset by measurement rather than by ear.** Run every candidate
   configuration across the whole genre set and keep the one with the best overall
   score -- insisting, as above, that it wins on tracks it was not tuned on.

4. **Ship them selectably.** The settings are already a single struct, so a preset is
   one assignment, and the panel already exposes every knob that matters. A choice of
   preset would sit beside the analysis settings.

**The risk is overfitting, and there is a concrete example of it.** While working on
the tempo prior, moving its centre from 120 BPM to 175 made every one of the five
test tracks I had at the time come out right. It was rejected anyway, for two
reasons: the window between it working and it breaking again was only ten beats per
minute wide, and 175 is a long way from where the tapping studies put the preferred
tempo. A setting that is right about five tracks because it was chosen on those five
tracks is not right about music, it has learned the test set.

That is the standard any preset has to meet.

**One thing worth being honest about.** Genre is a proxy. What actually differs
between the tracks this program gets right and the ones it gets wrong is the tempo
range and how metrically ambiguous the material is, not the label on the record.
Two drum and bass tracks at 174 BPM will want the same settings whatever else
separates them, and a slow ballad and an uptempo song in the same genre will want
different ones. So the presets may well end up named for something closer to "fast
electronic" and "slow acoustic" than for genre proper.

---

## How it is built

About 9000 lines of Jai across 25 files.

| File | Lines | What it is |
|---|---|---|
| `main.jai` | 546 | The loop, the App struct, the pipeline, the Analyzer tab |
| `adjust.jai` | 618 | The Editor tab: waveform, transport, timing point editing |
| `audio.jai` | 643 | Decoding, the SDL_mixer setup, the Win32 dialogs |
| `preprocess.jai` | 300 | Stage 1: decode, mix, resample, normalise |
| `onset.jai` | 618 | Stage 2: the onset envelope, and an FFT |
| `tempogram.jai` | 620 | Stage 3: the tempogram |
| `tempo.jai` | 277 | Stage 4: the Viterbi tempo curve |
| `octave.jai` | 348 | Stage 5: metrical correction |
| `smooth.jai` | 256 | Stage 6: smoothing |
| `beats.jai` | 349 | Stage 7: beat placement |
| `downbeat.jai` | 265 | Stage 8: the kick band, the meter, the bars |
| `report.jai` | 252 | Stage 9: validation, and the CSV exports |
| `playback.jai` | 481 | Playing the track, including the WSOLA time-stretch |
| `waveform.jai` | 151 | The peak envelope drawn behind the grid |
| `plot.jai` | 769 | The OpenGL plot renderer |
| `graphs.jai` | 401 | The three graphs |
| `timing.jai` | 357 | The editable timing points |
| `project.jai` | 287 | The save file format |
| `save.jai` | 239 | File menu actions, the unsaved-changes question |
| `osu.jai` | 384 | The change detection and the osu! exports |
| `settings.jai` | 169 | The settings panel |
| `util.jai` | 138 | Number formatting |
| `imgui_sdl_gl.jai` | 375 | ImGui's SDL2/OpenGL backend |
| `input.jai`, `ui.jai` | 123 | Small helpers |

---

## Where the numbers come from

The ten test tracks in `tests/`, with their known tempi in `tests/notes.txt`.
Current results:

| Track | Expected | Measured | Verdict |
|---|---|---|---|
| test1.ogg | 158 | 158.8 | ok |
| test2.mp3 | 137 | 137.5 | ok |
| test3.ogg | 250 | 124.9 | wrong — octave |
| test4.ogg | 150 | 149.9 | ok |
| test5.ogg | 180 | 180.0 | ok |
| test6.mp3 | 174 | 174.9 | ok |
| test7.mp3 | 300 | 150.0 | wrong — octave |
| test8.mp3 | 181 | 120.2 | wrong — 3:2 |
| test9.mp3 | 177 | 88.3 | wrong — octave |
| test10.mp3 | 142 | 142.9 | ok |

**Tempo right: 6/10. Changes right: 4/10. False reports: 15.**

Anything changed in the analysis should be re-measured against this. 
